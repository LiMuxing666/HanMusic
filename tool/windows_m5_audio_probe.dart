// Standalone M5 diagnostic. Build the product entrypoint again before shipping.
// Generate fixtures with tool/generate_m5_audio_fixtures.ps1, then build:
// flutter build windows --release -t tool/windows_m5_audio_probe.dart \
//   --dart-define=HANMUSIC_PROBE_DIR=D:/dev/tmp/hanmusic-m5-audio
// Run once with HANMUSIC_PROBE_PHASE=all, then in a NEW process with
// HANMUSIC_PROBE_PHASE=cold-network. No OS cache flush or audible-output claim.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:han_music/app/data/models/online_source_config.dart';
import 'package:han_music/app/data/models/play_mode.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/online_music_repository.dart';
import 'package:han_music/app/data/repositories/online_source_store.dart';
import 'package:han_music/app/data/sources/audio_backend.dart';
import 'package:han_music/app/data/sources/just_audio_backend.dart';
import 'package:han_music/app/services/online_music_service.dart';
import 'package:han_music/app/services/player_service.dart';

import 'online_fixture_server.dart';

const _operationTimeout = Duration(seconds: 18);
const _eventTimeout = Duration(seconds: 5);
const _volume = .02;
const _formats = ['mp3', 'flac', 'wav', 'm4a', 'ogg', 'aac'];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const directory = String.fromEnvironment('HANMUSIC_PROBE_DIR');
  if (directory.isEmpty || !Platform.isWindows) exit(2);
  initializeAudioBackend();
  final probe = _M5Probe(Directory(directory));
  FlutterError.onError = (details) =>
      probe.frameworkErrors.add(_safe(details.exception));
  PlatformDispatcher.instance.onError = (error, stack) {
    probe.frameworkErrors.add(_safe(error));
    return true;
  };
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('HanMusic M5 音频验证'))),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(probe.run()));
}

class _M5Probe {
  _M5Probe(this.output);
  final Directory output;
  final phase = Platform.environment['HANMUSIC_PROBE_PHASE'] ?? 'all';
  final started = DateTime.now().toUtc();
  final checks = <Map<String, Object?>>[];
  final frameworkErrors = <String>[];
  final samples = <Map<String, Object?>>[];
  final startupFailures = <Map<String, Object?>>[];
  final activeBackends = <_ObservedBackend>{};
  Map<String, dynamic>? manifest;
  Map<String, Object?>? benchmarkAudio;
  OnlineFixtureServer? server;
  OnlineMusicService? online;
  String? currentCheck;
  bool watchdogTriggered = false;

  File fixture(String extension) =>
      File('${output.path}/中文 空格/测试 音频.$extension');
  Song local(String extension) =>
      Song(uri: fixture(extension).uri, fileName: '测试 音频.$extension');
  Song network(String id) =>
      Song.online(sourceId: 'local-demo', trackId: id, title: '测试 $id');

  _ObservedBackend createBackend() {
    final value = _ObservedBackend(JustAudioBackend());
    activeBackends.add(value);
    return value;
  }

  Future<void> release(_ObservedBackend value) async {
    try {
      await value.close();
    } finally {
      activeBackends.remove(value);
    }
  }

  Future<void> run() async {
    await output.create(recursive: true);
    final watchdog = Timer(const Duration(seconds: 235), () {
      watchdogTriggered = true;
      File('${output.path}/result-m5-audio-$phase.json').writeAsStringSync(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(report('Probe exceeded 235-second watchdog.')),
        flush: true,
      );
      exit(3);
    });
    String? fatal;
    try {
      _require(
        {'all', 'cold-network'}.contains(phase),
        'Unsupported probe phase.',
      );
      await check('generated_fixture_integrity', () async {
        final raw = await File('${output.path}/fixtures.json').readAsString();
        manifest =
            jsonDecode(raw.replaceFirst('\uFEFF', '')) as Map<String, dynamic>;
        _require(
          manifest!['schemaVersion'] == 1,
          'Unsupported fixture manifest.',
        );
        final entries = manifest!['fixtures'] as List;
        final observations = <Map<String, Object?>>[];
        for (final extension in _formats) {
          final entry = entries.cast<Map<String, dynamic>>().singleWhere(
            (item) => item['format'] == extension,
          );
          final bytes = await fixture(extension).readAsBytes();
          _require(
            sha256.convert(bytes).toString() == entry['sha256'],
            'Fixture hash mismatch: $extension',
          );
          _require(
            entry['ffmpegDecodeVerified'] == true,
            'Fixture was not independently decoded: $extension',
          );
          observations.add({
            'format': extension,
            'bytes': bytes.length,
            'codec': entry['codec'],
            'container': entry['container'],
            'sha256': entry['sha256'],
          });
        }
        return {'generatedFormats': observations, 'unicodeAndSpaces': true};
      });
      _require(
        checks.last['status'] == 'passed',
        'Fixture integrity must pass before any audio is played.',
      );
      final benchmarkBytes = createFixtureWav();
      await File(
        '${output.path}/benchmark-local.wav',
      ).writeAsBytes(benchmarkBytes);
      benchmarkAudio = {
        'format': 'PCM s16le WAV',
        'sampleRateHz': 22050,
        'channels': 1,
        'durationSeconds': 6,
        'sha256': sha256.convert(benchmarkBytes).toString(),
        'sameBytesForLocalAndLoopback': true,
      };

      // No audio backend has been created before this local cold sample.
      if (phase == 'all') {
        await check(
          'local_cold_and_10_warm_starts',
          () => startSeries(networkSource: false),
        );
      }
      server = await OnlineFixtureServer.start();
      _require(
        sha256.convert(server!.audio).toString() == benchmarkAudio!['sha256'],
        'Local/network benchmark fixtures differ.',
      );
      online = OnlineMusicService(
        repository: OnlineMusicRepository(),
        store: FileOnlineSourceStore(
          Directory('${output.path}/sources-$phase'),
        ),
      );
      await online!.initialize();
      await check('loopback_source_setup', () async {
        _require(
          await online!.upsertSource(
            OnlineSourceConfig.fromJson(server!.configJson()),
          ),
          'Could not configure loopback fixture source.',
        );
        return {
          'sourceId': 'local-demo',
          'authentication': 'anonymous',
          'requests': server!.searchCount,
        };
      });
      await check(
        phase == 'cold-network'
            ? 'network_cold_new_process'
            : 'network_warmup_and_10_warm_starts',
        () => startSeries(networkSource: true),
      );

      if (phase == 'all') {
        for (final extension in _formats) {
          await check(
            '${extension}_native_play_pause_seek_completion',
            () => formatControls(extension),
          );
        }
        await check('corrupt_file_failure_and_same_backend_recovery', recovery);
        await check(
          'mixed_local_network_queue_and_expired_url_recovery',
          mixedQueue,
        );
      }
    } catch (error) {
      fatal = _safe(error);
    } finally {
      for (final backend in activeBackends.toList()) {
        try {
          await release(backend);
        } catch (error) {
          fatal ??= 'Backend cleanup: ${_safe(error)}';
        }
      }
      try {
        await online?.close().timeout(const Duration(seconds: 5));
        await server?.close().timeout(const Duration(seconds: 5));
      } catch (error) {
        fatal ??= 'Service cleanup: ${_safe(error)}';
      }
      final value = report(fatal);
      await File('${output.path}/result-m5-audio-$phase.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(value),
        flush: true,
      );
      watchdog.cancel();
      exit(value['passed'] == true ? 0 : 1);
    }
  }

  Map<String, Object?> report(String? fatal) => {
    'schemaVersion': 1,
    'phase': phase,
    'startedAt': started.toIso8601String(),
    'finishedAt': DateTime.now().toUtc().toIso8601String(),
    'os': Platform.operatingSystemVersion,
    'dartVersion': Platform.version,
    'backend':
        'production JustAudioBackend / just_audio_media_kit / media_kit Windows native decoder',
    'backendVersionsFromFixtureGenerationLockfile':
        manifest?['backendVersionsFromLockfile'],
    'ffmpegVersion': manifest?['ffmpegVersion'],
    'benchmarkAudio': benchmarkAudio,
    'passed':
        !watchdogTriggered &&
        fatal == null &&
        frameworkErrors.isEmpty &&
        checks.isNotEmpty &&
        checks.every((value) => value['status'] == 'passed'),
    'watchdogSeconds': 235,
    'watchdogTriggered': watchdogTriggered,
    'currentCheck': currentCheck,
    'fatalError': fatal,
    'frameworkErrors': frameworkErrors,
    'checks': checks,
    'startupSamples': samples,
    'startupFailures': startupFailures,
    'timingDefinition': {
      'start':
          'Immediately before optional resolveForPlayback and backend.load; backend object and low volume are prepared beforehand.',
      'end':
          'Both playing=true/nonloading state and first subsequent nonzero position event after play() request are observed; end is the later event.',
      'segments': [
        'resolveMs',
        'loadAndReadyMs',
        'playToPlayingEventMs',
        'playToFirstNonzeroPositionMs',
        'totalToBothEventsMs',
      ],
      'cold':
          'First native source load in a fresh probe process after Flutter/plugin setup. OS filesystem cache is not flushed.',
      'warm':
          '10 subsequent fresh source loads into the same backend. Network sample resolves a new temporary URI every time.',
      'p95':
          'Nearest rank ceil(0.95*n); with n=10 this is the largest sample. Descriptive only, no audio-output threshold verdict.',
    },
    'limitations': [
      'Backend position events may interpolate from native clock anchors. They do not measure the sound card, speaker, DAC or audible first sample.',
      'Flutter/process launch time and audio device initialization before load() are outside the stopwatch.',
      'Loopback timings exclude real Internet latency, TLS handshakes, commercial APIs and authentication.',
      'Six generated codec/container samples do not cover all profiles, damaged media, bit rates, tags or large libraries.',
      'No OS sleep, sound-device switch, audio loopback capture or clean-machine deployment is validated by this probe.',
      'The production adapter bounds the known bridge error-stream/load-Future hang; this does not fix upstream just_audio_media_kit.',
    ],
  };

  Future<void> check(
    String name,
    Future<Map<String, Object?>> Function() action,
  ) async {
    currentCheck = name;
    final watch = Stopwatch()..start();
    try {
      final observations = await action().timeout(const Duration(seconds: 35));
      checks.add({
        'name': name,
        'status': 'passed',
        'elapsedMs': watch.elapsedMilliseconds,
        'observations': observations,
      });
    } catch (error) {
      checks.add({
        'name': name,
        'status': 'failed',
        'elapsedMs': watch.elapsedMilliseconds,
        'error': _safe(error),
      });
      // A stalled operation must not overlap the next native player scenario.
      if (error is TimeoutException) rethrow;
    }
    await File('${output.path}/progress-m5-audio-$phase.json').writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'phase': phase, 'currentCheck': name, 'checks': checks}),
      flush: true,
    );
    currentCheck = null;
  }

  Future<Map<String, Object?>> startSeries({
    required bool networkSource,
  }) async {
    final observed = createBackend();
    final transport = networkSource ? 'loopback' : 'local';
    final records = <Map<String, Object?>>[];
    try {
      await observed.backend.setVolume(_volume).timeout(_eventTimeout);
      final firstKind = !networkSource || phase == 'cold-network'
          ? 'cold_process_first_load'
          : 'warmup_after_local_native_use';
      records.add(
        await startOnce(
          observed,
          transport: transport,
          kind: firstKind,
          index: 0,
        ),
      );
      final warmCount = phase == 'cold-network' ? 0 : 10;
      for (var index = 1; index <= warmCount; index++) {
        records.add(
          await startOnce(
            observed,
            transport: transport,
            kind: 'warm',
            index: index,
          ),
        );
      }
      final warm = records.where((item) => item['kind'] == 'warm').toList();
      return {
        'firstSample': records.first,
        'warmCount': warm.length,
        'warmSummariesMs': {
          for (final key in [
            'resolveMs',
            'loadAndReadyMs',
            'playToPlayingEventMs',
            'playToFirstNonzeroPositionMs',
            'totalToBothEventsMs',
          ])
            key: summarize(warm, key),
        },
        'soundCardThresholdAssessed': false,
      };
    } finally {
      await release(observed);
    }
  }

  Future<Map<String, Object?>> startOnce(
    _ObservedBackend observed, {
    required String transport,
    required String kind,
    required int index,
  }) async {
    await observed.backend.pause().timeout(_eventTimeout);
    observed.disarm();
    final errorBaseline = observed.errorTypes.length;
    final watch = Stopwatch()..start();
    var stage = 'resolve';
    final positionBeforeLoad = observed.position.inMilliseconds;
    final positionEventsBeforeLoad = observed.positionEvents;
    try {
      final uri = transport == 'local'
          ? File('${output.path}/benchmark-local.wav').uri
          : await online!
                .resolveForPlayback(network('tone-a'))
                .timeout(_eventTimeout);
      final resolvedUs = watch.elapsedMicroseconds;
      stage = 'load';
      final duration = await observed.backend
          .load(uri)
          .timeout(_operationTimeout);
      stage = 'await_loaded_paused_zero';
      // positionStream is distinct(). If pause already emitted native position 0,
      // a new source at the same position need not emit another 0. The completed
      // load and paused/ready state establish the new source boundary instead.
      await _until(
        () =>
            !observed.loading &&
            !observed.playing &&
            observed.position == Duration.zero,
        stage: stage,
      );
      final loadedUs = watch.elapsedMicroseconds;
      observed.arm(watch);
      stage = 'await_playing_and_nonzero';
      await observed.backend.play().timeout(_eventTimeout);
      await _until(
        () =>
            observed.firstPlayingUs != null && observed.firstPositionUs != null,
        stage: stage,
      );
      _require(
        observed.errorTypes.length == errorBaseline,
        'Unexpected native error during startup.',
      );
      final endUs = math.max(
        observed.firstPlayingUs!,
        observed.firstPositionUs!,
      );
      final value = <String, Object?>{
        'transport': transport,
        'kind': kind,
        'index': index,
        'format': 'wav',
        'durationMs': duration?.inMilliseconds,
        'resolveMs': transport == 'local' ? 0 : resolvedUs / 1000,
        'loadAndReadyMs': (loadedUs - resolvedUs) / 1000,
        'playToPlayingEventMs': (observed.firstPlayingUs! - loadedUs) / 1000,
        'playToFirstNonzeroPositionMs':
            (observed.firstPositionUs! - loadedUs) / 1000,
        'totalToBothEventsMs': endUs / 1000,
        'firstNonzeroPositionMs': observed.firstPositionMs,
      };
      samples.add(value);
      stage = 'pause_after_sample';
      await observed.backend.pause().timeout(_eventTimeout);
      return value;
    } catch (error) {
      startupFailures.add({
        'transport': transport,
        'kind': kind,
        'index': index,
        'stage': stage,
        'elapsedMs': watch.elapsedMilliseconds,
        'error': _safe(error),
        'positionBeforeLoadMs': positionBeforeLoad,
        'positionEventsBeforeLoad': positionEventsBeforeLoad,
        'positionMs': observed.position.inMilliseconds,
        'positionEvents': observed.positionEvents,
        'playing': observed.playing,
        'loading': observed.loading,
        'completed': observed.completed,
        'firstPlayingUs': observed.firstPlayingUs,
        'firstNonzeroPositionUs': observed.firstPositionUs,
        'errorTypes': List<String>.of(observed.errorTypes),
        'nativeStates': List.of(observed.stateTrace),
      });
      rethrow;
    }
  }

  Future<Map<String, Object?>> formatControls(String extension) async {
    final observed = createBackend();
    try {
      await observed.backend.setVolume(_volume).timeout(_eventTimeout);
      final duration = await observed.backend
          .load(fixture(extension).uri)
          .timeout(_operationTimeout);
      await _until(
        () =>
            (duration ?? observed.duration ?? Duration.zero) >
            const Duration(seconds: 4),
      );
      final total = duration ?? observed.duration!;
      _require(
        total < const Duration(seconds: 8),
        'Generated six-second fixture has unexpected duration.',
      );
      await observed.backend.play().timeout(_eventTimeout);
      await _until(
        () => observed.playing && observed.position.inMilliseconds >= 250,
      );
      final playingPosition = observed.position.inMilliseconds;
      final paused = await _verifyPause(observed);
      await observed.backend
          .seek(const Duration(milliseconds: 1200))
          .timeout(_eventTimeout);
      await _until(
        () => (observed.position.inMilliseconds - 1200).abs() <= 180,
      );
      final seekPosition = observed.position.inMilliseconds;
      final completionBaseline = observed.completionCount;
      await observed.backend
          .seek(total - const Duration(milliseconds: 550))
          .timeout(_eventTimeout);
      await observed.backend.play().timeout(_eventTimeout);
      await _until(() => observed.completionCount > completionBaseline);
      _require(
        observed.errorTypes.isEmpty,
        'Unexpected native error for $extension.',
      );
      return {
        'format': extension,
        'unicodeAndSpacesPath': true,
        'durationMs': total.inMilliseconds,
        'playingPositionMs': playingPosition,
        'pause': paused,
        'seekTargetMs': 1200,
        'seekObservedMs': seekPosition,
        'completionEventCount': observed.completionCount,
        'positionEventCount': observed.positionEvents,
        'nativeStates': observed.stateTrace,
        'backendVolumeRequested': _volume,
      };
    } finally {
      await release(observed);
    }
  }

  Future<Map<String, Object?>> recovery() async {
    final invalid = File('${output.path}/generated-corrupt.wav');
    await invalid.writeAsString('HanMusic generated invalid audio fixture.');
    final observed = createBackend();
    try {
      await observed.backend.setVolume(_volume).timeout(_eventTimeout);
      final failureWatch = Stopwatch()..start();
      Object? failure;
      try {
        await observed.backend.load(invalid.uri).timeout(_operationTimeout);
      } catch (error) {
        failure = error;
      }
      _require(failure != null, 'Invalid audio unexpectedly loaded.');
      final failureMs = failureWatch.elapsedMilliseconds;
      final errorsBeforeRecovery = observed.errorTypes.length;
      await observed.backend
          .load(fixture('mp3').uri)
          .timeout(_operationTimeout);
      await observed.backend.play().timeout(_eventTimeout);
      await _until(
        () => observed.playing && observed.position.inMilliseconds >= 250,
      );
      _require(
        observed.errorTypes.length == errorsBeforeRecovery,
        'Recovery generated a new native error.',
      );
      final paused = await _verifyPause(observed);
      return {
        'controlledFailureType': '${failure.runtimeType}',
        'failureMs': failureMs,
        'nativeErrorTypes': observed.errorTypes,
        'recoveredPositionMs': observed.position.inMilliseconds,
        'pauseAfterRecovery': paused,
        'adapterTimeoutSeconds': 15,
      };
    } finally {
      await release(observed);
    }
  }

  Future<Map<String, Object?>> mixedQueue() async {
    final observed = createBackend();
    final player = PlayerService(
      observed.backend,
      resolver: online!.resolveForPlayback,
    );
    try {
      player.playMode.value = PlayMode.sequential;
      await player.setVolume(_volume).timeout(_eventTimeout);
      final first = local('mp3');
      final middle = network('tone-b');
      final last = local('m4a');
      await player.playQueue([first, middle, last]).timeout(_operationTimeout);
      await _until(
        () =>
            player.isPlaying.value &&
            player.position.value.inMilliseconds >= 200,
      );
      await player
          .seek(player.duration.value - const Duration(milliseconds: 500))
          .timeout(_eventTimeout);
      await _until(
        () =>
            player.currentSong.value?.id == middle.id &&
            player.isPlaying.value &&
            player.position.value.inMilliseconds >= 200,
      );
      await player
          .seek(player.duration.value - const Duration(milliseconds: 500))
          .timeout(_eventTimeout);
      await _until(
        () =>
            player.currentSong.value?.id == last.id &&
            player.isPlaying.value &&
            player.position.value.inMilliseconds >= 200,
      );
      await player.previous().timeout(_operationTimeout);
      await _until(
        () =>
            player.currentSong.value?.id == middle.id &&
            player.isPlaying.value &&
            player.position.value.inMilliseconds >= 200,
      );
      await player.next().timeout(_operationTimeout);
      await _until(
        () =>
            player.currentSong.value?.id == last.id &&
            player.isPlaying.value &&
            player.position.value.inMilliseconds >= 200,
      );
      await player.pause().timeout(_eventTimeout);
      final mixedIds = player.queue.map((song) => song.id).toList();
      _require(
        !jsonEncode(
          player.queue.map((song) => song.toJson()).toList(),
        ).contains('http://'),
        'Temporary network URL leaked into a queue entry.',
      );

      final refresh = network('refresh');
      await player
          .playQueue([refresh, local('wav')])
          .timeout(_operationTimeout);
      await _until(
        () =>
            player.currentSong.value?.id == refresh.id &&
            player.isPlaying.value &&
            player.position.value.inMilliseconds >= 200,
      );
      _require(
        server!.resolveCounts['refresh'] == 2,
        'Expired stream URL did not retry resolution exactly once.',
      );
      final refreshedPosition = player.position.value.inMilliseconds;
      await player
          .playQueue([network('broken'), local('wav')])
          .timeout(_operationTimeout);
      await _until(
        () =>
            player.currentSong.value?.id == local('wav').id &&
            player.isPlaying.value &&
            player.position.value.inMilliseconds >= 200,
      );
      _require(
        server!.resolveCounts['broken'] == 2,
        'Bad stream URL retry was not bounded.',
      );
      return {
        'naturalAdvance': ['local_mp3', 'network_tone-b', 'local_m4a'],
        'manualPreviousAndNext': true,
        'queueLogicalIds': mixedIds,
        'expiredUrlResolutions': server!.resolveCounts['refresh'],
        'refreshedPositionMs': refreshedPosition,
        'brokenUrlResolutions': server!.resolveCounts['broken'],
        'failedOnlineSkippedToLocal': true,
        'nativeExpectedErrorTypes': observed.errorTypes,
        'audioRequestCounts': server!.audioRequests,
      };
    } finally {
      try {
        await player.shutdown().timeout(_operationTimeout);
      } finally {
        await release(observed);
      }
    }
  }
}

class _ObservedBackend {
  _ObservedBackend(this.backend) {
    subscriptions.addAll([
      backend.states.listen((value) {
        playing = value.playing;
        loading = value.loading;
        if (value.completed && !completed) completionCount++;
        completed = value.completed;
        if (stateTrace.length < 80) {
          stateTrace.add({
            'playing': value.playing,
            'loading': value.loading,
            'completed': value.completed,
          });
        }
        final clock = armedClock;
        if (clock != null &&
            value.playing &&
            !value.loading &&
            !value.completed) {
          firstPlayingUs ??= clock.elapsedMicroseconds;
        }
      }),
      backend.positions.listen((value) {
        position = value;
        positionEvents++;
        final clock = armedClock;
        if (clock != null &&
            value > Duration.zero &&
            value < const Duration(seconds: 1) &&
            firstPositionUs == null) {
          firstPositionUs = clock.elapsedMicroseconds;
          firstPositionMs = value.inMilliseconds;
        }
      }),
      backend.durations.listen((value) {
        if (value != null) duration = value;
      }),
      backend.errors.listen((error) => errorTypes.add('${error.runtimeType}')),
    ]);
  }
  final AudioBackend backend;
  final subscriptions = <StreamSubscription<dynamic>>[];
  final errorTypes = <String>[];
  final stateTrace = <Map<String, bool>>[];
  Duration position = Duration.zero;
  Duration? duration;
  bool playing = false, loading = false, completed = false;
  int positionEvents = 0, completionCount = 0;
  Stopwatch? armedClock;
  int? firstPlayingUs, firstPositionUs, firstPositionMs;
  bool closed = false;
  void arm(Stopwatch watch) {
    armedClock = watch;
    firstPlayingUs = null;
    firstPositionUs = null;
    firstPositionMs = null;
  }

  void disarm() {
    armedClock = null;
    firstPlayingUs = null;
    firstPositionUs = null;
    firstPositionMs = null;
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    try {
      await backend.dispose().timeout(const Duration(seconds: 5));
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
  }
}

Future<Map<String, Object?>> _verifyPause(_ObservedBackend observed) async {
  await observed.backend.pause().timeout(_eventTimeout);
  await _until(() => !observed.playing);
  final settling = Stopwatch()..start();
  var unchangedSince = settling.elapsedMilliseconds;
  var last = observed.position.inMilliseconds;
  while (settling.elapsedMilliseconds - unchangedSince < 240) {
    if (settling.elapsed > const Duration(seconds: 3)) {
      throw TimeoutException('Native pause did not settle.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final next = observed.position.inMilliseconds;
    if (next != last) {
      last = next;
      unchangedSince = settling.elapsedMilliseconds;
    }
  }
  final baseline = observed.position.inMilliseconds;
  var minimum = baseline, maximum = baseline;
  final verification = Stopwatch()..start();
  while (verification.elapsedMilliseconds < 360) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    _require(
      !observed.playing,
      'Native state resumed during pause verification.',
    );
    minimum = math.min(minimum, observed.position.inMilliseconds);
    maximum = math.max(maximum, observed.position.inMilliseconds);
  }
  _require(
    maximum - minimum <= 20,
    'Clock advanced after native pause had settled.',
  );
  return {
    'settlingMs':
        settling.elapsedMilliseconds - verification.elapsedMilliseconds,
    'settledPositionMs': baseline,
    'verificationWindowMs': verification.elapsedMilliseconds,
    'observedDriftMs': maximum - minimum,
    'nativePlayingFalse': !observed.playing,
  };
}

Map<String, Object?> summarize(List<Map<String, Object?>> values, String key) {
  if (values.isEmpty) return {'count': 0};
  final ordered = values.map((value) => (value[key] as num).toDouble()).toList()
    ..sort();
  final middle = ordered.length ~/ 2;
  return {
    'count': ordered.length,
    'minimum': ordered.first,
    'maximum': ordered.last,
    'median': ordered.length.isEven
        ? (ordered[middle - 1] + ordered[middle]) / 2
        : ordered[middle],
    'p95NearestRank': ordered[(ordered.length * .95).ceil() - 1],
  };
}

Future<void> _until(bool Function() predicate, {String? stage}) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    if (watch.elapsed > _eventTimeout) {
      throw TimeoutException(
        'Required backend event did not arrive within five seconds${stage == null ? '' : ' ($stage)'}.',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String _safe(Object error) =>
    '$error'.replaceAll(RegExp(r'https?://[^\s]+'), '<stream-url>');
