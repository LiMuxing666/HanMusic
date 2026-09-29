// Native M4 diagnostic. Build main.dart again before distributing the app.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:han_music/app/data/models/online_source_config.dart';
import 'package:han_music/app/data/models/play_mode.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';
import 'package:han_music/app/data/repositories/online_music_repository.dart';
import 'package:han_music/app/data/repositories/online_source_store.dart';
import 'package:han_music/app/data/sources/just_audio_backend.dart';
import 'package:han_music/app/services/online_music_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/sleep_timer_coordinator.dart';
import 'package:han_music/app/services/timer_service.dart';

import 'online_fixture_server.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('HANMUSIC_PROBE_DIR');
  if (root.isEmpty) exit(2);
  initializeAudioBackend();
  final probe = _Probe(Directory(root));
  FlutterError.onError = (details) => probe.errors.add('${details.exception}');
  PlatformDispatcher.instance.onError = (error, stack) {
    probe.errors.add('$error');
    return true;
  };
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('HanMusic M4 原生验证'))),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(probe.run()));
}

class _Probe {
  _Probe(this.output);
  final Directory output;
  final checks = <Map<String, Object?>>[];
  final errors = <String>[];
  late OnlineFixtureServer server;
  late OnlineMusicService online;
  late PlayerService player;
  late TimerService timer;
  late SleepTimerCoordinator coordinator;
  DateTime now = DateTime.now();
  final phase = Platform.environment['HANMUSIC_PROBE_PHASE'] ?? 'exercise';

  Song track(String id) =>
      Song.online(sourceId: 'local-demo', trackId: id, title: id);
  Song get local =>
      Song(uri: File('${output.path}/local.wav').uri, fileName: 'local.wav');

  Future<void> run() async {
    final watchdog = Timer(const Duration(minutes: 4), () => exit(3));
    String? fatal;
    final started = DateTime.now().toUtc();
    await output.create(recursive: true);
    server = await OnlineFixtureServer.start();
    online = OnlineMusicService(
      repository: OnlineMusicRepository(),
      store: FileOnlineSourceStore(Directory('${output.path}/sources')),
    );
    await online.initialize();
    player = PlayerService(
      JustAudioBackend(),
      resolver: online.resolveForPlayback,
    );
    timer = TimerService(onExpired: player.pauseForSleepTimer, now: () => now);
    coordinator = SleepTimerCoordinator(player: player, timer: timer);
    try {
      await player.setVolume(.01);
      if (phase == 'restore') {
        await _restore();
      } else {
        await _exercise();
      }
    } catch (error) {
      fatal = '$error';
    } finally {
      coordinator.onClose();
      timer.onClose();
      try {
        await player.shutdown().timeout(const Duration(seconds: 15));
        await online.close();
        await server.close();
      } catch (error) {
        fatal ??= 'Cleanup: $error';
      }
      final passed =
          fatal == null &&
          errors.isEmpty &&
          checks.isNotEmpty &&
          checks.every((check) => check['status'] == 'passed');
      await File('${output.path}/result-m4-$phase.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'phase': phase,
          'passed': passed,
          'startedAt': started.toIso8601String(),
          'finishedAt': DateTime.now().toUtc().toIso8601String(),
          'os': Platform.operatingSystemVersion,
          'checks': checks,
          'fatalError': fatal,
          'frameworkErrors': errors,
          'limitations': [
            'Native events do not measure audible output.',
            'No native dialog/window interaction or real system sleep tested.',
            'Loopback fixture is anonymous; no public commercial source tested.',
          ],
        }),
        flush: true,
      );
      watchdog.cancel();
      exit(passed ? 0 : 1);
    }
  }

  Future<void> _exercise() async {
    await File('${output.path}/local.wav').writeAsBytes(server.audio);
    await _check('configure_search_page_and_controlled_errors', () async {
      _require(
        await online.upsertSource(
          OnlineSourceConfig.fromJson(server.configJson()),
        ),
        'Source not saved.',
      );
      await online.searchNow('test');
      _require(
        online.results.length == 2 && online.hasMore.value,
        'First page incorrect.',
      );
      await online.loadMore();
      _require(
        online.results.length == 3 && !online.hasMore.value,
        'Final page incorrect.',
      );
      final notices = <String, String?>{};
      for (final query in ['empty', 'unauthorized', 'malformed', 'timeout']) {
        await online.searchNow(query);
        if (query == 'empty') {
          _require(
            online.results.isEmpty && online.errorMessage.value == null,
            'Empty search incorrect.',
          );
        } else {
          _require(
            online.errorMessage.value != null,
            'Missing controlled error.',
          );
        }
        notices[query] = online.errorMessage.value;
      }
      await online.searchNow('test');
      return {'sources': online.sources.length, 'errorNotices': notices};
    });

    await _check(
      'mixed_queue_native_pause_seek_volume_and_natural_next',
      () async {
        final first = track('tone-a');
        await player.playQueue([first, local]);
        await _until(() => player.position.value.inMilliseconds > 200);
        await player.pause();
        _require(!player.isPlaying.value, 'Pause failed.');
        await player.seek(const Duration(seconds: 1));
        _require(
          player.position.value.inMilliseconds >= 900,
          'Seek did not update progress.',
        );
        await player.setVolume(.02);
        await player.togglePlayback();
        await _until(
          () =>
              player.currentSong.value?.id == local.id &&
              player.isPlaying.value,
        );
        await player.pause();
        return {
          'localAndOnline': player.queue.length,
          'volume': player.volume.value,
          'onlineAudioRequests': server.audioRequests['tone-a'],
        };
      },
    );

    await _check(
      'expired_address_refresh_once_and_all_bad_queue_stops',
      () async {
        player.skipOnError.value = false;
        await player.playQueue([track('refresh')]);
        await _until(() => player.isPlaying.value);
        _require(
          server.resolveCounts['refresh'] == 2,
          'Expected exactly one fresh-address retry.',
        );
        await player.pause();
        player.skipOnError.value = true;
        await player.playQueue([track('broken')]);
        await _until(
          () =>
              !player.isLoading.value &&
              !player.isPlaying.value &&
              player.errorMessage.value != null,
        );
        _require(
          server.resolveCounts['broken'] == 2,
          'Bad queue retried indefinitely or skipped retry.',
        );
        _require(
          !player.errorMessage.value!.contains('probe-only'),
          'Signed URL leaked to player notice.',
        );
        return {
          'refreshResolves': server.resolveCounts['refresh'],
          'badResolves': server.resolveCounts['broken'],
          'notice': player.errorMessage.value,
        };
      },
    );

    await _check(
      'countdown_during_address_resolution_blocks_autoplay',
      () async {
        player.skipOnError.value = false;
        now = DateTime.now();
        timer.start(const Duration(minutes: 1));
        final operation = player.playQueue([track('slow')]);
        await _until(() => server.resolveCounts['slow'] == 1);
        now = now.add(const Duration(minutes: 2));
        timer.checkDeadline();
        await operation;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        _require(
          !player.isPlaying.value && !timer.isActive,
          'Late resolution resumed after expiry.',
        );
        return {'paused': true, 'notice': timer.statusMessage.value};
      },
    );

    await _check('manual_next_does_not_wait_for_obsolete_resolution', () async {
      final pending = player.playQueue([track('switch-slow'), local]);
      await _until(() => server.resolveCounts['switch-slow'] == 1);
      final watch = Stopwatch()..start();
      await player.next().timeout(const Duration(seconds: 2));
      await pending;
      _require(
        player.currentSong.value?.id == local.id && player.isPlaying.value,
        'New selection waited for the old lookup.',
      );
      final switchedMs = watch.elapsedMilliseconds;
      await Future<void>.delayed(const Duration(milliseconds: 3200));
      _require(
        player.currentSong.value?.id == local.id &&
            server.audioRequests['switch-slow'] == null,
        'Late lookup started obsolete audio.',
      );
      await player.pause();
      return {'switchedMs': switchedMs, 'obsoleteAudioRequests': 0};
    });

    await _check('online_end_of_track_beats_repeat_one', () async {
      player.playMode.value = PlayMode.repeatOne;
      final first = track('tone-b');
      await player.playQueue([first, local]);
      final before = server.resolveCounts['tone-b'];
      timer.startEndOfTrack(first.id);
      await _until(() => !timer.isActive && !player.isPlaying.value);
      await _until(() => timer.statusMessage.value == '定时已停止播放');
      _require(
        server.resolveCounts['tone-b'] == before,
        'Repeat resumed before timer.',
      );
      _require(
        player.position.value == player.duration.value,
        'End position was lost.',
      );
      return {
        'positionMs': player.position.value.inMilliseconds,
        'notice': timer.statusMessage.value,
      };
    });

    await _check(
      'persist_logical_online_identity_and_resume_position',
      () async {
        player.playMode.value = PlayMode.sequential;
        await player.playQueue([track('tone-a'), local]);
        await _until(() => player.isPlaying.value);
        await player.pause();
        await player.seek(const Duration(seconds: 2));
        final store = FileAppStateStore(Directory('${output.path}/state'));
        await store.load();
        await store.save(
          AppSnapshot(
            songs: [local],
            queue: player.queue.toList(),
            currentId: player.currentSong.value!.id,
            position: player.position.value,
            mode: player.playMode.value,
            volume: .01,
            skipOnError: false,
          ),
        );
        final json = await File(
          '${output.path}/state/state.json',
        ).readAsString();
        _require(
          !json.contains('http://') &&
              !json.contains('probe-only') &&
              json.contains('hanmusic://'),
          'Persisted a stream URL.',
        );
        return {
          'positionMs': player.position.value.inMilliseconds,
          'schemaVersion': 2,
        };
      },
    );
  }

  Future<void> _restore() async {
    await _check(
      'new_process_restores_without_autoplay_and_resolves_fresh_address',
      () async {
        _require(
          online.sources.length == 1,
          'Source store did not survive restart.',
        );
        final store = FileAppStateStore(Directory('${output.path}/state'));
        final snapshot = await store.load();
        _require(
          snapshot.queue.length == 2 && snapshot.queue.first.isOnline,
          'Mixed state lost.',
        );
        await player.restoreQueue(
          snapshot.queue,
          currentId: snapshot.currentId,
          position: snapshot.position,
          mode: snapshot.mode,
          volume: snapshot.volume,
          skipOnError: snapshot.skipOnError,
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
        _require(
          !player.isPlaying.value && server.resolveCounts.isEmpty,
          'Restart autoplayed/resolved early.',
        );
        _require(
          player.position.value.inMilliseconds >= 1900,
          'Saved progress lost.',
        );
        // The new process listens on a new port. Stable IDs must resolve using
        // the edited source configuration, never yesterday's temporary URL.
        _require(
          await online.upsertSource(
            OnlineSourceConfig.fromJson(server.configJson()),
          ),
          'Source edit failed.',
        );
        final before = server.resolveCounts['tone-a'] ?? 0;
        await player.togglePlayback();
        await _until(
          () =>
              player.isPlaying.value &&
              player.position.value.inMilliseconds >= 1900,
        );
        _require(
          server.resolveCounts['tone-a'] == before + 1,
          'Playback did not resolve again.',
        );
        await player.pause();
        return {
          'queueCount': player.queue.length,
          'restoredPositionMs': snapshot.position.inMilliseconds,
          'freshResolution': true,
        };
      },
    );
    await _check('deleted_source_preserves_queue_and_reports_error', () async {
      await online.removeSource('local-demo');
      await player.playQueue([track('tone-a'), local]);
      _require(
        player.queue.length == 2 &&
            !player.isPlaying.value &&
            player.errorMessage.value != null,
        'Missing source was lost or silently played.',
      );
      return {
        'notice': player.errorMessage.value,
        'queueCount': player.queue.length,
      };
    });
  }

  Future<void> _check(
    String name,
    Future<Map<String, Object?>> Function() action,
  ) async {
    final watch = Stopwatch()..start();
    try {
      final observations = await action().timeout(const Duration(seconds: 40));
      checks.add({
        'name': name,
        'status': 'passed',
        'elapsedMs': watch.elapsedMilliseconds,
        'observations': observations,
      });
    } catch (error) {
      checks.add({'name': name, 'status': 'failed', 'error': '$error'});
      rethrow;
    }
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> _until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 25)) {
      throw TimeoutException('Condition not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}
