// Production service/controller/UI diagnostic, separate from lib/main.dart.
// flutter build windows --release -t tool/windows_app_probe.dart \
//   --dart-define=HANMUSIC_PROBE_DIR=D:/dev/tmp/hanmusic-audio-probe
// Supply sample.mp3 and sample.flac in that directory. A quiet WAV is generated.
// phase-app.json marks the 30-second window for manual minimization checks.
// result-app.json records each case, framework errors and actual lifecycle events.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/data/sources/just_audio_backend.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/view.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

const _caseTimeout = Duration(seconds: 28);
const _observationDuration = Duration(seconds: 30);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const outputPath = String.fromEnvironment('HANMUSIC_PROBE_DIR');
  if (outputPath.isEmpty) {
    stderr.writeln(
      'Set --dart-define=HANMUSIC_PROBE_DIR to the fixture directory.',
    );
    exit(2);
  }
  final output = Directory(outputPath);
  await output.create(recursive: true);
  try {
    initializeAudioBackend();
    final probe = _AppProbe(output);
    FlutterError.onError = (details) {
      probe.frameworkErrors.add('${details.exception}\n${details.stack}');
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      probe.frameworkErrors.add('$error\n$stack');
      return true;
    };
    probe.controller.onStart();
    WidgetsBinding.instance.addObserver(probe);
    runApp(
      GetMaterialApp(
        title: 'HanMusic App Probe',
        debugShowCheckedModeBanner: false,
        theme: HanMusicTheme.light,
        home: PlayerPage(controller: probe.controller),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(probe.run());
    });
  } catch (error, stack) {
    await _writeJson(File('${output.path}/result-app.json'), {
      'schemaVersion': 1,
      'passed': false,
      'fatalError': '$error\n$stack',
      'checks': <Object>[],
    });
    exit(1);
  }
}

class _AppProbe with WidgetsBindingObserver {
  _AppProbe(this.output) {
    player = PlayerService(JustAudioBackend());
    timer = TimerService(
      onExpired: player.pause,
      onError: (error, stack) => frameworkErrors.add('$error\n$stack'),
    );
    controller = PlayerController(player: player, timer: timer, picker: picker);
  }

  final Directory output;
  final picker = _FixtureSongPicker();
  final frameworkErrors = <String>[];
  final lifecycleEvents = <Map<String, Object?>>[];
  final checks = <Map<String, Object?>>[];
  late final PlayerService player;
  late final TimerService timer;
  late final PlayerController controller;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    lifecycleEvents.add({
      'state': state.name,
      'at': DateTime.now().toUtc().toIso8601String(),
      'positionMs': controller.position.value.inMilliseconds,
      'playing': controller.isPlaying.value,
    });
  }

  Future<void> run() async {
    final started = DateTime.now().toUtc();
    String? fatalError;
    final watchdog = Timer(const Duration(minutes: 4), () {
      unawaited(() async {
        await _writeJson(File('${output.path}/result-app.json'), {
          'schemaVersion': 1,
          'passed': false,
          'fatalError': 'Overall diagnostic exceeded four minutes.',
          'checks': checks,
          'frameworkErrors': frameworkErrors,
          'lifecycleEvents': lifecycleEvents,
        });
        exit(1);
      }());
    });

    try {
      final fixtureDirectory = Directory('${output.path}/中文 音频');
      await fixtureDirectory.create(recursive: true);
      final wav = File('${fixtureDirectory.path}/应用探针 曲目.wav');
      await wav.writeAsBytes(_quietWav());
      final corrupt = File('${output.path}/app-corrupt.wav');
      await corrupt.writeAsString('Intentionally invalid audio fixture.');
      await controller.setVolume(0.01).timeout(_caseTimeout);
      _require(controller.errorMessage.value == null, 'Volume setup failed.');

      await _check('wav_import_and_autoplay', () => _importAndPlay(wav));
      await _check('pause_seek_resume', () async {
        await controller.togglePlayback();
        await _waitUntil(
          () => !controller.isPlaying.value,
          'Audio did not pause.',
        );
        final pausedAt = controller.position.value;
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final pauseDrift = (controller.position.value - pausedAt).abs();
        _require(
          pauseDrift.inMilliseconds < 250,
          'Position advanced while paused.',
        );

        const target = Duration(seconds: 2);
        await controller.seek(target);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final seekError = (controller.position.value - target).abs();
        _require(
          seekError.inMilliseconds < 700,
          'Seek did not reach the target.',
        );
        await controller.togglePlayback();
        await _waitUntil(
          () =>
              controller.isPlaying.value &&
              controller.position.value >
                  target + const Duration(milliseconds: 250),
          'Playback position did not advance after resume.',
        );
        return {..._snapshot(), 'pauseDriftMs': pauseDrift.inMilliseconds};
      });

      for (final extension in ['mp3', 'flac']) {
        await _check(
          '${extension}_import_and_autoplay',
          () => _importAndPlay(File('${output.path}/sample.$extension')),
        );
      }

      await _check('one_second_sleep_timer_pauses', () async {
        await _importAndPlay(wav);
        final watch = Stopwatch()..start();
        controller.startSleepTimer(const Duration(seconds: 1));
        await _waitUntil(
          () =>
              controller.timerRemaining.value == null &&
              !controller.isPlaying.value,
          'Sleep timer did not clear and pause audio.',
          timeout: const Duration(seconds: 5),
        );
        _require(
          watch.elapsedMilliseconds >= 700,
          'Sleep timer expired too early.',
        );
        return {..._snapshot(), 'expirationMs': watch.elapsedMilliseconds};
      });

      await _check('cancelled_sleep_timer_keeps_playing', () async {
        await controller.togglePlayback();
        await _waitUntil(
          () => controller.isPlaying.value,
          'Audio did not resume.',
        );
        final initialPosition = controller.position.value;
        controller.startSleepTimer(const Duration(seconds: 1));
        controller.cancelSleepTimer();
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        _require(
          controller.timerRemaining.value == null,
          'Timer was not cancelled.',
        );
        _require(
          controller.isPlaying.value,
          'Cancelled timer paused playback.',
        );
        _require(
          controller.position.value >
              initialPosition + const Duration(milliseconds: 700),
          'Playback stopped advancing after timer cancellation.',
        );
        return _snapshot();
      });

      await _check('damaged_file_disables_playback', () async {
        picker.nextFile = corrupt;
        await controller.importFile();
        await _waitUntil(
          () =>
              !controller.isLoading.value &&
              controller.errorMessage.value != null,
          'Damaged audio did not produce an application error.',
        );
        _require(!controller.canPlay, 'Damaged source left playback enabled.');
        await controller.togglePlayback();
        _require(
          !controller.isPlaying.value,
          'Damaged source resumed playback.',
        );
        return _snapshot();
      });

      await _check('reimport_recovers_after_damaged_file', () async {
        final result = await _importAndPlay(wav);
        _require(
          controller.errorMessage.value == null,
          'Prior error was not cleared.',
        );
        return result;
      });

      await _check('playback_observation_30s', () async {
        // This visible phase lets the operator minimize and restore the real UI.
        final initialPosition = controller.position.value;
        final initialEventCount = lifecycleEvents.length;
        await _phase('playback_observation_30s', {
          'expectedFinishAt': DateTime.now()
              .toUtc()
              .add(_observationDuration)
              .toIso8601String(),
          'instruction':
              'Minimize and restore the application during this phase.',
        });
        await Future<void>.delayed(_observationDuration);
        final advanced = controller.position.value - initialPosition;
        _require(
          controller.isPlaying.value,
          'Playback stopped during observation.',
        );
        _require(
          advanced.inSeconds >= 25,
          'Playback did not advance for the observation period.',
        );
        _require(
          controller.errorMessage.value == null,
          'Application reported an audio error.',
        );
        final observedEvents = lifecycleEvents.sublist(initialEventCount);
        return {
          ..._snapshot(),
          'advancedMs': advanced.inMilliseconds,
          'lifecycleEvents': observedEvents,
          'hiddenObserved': observedEvents.any(
            (event) => event['state'] == 'hidden',
          ),
          'resumedObserved': observedEvents.any(
            (event) => event['state'] == 'resumed',
          ),
        };
      }, timeout: const Duration(seconds: 40));
    } catch (error, stack) {
      fatalError = '$error\n$stack';
    } finally {
      controller.onDelete();
      timer.onClose();
      WidgetsBinding.instance.removeObserver(this);
      try {
        await player.shutdown().timeout(const Duration(seconds: 10));
      } catch (error, stack) {
        fatalError ??= 'Shutdown failed: $error\n$stack';
      }
      watchdog.cancel();
      final passed =
          fatalError == null &&
          frameworkErrors.isEmpty &&
          checks.isNotEmpty &&
          checks.every((check) => check['status'] == 'passed');
      await _writeJson(File('${output.path}/result-app.json'), {
        'schemaVersion': 1,
        'startedAt': started.toIso8601String(),
        'finishedAt': DateTime.now().toUtc().toIso8601String(),
        'os': Platform.operatingSystemVersion,
        'dartVersion': Platform.version,
        'passed': passed,
        'fatalError': fatalError,
        'checks': checks,
        'frameworkErrors': frameworkErrors,
        'lifecycleEvents': lifecycleEvents,
        'limitations': [
          'The fixture picker intentionally bypasses the native file dialog.',
          'Clock and state checks do not verify audible speaker output.',
          'Minimization is only observed when actual hidden/resumed events are recorded.',
          'System sleep, device changes and clean-machine packaging need separate checks.',
        ],
      });
      await _phase('complete', {'passed': passed});
      exit(passed ? 0 : 1);
    }
  }

  Future<Map<String, Object?>> _importAndPlay(File file) async {
    _require(await file.exists(), 'Missing fixture: ${file.path}');
    picker.nextFile = file;
    await controller.importFile();
    await _waitUntil(
      () =>
          controller.canPlay &&
          controller.isPlaying.value &&
          controller.duration.value > Duration.zero &&
          controller.position.value > const Duration(milliseconds: 100),
      'Import did not reach playing with an advancing position: ${file.path}',
    );
    _require(
      controller.currentSong.value?.uri == file.absolute.uri,
      'Wrong source imported.',
    );
    _require(
      controller.errorMessage.value == null,
      'Import reported an application error.',
    );
    return _snapshot();
  }

  Future<void> _check(
    String name,
    Future<Map<String, Object?>> Function() action, {
    Duration timeout = _caseTimeout,
  }) async {
    await _phase(name);
    final watch = Stopwatch()..start();
    try {
      final observations = await action().timeout(timeout);
      checks.add({
        'name': name,
        'status': 'passed',
        'elapsedMs': watch.elapsedMilliseconds,
        'observations': observations,
      });
    } catch (error, stack) {
      checks.add({
        'name': name,
        'status': 'failed',
        'elapsedMs': watch.elapsedMilliseconds,
        'error': '$error',
        'stack': '$stack',
        'state': _snapshot(),
      });
      // A timed-out native call is still in flight. Avoid contaminating later cases.
      if (error is TimeoutException) rethrow;
    }
  }

  Map<String, Object?> _snapshot() => {
    'file': controller.currentSong.value?.path,
    'positionMs': controller.position.value.inMilliseconds,
    'durationMs': controller.duration.value.inMilliseconds,
    'playing': controller.isPlaying.value,
    'loading': controller.isLoading.value,
    'canPlay': controller.canPlay,
    'volume': controller.volume.value,
    'error': controller.errorMessage.value,
    'timerRemainingMs': controller.timerRemaining.value?.inMilliseconds,
  };

  Future<void> _phase(String name, [Map<String, Object?> extra = const {}]) =>
      _writeJson(File('${output.path}/phase-app.json'), {
        'phase': name,
        'at': DateTime.now().toUtc().toIso8601String(),
        ...extra,
      });
}

class _FixtureSongPicker implements SongPicker {
  File? nextFile;

  @override
  Future<Song?> pick() async {
    final file = nextFile;
    nextFile = null;
    if (file == null) return null;
    if (!await file.exists()) {
      throw FileSystemException('Missing fixture.', file.path);
    }
    return Song(uri: file.absolute.uri, fileName: file.uri.pathSegments.last);
  }
}

Future<void> _waitUntil(
  bool Function() predicate,
  String failure, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    if (watch.elapsed >= timeout) throw StateError(failure);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> _writeJson(File file, Map<String, Object?> value) =>
    file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true,
    );

Uint8List _quietWav() {
  const sampleRate = 22050;
  const sampleCount = sampleRate * 60;
  const dataLength = sampleCount * 2;
  final data = ByteData(44 + dataLength);
  final bytes = data.buffer.asUint8List();
  void marker(int offset, String value) =>
      bytes.setAll(offset, ascii.encode(value));
  marker(0, 'RIFF');
  data.setUint32(4, 36 + dataLength, Endian.little);
  marker(8, 'WAVE');
  marker(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  marker(36, 'data');
  data.setUint32(40, dataLength, Endian.little);
  for (var index = 0; index < sampleCount; index++) {
    final sample = (1200 * math.sin(2 * math.pi * 220 * index / sampleRate))
        .round();
    data.setInt16(44 + index * 2, sample, Endian.little);
  }
  return bytes;
}
