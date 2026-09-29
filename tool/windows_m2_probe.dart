// Native M2 diagnostic. Build this entry separately from the shipping app.
// --dart-define=HANMUSIC_PROBE_DIR=<owned test directory with fixtures/>
// Run once with no arguments, then again with 'restore' to test a new process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/play_mode.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/data/sources/just_audio_backend.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/view.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('HANMUSIC_PROBE_DIR');
  if (root.isEmpty) exit(2);
  initializeAudioBackend();
  final probe = _M2Probe(Directory(root), arguments.contains('restore'));
  FlutterError.onError = (details) {
    probe.frameworkErrors.add('${details.exception}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    probe.frameworkErrors.add('$error\n$stack');
    return true;
  };
  probe.controller.onStart();
  runApp(
    GetMaterialApp(
      debugShowCheckedModeBanner: false,
      theme: HanMusicTheme.light,
      home: PlayerPage(controller: probe.controller),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(probe.run()));
}

class _M2Probe {
  _M2Probe(this.output, this.restoring) {
    library = LibraryService(
      repository: LocalLibraryRepository(
        artworkDirectory: Directory('${output.path}/artwork'),
      ),
    );
    player = PlayerService(JustAudioBackend());
    timer = TimerService(onExpired: player.pause);
    store = FileAppStateStore(Directory('${output.path}/session'));
    controller = PlayerController(
      player: player,
      timer: timer,
      picker: _UnusedPicker(),
      library: library,
    );
  }

  final Directory output;
  final bool restoring;
  late final LibraryService library;
  late final PlayerService player;
  late final TimerService timer;
  late final FileAppStateStore store;
  late final PlayerController controller;
  final checks = <Map<String, Object?>>[];
  final frameworkErrors = <String>[];

  Future<void> run() async {
    final started = DateTime.now().toUtc();
    final watchdog = Timer(const Duration(minutes: 5), () => exit(3));
    String? fatal;
    try {
      await output.create(recursive: true);
      await player.setVolume(.01);
      if (restoring) {
        await _restore();
      } else {
        await _initial();
      }
    } catch (error, stack) {
      fatal = '$error\n$stack';
    } finally {
      timer.onClose();
      library.onClose();
      controller.onDelete();
      await player.shutdown().timeout(const Duration(seconds: 15));
      watchdog.cancel();
      final passed =
          fatal == null &&
          frameworkErrors.isEmpty &&
          checks.isNotEmpty &&
          checks.every((c) => c['status'] == 'passed');
      await File(
        '${output.path}/result-m2-${restoring ? 'restore' : 'write'}.json',
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'startedAt': started.toIso8601String(),
          'finishedAt': DateTime.now().toUtc().toIso8601String(),
          'os': Platform.operatingSystemVersion,
          'phase': restoring ? 'new_process_restore' : 'initial_import',
          'passed': passed,
          'fatalError': fatal,
          'checks': checks,
          'frameworkErrors': frameworkErrors,
          'limitations': [
            'Fixture paths bypass the native file selection dialog.',
            'Decoder/clock checks do not measure audible output or device changes.',
            '10k benchmark measures synthetic index I/O/search, not 10k physical imports or frame timing.',
          ],
        }),
        flush: true,
      );
      exit(passed ? 0 : 1);
    }
  }

  Future<void> _initial() async {
    await store.load();
    final fixtures = Directory('${output.path}/fixtures');
    await _check('recursive_import_metadata_and_duplicate', () async {
      final imported = await library.importPaths([fixtures.path]);
      _require(
        imported.length == 4,
        'Expected 3 valid audio fixtures and 1 bad file.',
      );
      final alpha = library.songs.firstWhere(
        (s) => s.fileName == '01-alpha.flac',
      );
      _require(
        alpha.title == '测试曲目 Alpha' && alpha.artist == 'HanMusic Probe',
        'FLAC tags were not read.',
      );
      final beta = library.songs.firstWhere((s) => s.fileName == '02-beta.mp3');
      _require(beta.title == '测试曲目 Beta', 'MP3 tags were not read.');
      final repeated = await library.importPaths([fixtures.path, alpha.path]);
      _require(
        repeated.isEmpty && library.songs.length == 4,
        'Import did not deduplicate.',
      );
      _require(
        library.search('HanMusic Probe').length >= 2,
        'Artist search failed.',
      );
      return {
        'count': library.songs.length,
        'alphaTitle': alpha.title,
        'betaTitle': beta.title,
        'status': library.statusMessage.value,
      };
    });
    final alpha = library.songs.firstWhere(
      (s) => s.fileName == '01-alpha.flac',
    );
    final beta = library.songs.firstWhere((s) => s.fileName == '02-beta.mp3');
    final wave = library.songs.firstWhere((s) => s.fileName == '03-wave.wav');
    final bad = library.songs.firstWhere((s) => s.fileName == '90-bad.wav');

    await _check('natural_completion_advances_native_queue', () async {
      player.playMode.value = PlayMode.sequential;
      await player.playQueue([alpha, beta]);
      await _until(
        () => player.currentSong.value?.id == beta.id && player.isPlaying.value,
      );
      _require(
        player.position.value >= Duration.zero,
        'Missing playback clock.',
      );
      await player.pause();
      return {'current': player.currentSong.value?.fileName};
    });
    await _check('native_bad_file_skip_terminates', () async {
      await player.playQueue([bad, wave]);
      await _until(
        () => player.currentSong.value?.id == wave.id && player.isPlaying.value,
      );
      await player.pause();
      await player.playQueue([bad]);
      await _until(() => !player.isLoading.value && !player.isPlaying.value);
      _require(
        player.errorMessage.value != null,
        'All-bad queue did not report an error.',
      );
      return {'allBadStopped': true, 'error': player.errorMessage.value};
    });
    await _check('reorder_and_timer_preserve_current_song', () async {
      await player.playQueue([wave, alpha, beta]);
      await _until(() => player.isPlaying.value);
      player.reorderQueue(0, 3);
      _require(
        player.currentSong.value?.id == wave.id && player.currentIndex == 2,
        'Reorder changed the active source.',
      );
      timer.start(const Duration(seconds: 1));
      await _until(
        () => !player.isPlaying.value && timer.remaining.value == null,
      );
      return {'currentIndex': player.currentIndex, 'pausedByTimer': true};
    });
    await _check('save_paused_queue_for_new_process', () async {
      await player.seek(const Duration(seconds: 2));
      player.playMode.value = PlayMode.repeatAll;
      await store.save(
        AppSnapshot(
          songs: library.songs.toList(),
          queue: player.queue.toList(),
          currentId: player.currentSong.value?.id,
          position: const Duration(seconds: 2),
          mode: player.playMode.value,
          volume: .01,
          skipOnError: true,
        ),
      );
      return {
        'currentId': player.currentSong.value?.id,
        'positionMs': 2000,
        'mode': player.playMode.value.name,
      };
    });
    await _benchmark();
  }

  Future<void> _restore() async {
    await _check('new_process_restores_without_autoplay', () async {
      final saved = await store.load();
      _require(
        saved.songs.length == 4 && saved.queue.length == 3,
        'Saved state missing.',
      );
      library.replaceAll(saved.songs);
      await library.refreshMissing();
      await player.restoreQueue(
        saved.queue,
        currentId: saved.currentId,
        position: saved.position,
        mode: saved.mode,
        volume: saved.volume,
        skipOnError: saved.skipOnError,
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
      _require(
        !player.isPlaying.value && player.canPlay,
        'Restored state auto-played or is unusable.',
      );
      _require(
        player.position.value == const Duration(seconds: 2),
        'Saved position was lost.',
      );
      _require(
        player.playMode.value == PlayMode.repeatAll,
        'Saved mode was lost.',
      );
      _require(timer.remaining.value == null, 'Old timer was restored.');
      return {
        'paused': true,
        'current': player.currentSong.value?.fileName,
        'positionMs': player.position.value.inMilliseconds,
      };
    });
    await _check('resume_uses_restored_seek_position', () async {
      await player.togglePlayback();
      await _until(
        () =>
            player.isPlaying.value &&
            player.position.value.inMilliseconds > 2150,
      );
      await player.pause();
      return {'positionMs': player.position.value.inMilliseconds};
    });
    await _check('remove_index_does_not_remove_source', () async {
      final target = library.songs.firstWhere(
        (s) => s.fileName == '01-alpha.flac',
      );
      await controller.removeFromLibrary(target);
      _require(await File(target.path).exists(), 'Source audio was deleted.');
      _require(
        !library.songs.any((s) => s.id == target.id),
        'Index was not removed.',
      );
      _require(
        !player.queue.any((s) => s.id == target.id),
        'Queue removal was not synchronized.',
      );
      return {'sourceStillExists': true};
    });
  }

  Future<void> _benchmark() => _check(
    'ten_thousand_index_round_trip_and_search',
    () async {
      final songs = List.generate(
        10000,
        (i) => Song(
          uri: Uri.file(
            '${output.path}/synthetic/track-$i.flac',
            windows: true,
          ),
          fileName: 'track-$i.flac',
          trackTitle: '测试曲目 $i',
          artist: 'artist-${i % 50}',
          album: 'album-${i % 100}',
          duration: const Duration(minutes: 3),
        ),
      );
      final benchmarkStore = FileAppStateStore(
        Directory('${output.path}/benchmark'),
      );
      await benchmarkStore.load();
      final watch = Stopwatch()..start();
      await benchmarkStore.save(
        AppSnapshot(songs: songs, queue: songs.take(100).toList()),
      );
      final saveMs = watch.elapsedMicroseconds / 1000;
      watch.reset();
      final loaded = await FileAppStateStore(
        Directory('${output.path}/benchmark'),
      ).load();
      final loadMs = watch.elapsedMicroseconds / 1000;
      final searchLibrary = LibraryService(
        repository: LocalLibraryRepository(
          artworkDirectory: Directory('${output.path}/benchmark-artwork'),
        ),
      );
      searchLibrary.replaceAll(loaded.songs);
      final searches = <double>[];
      for (var i = 0; i < 10; i++) {
        watch.reset();
        final found = searchLibrary.search('测试曲目 9999');
        searches.add(watch.elapsedMicroseconds / 1000);
        _require(found.length == 1, 'Search result mismatch.');
      }
      searchLibrary.onClose();
      _require(loaded.songs.length == 10000, 'Index round-trip lost entries.');
      return {
        'entries': 10000,
        'queueEntries': 100,
        'saveMs': saveMs,
        'restoreMs': loadMs,
        'searchSamplesMs': searches,
        'jsonBytes': await File('${output.path}/benchmark/state.json').length(),
        'buildMode': const bool.fromEnvironment('dart.vm.product')
            ? 'release'
            : 'debug/profile',
      };
    },
  );

  Future<void> _check(
    String name,
    Future<Map<String, Object?>> Function() action,
  ) async {
    final watch = Stopwatch()..start();
    try {
      final data = await action().timeout(const Duration(seconds: 45));
      checks.add({
        'name': name,
        'status': 'passed',
        'elapsedMs': watch.elapsedMilliseconds,
        'observations': data,
      });
    } catch (error, stack) {
      checks.add({
        'name': name,
        'status': 'failed',
        'error': '$error',
        'stack': '$stack',
      });
      rethrow;
    }
  }
}

Future<void> _until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 15)) {
      throw TimeoutException('Condition not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

void _require(bool value, String message) {
  if (!value) throw StateError(message);
}

class _UnusedPicker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}
