// Native M3 diagnostic; never use this entry as the shipping application.
// Provide the generated M2 fixtures in <HANMUSIC_PROBE_DIR>/fixtures/.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/play_mode.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/data/sources/audio_backend.dart';
import 'package:han_music/app/data/sources/just_audio_backend.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/sleep_timer_coordinator.dart';
import 'package:han_music/app/services/timer_service.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('HANMUSIC_PROBE_DIR');
  if (root.isEmpty) exit(2);
  initializeAudioBackend();
  final probe = _Probe(Directory(root));
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

class _Probe {
  _Probe(this.output) {
    backend = _CountingBackend(JustAudioBackend());
    player = PlayerService(backend);
    timer = TimerService(onExpired: player.pause, now: () => now);
    coordinator = SleepTimerCoordinator(player: player, timer: timer);
    controller = PlayerController(
      player: player,
      timer: timer,
      picker: _UnusedPicker(),
    );
  }

  final Directory output;
  DateTime now = DateTime.now();
  late final _CountingBackend backend;
  late final PlayerService player;
  late final TimerService timer;
  late final SleepTimerCoordinator coordinator;
  late final PlayerController controller;
  final checks = <Map<String, Object?>>[];
  final frameworkErrors = <String>[];

  Song song(String name) =>
      Song(uri: File('${output.path}/fixtures/$name').uri, fileName: name);

  Future<void> run() async {
    final started = DateTime.now().toUtc();
    final watchdog = Timer(const Duration(minutes: 3), () => exit(3));
    String? fatal;
    try {
      await output.create(recursive: true);
      await player.setVolume(.01);
      final alpha = song('01-alpha.flac');
      final beta = song('02-beta.mp3');
      final wave = song('03-wave.wav');
      for (final source in [alpha, beta, wave]) {
        _require(
          await File.fromUri(source.uri).exists(),
          'Missing fixture ${source.fileName}',
        );
      }

      await _check('end_of_track_stops_repeat_one_at_final_position', () async {
        player.playMode.value = PlayMode.repeatOne;
        await player.playQueue([alpha, beta]);
        await _until(() => player.isPlaying.value);
        final loads = backend.loads.length;
        timer.startEndOfTrack(alpha.id);
        await _until(() => !timer.isActive && !player.isPlaying.value);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        _require(
          backend.loads.length == loads,
          'Repeat-one reloaded the source before stopping.',
        );
        _require(
          player.currentSong.value?.id == alpha.id && player.queue.length == 2,
          'Current track/queue lost.',
        );
        _require(
          player.position.value == player.duration.value &&
              player.duration.value.inMilliseconds > 1000,
          'Completion lost the final position.',
        );
        return {
          'nativeLoadsAfterArming': backend.loads.length - loads,
          'positionMs': player.position.value.inMilliseconds,
          'notice': timer.statusMessage.value,
        };
      });

      await _check('cancel_end_of_track_allows_natural_next', () async {
        player.playMode.value = PlayMode.sequential;
        await player.playQueue([alpha, beta]);
        timer.startEndOfTrack(alpha.id);
        timer.cancel();
        await _until(
          () =>
              player.currentSong.value?.id == beta.id && player.isPlaying.value,
        );
        await player.pause();
        return {'current': player.currentSong.value?.fileName};
      });

      await _check('manual_next_cancels_end_of_track', () async {
        await player.playQueue([wave, beta]);
        timer.startEndOfTrack(wave.id);
        await player.next();
        await _until(
          () =>
              player.currentSong.value?.id == beta.id && player.isPlaying.value,
        );
        _require(
          !timer.isActive,
          'Manual navigation retained the old track timer.',
        );
        await player.pause();
        return {
          'cancelled': true,
          'current': player.currentSong.value?.fileName,
        };
      });

      await _check(
        'extend_original_deadline_and_simulated_resume_pauses',
        () async {
          await player.playQueue([wave, beta]);
          await _until(() => player.position.value.inMilliseconds > 150);
          now = DateTime.now();
          timer.start(const Duration(minutes: 5));
          final original = timer.deadline.value!;
          now = now.add(const Duration(minutes: 1));
          _require(timer.extend10Minutes(), 'Active countdown did not extend.');
          _require(
            timer.deadline.value == original.add(const Duration(minutes: 10)),
            'Extension restarted from now instead of the original deadline.',
          );
          now = original.add(const Duration(minutes: 1));
          controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          _require(
            player.isPlaying.value,
            'The original deadline still paused audio.',
          );
          now = original.add(const Duration(minutes: 11));
          controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await _until(() => !player.isPlaying.value && !timer.isActive);
          _require(
            player.currentSong.value?.id == wave.id && player.queue.length == 2,
            'Expiry cleared the queue.',
          );
          _require(
            player.position.value > Duration.zero,
            'Expiry reset progress.',
          );
          return {
            'extensionMinutes': 10,
            'paused': true,
            'positionMs': player.position.value.inMilliseconds,
            'resumeWasSimulated': true,
          };
        },
      );

      await _check('overdue_completion_cannot_load_next_track', () async {
        await player.playQueue([alpha, beta]);
        final loads = backend.loads.length;
        now = DateTime.now();
        timer.start(const Duration(minutes: 10));
        // Move only the injected clock, then finish the short native source.
        // No explicit deadline check: the playback boundary must catch expiry.
        now = now.add(const Duration(hours: 1));
        await player.seek(
          player.duration.value - const Duration(milliseconds: 100),
        );
        await _until(() => !timer.isActive && !player.isPlaying.value);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        _require(
          backend.loads.length == loads,
          'Overdue completion loaded the next source.',
        );
        _require(
          player.currentSong.value?.id == alpha.id,
          'Overdue completion changed the track.',
        );
        return {
          'nativeLoadsAfterArming': backend.loads.length - loads,
          'current': player.currentSong.value?.fileName,
        };
      });

      await _check('replacement_invalidates_pending_expiration', () async {
        await player.playQueue([wave, beta]);
        now = DateTime.now();
        timer.start(const Duration(seconds: 1));
        now = now.add(const Duration(seconds: 2));
        timer.checkDeadline();
        timer.start(const Duration(minutes: 2));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        _require(
          timer.isActive && player.isPlaying.value,
          'Old queued expiry paused the replacement session.',
        );
        timer.cancel();
        await player.pause();
        return {'oldExpirationInvalidated': true};
      });
    } catch (error, stack) {
      fatal = '$error\n$stack';
    } finally {
      coordinator.onClose();
      timer.onClose();
      controller.onDelete();
      try {
        await player.shutdown().timeout(const Duration(seconds: 15));
      } catch (error) {
        fatal ??= 'Shutdown failed: $error';
      }
      watchdog.cancel();
      final passed =
          fatal == null &&
          frameworkErrors.isEmpty &&
          checks.length == 6 &&
          checks.every((check) => check['status'] == 'passed');
      await File('${output.path}/result-m3.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'startedAt': started.toIso8601String(),
          'finishedAt': DateTime.now().toUtc().toIso8601String(),
          'os': Platform.operatingSystemVersion,
          'passed': passed,
          'fatalError': fatal,
          'checks': checks,
          'frameworkErrors': frameworkErrors,
          'limitations': [
            'Uses actual native audio with generated low-volume fixtures; does not measure audible output.',
            'Clock advancement and lifecycle resume are injected, not actual Windows sleep or power broadcasts.',
            'Does not operate native file dialogs, minimize, or the close button.',
          ],
        }),
        flush: true,
      );
      exit(passed ? 0 : 1);
    }
  }

  Future<void> _check(
    String name,
    Future<Map<String, Object?>> Function() action,
  ) async {
    final watch = Stopwatch()..start();
    try {
      final observations = await action().timeout(const Duration(seconds: 25));
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

class _CountingBackend implements AudioBackend {
  _CountingBackend(this.delegate);
  final AudioBackend delegate;
  final loads = <Uri>[];
  @override
  Stream<BackendPlaybackState> get states => delegate.states;
  @override
  Stream<Duration> get positions => delegate.positions;
  @override
  Stream<Duration?> get durations => delegate.durations;
  @override
  Stream<Object> get errors => delegate.errors;
  @override
  Future<Duration?> load(Uri uri) {
    loads.add(uri);
    return delegate.load(uri);
  }

  @override
  Future<void> play() => delegate.play();
  @override
  Future<void> pause() => delegate.pause();
  @override
  Future<void> seek(Duration position) => delegate.seek(position);
  @override
  Future<void> setVolume(double value) => delegate.setVolume(value);
  @override
  Future<void> dispose() => delegate.dispose();
}

class _UnusedPicker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}

Future<void> _until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 15)) {
      throw TimeoutException('Condition not reached.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

void _require(bool value, String message) {
  if (!value) throw StateError(message);
}
