// Standalone Windows diagnostic. Build separately from lib/main.dart.
// Runtime env: HANMUSIC_PROBE_DIR, HANMUSIC_LOOPBACK_DLL,
// HANMUSIC_PROBE_PHASE=all|cold-network. The runner owns the new controlled root.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:han_music/app/data/models/online_source_config.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/online_music_repository.dart';
import 'package:han_music/app/data/repositories/online_source_store.dart';
import 'package:han_music/app/data/sources/audio_backend.dart';
import 'package:han_music/app/data/sources/just_audio_backend.dart';
import 'package:han_music/app/services/online_music_service.dart';
import 'package:path/path.dart' as path;

import 'online_fixture_server.dart';
import 'windows_m5_output_evidence.dart';

// The pinned mpv applies pow(volume / 100, 3). With this fixed 1000-LSB
// waveform, bridge volume .02 yields only .008 LSB; .2 yields about 8 LSB,
// above the unchanged >1-LSB detector. This is a diagnostic-only setting.
// https://github.com/mpv-player/mpv/blob/652a1dd90711839acdccc08004056d25514ef2d8/player/audio.c
const _volume = .2;
const _operationTimeout = Duration(seconds: 18);
const _shortTimeout = Duration(seconds: 5);
const _quietMs = 450;
final _windows = path.Context(style: path.Style.windows);

void main() {
  _OutputProbe? probe;
  final watchdog = Timer(const Duration(seconds: 175), () {
    stderr.writeln('Output diagnostic exceeded its 175-second watchdog.');
    probe?.watchdogFailure();
    exit(3);
  });
  runZonedGuarded(
    () async {
      try {
        if (!Platform.isWindows) throw StateError('Windows is required.');
        final paths = OutputProbePaths.parse(
          Platform.environment['HANMUSIC_PROBE_DIR'],
          Platform.environment['HANMUSIC_LOOPBACK_DLL'],
          Platform.environment['HANMUSIC_PROBE_PHASE'],
        );
        probe = _OutputProbe(paths);
        await probe!.preflight().timeout(const Duration(seconds: 15));
        WidgetsFlutterBinding.ensureInitialized();
        FlutterError.onError = (details) => probe!.backgroundError(
          'framework',
          details.exception,
          details.stack,
        );
        PlatformDispatcher.instance.onError = (error, stack) {
          probe!.backgroundError('platform', error, stack);
          return true;
        };
        initializeAudioBackend();
        runApp(
          const MaterialApp(
            home: Scaffold(
              body: Center(child: Text('HanMusic Windows 输出路径验证')),
            ),
          ),
        );
        await WidgetsBinding.instance.waitUntilFirstFrameRasterized.timeout(
          const Duration(seconds: 10),
        );
        await probe!.run();
      } catch (error, stack) {
        stderr.writeln(_safe(error));
        probe?.fatal = {'error': _safe(error), 'stack': _safe(stack)};
      } finally {
        await probe?.cleanup();
        var code = 2;
        try {
          final current = probe;
          if (current != null) {
            current.writeReport();
            code = current.passed ? 0 : 1;
          }
        } catch (error) {
          stderr.writeln('Unable to write diagnostic report: ${_safe(error)}');
        }
        watchdog.cancel();
        exit(code);
      }
    },
    (error, stack) {
      probe?.backgroundError('zone', error, stack);
      stderr.writeln('Background diagnostic error: ${_safe(error)}');
    },
  );
}

class _OutputProbe {
  _OutputProbe(this.paths);
  final OutputProbePaths paths;
  final startedUtc = DateTime.now().toUtc().toIso8601String();
  final elapsed = Stopwatch()..start();
  final samples = <Map<String, Object?>>[];
  final controls = <Map<String, Object?>>[];
  final backgroundErrors = <Map<String, Object?>>[];
  final cleanupErrors = <Map<String, Object?>>[];
  final summaries = <String, Map<String, Object?>>{};
  final fixtureEvidence = <String, Object?>{};
  final pathInspector = _WindowsPathInspector();
  Map<String, Object?>? fatal;
  _Capture? capture;
  OutputProbeBackendObservation? audio;
  OnlineFixtureServer? server;
  OnlineMusicService? online;
  RandomAccessFile? _reportHandle;
  bool _reportWritten = false;
  bool _cleaned = false;
  int _armSerial = 0;
  String? _currentStage;
  Map<String, Object?>? _activeSample;

  bool get passed =>
      fatal == null &&
      backgroundErrors.isEmpty &&
      cleanupErrors.isEmpty &&
      controls.any(
        (item) =>
            item['name'] == 'active_silent_pcm_negative_control' &&
            item['passed'] == true,
      ) &&
      samples.length == (paths.phase == 'all' ? 22 : 1) &&
      samples.every((sample) => sample['passed'] == true) &&
      summaries.isNotEmpty &&
      summaries.values.every(
        (value) =>
            value['thresholdApplies'] != true ||
            value['allSamplesWithinThreshold'] == true,
      );

  void backgroundError(String source, Object error, StackTrace? stack) {
    backgroundErrors.add({
      'source': source,
      'stage': _currentStage,
      'error': _safe(error),
      if (stack != null) 'stack': _safe(stack),
    });
  }

  Future<void> preflight() async {
    _currentStage = 'preflight';
    await _validatePath(paths.root, requireDirectory: true);
    await _validatePath(paths.dll, requireFile: true);
    await _validatePath(paths.result);
    _require(
      await FileSystemEntity.type(paths.result, followLinks: false) ==
          FileSystemEntityType.notFound,
      'Result already exists; refusing overwrite.',
    );
    // Exclusive creation reserves this phase's result. Keep the OS handle so
    // later writes cannot follow a substituted result path. A failed preflight
    // after reservation still produces its own failure report.
    await File(paths.result).create(exclusive: true);
    _reportHandle = await File(paths.result).open(mode: FileMode.writeOnly);
    final dll = File(paths.dll);
    fixtureEvidence['dll'] = {
      'path': paths.dll,
      'bytes': await dll.length(),
      'sha256': (await sha256.bind(dll.openRead()).first).toString(),
    };
    final wav = createFixtureWav();
    final silent = Uint8List.fromList(wav)..fillRange(44, wav.length, 0);
    fixtureEvidence['tone'] = await _ensureFixture(paths.fixture, wav);
    fixtureEvidence['silence'] = await _ensureFixture(
      paths.silentFixture,
      silent,
    );
    await _validatePath(paths.onlineDirectory);
    _require(
      await FileSystemEntity.type(paths.onlineDirectory, followLinks: false) ==
          FileSystemEntityType.notFound,
      'This phase online store already exists.',
    );
    await Directory(paths.onlineDirectory).create();
  }

  Future<Map<String, Object?>> _ensureFixture(
    String filePath,
    Uint8List bytes,
  ) async {
    await _validatePath(filePath);
    final file = File(filePath);
    final expectedHash = sha256.convert(bytes).toString();
    final type = await FileSystemEntity.type(filePath, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await file.create(exclusive: true);
      await file.writeAsBytes(bytes, flush: true);
    } else {
      _require(
        type == FileSystemEntityType.file,
        'Fixture must be a regular file.',
      );
    }
    _require(
      await file.length() == bytes.length &&
          (await sha256.bind(file.openRead()).first).toString() == expectedHash,
      'Existing fixture differs from the fixed generated WAV.',
    );
    return {
      'path': filePath,
      'sha256': expectedHash,
      'bytes': bytes.length,
      'durationMs': 6000,
      'sampleRateHz': 22050,
      'channels': 1,
      'bitsPerSample': 16,
      'existingFileReused': type == FileSystemEntityType.file,
    };
  }

  Future<void> _validatePath(
    String value, {
    bool requireFile = false,
    bool requireDirectory = false,
  }) async {
    final normalized = _windows.normalize(value);
    final lower = normalized.toLowerCase();
    _require(
      lower == paths.root.toLowerCase() ||
          lower.startsWith('${paths.root.toLowerCase()}\\'),
      'Path escapes controlled root.',
    );
    // Check every existing component from D:\, including a dangling reparse
    // point. No traversal is allowed through any reparse attribute, not just
    // links that Dart recognizes. Controlled fixtures must remain unchanged
    // by other processes throughout the run.
    var cursor = _windows.rootPrefix(normalized);
    for (final part in _windows.split(normalized).skip(1)) {
      cursor = _windows.join(cursor, part);
      final attributes = pathInspector.attributes(cursor);
      if (attributes == null) break;
      _require(
        attributes & 0x400 == 0,
        'Reparse points are forbidden: $cursor',
      );
      final type = await FileSystemEntity.type(cursor, followLinks: false);
      _require(
        type != FileSystemEntityType.link,
        'Links are forbidden: $cursor',
      );
      if (cursor.toLowerCase() != lower) {
        _require(
          type == FileSystemEntityType.directory,
          'Path parent is not a directory.',
        );
      }
    }
    if (requireDirectory) {
      _require(
        await Directory(value).exists(),
        'Controlled directory does not exist.',
      );
    }
    if (requireFile) {
      _require(await File(value).exists(), 'Controlled DLL does not exist.');
    }
  }

  Future<void> run() async {
    _currentStage = 'capture_start';
    capture = _Capture(paths.dll);
    capture!.start();
    audio = OutputProbeBackendObservation(JustAudioBackend(), backgroundError);
    await audio!.backend.setVolume(_volume).timeout(_shortTimeout);
    if (paths.phase == 'all') {
      await _sample('local-cold', network: false, sequence: 0);
      for (var i = 1; i <= 10; i++) {
        await _sample('local-warm', network: false, sequence: i);
      }
    }
    _currentStage = 'network_setup';
    server = await OnlineFixtureServer.start().timeout(_shortTimeout);
    _require(
      sha256.convert(server!.audio).toString() ==
          (fixtureEvidence['tone'] as Map)['sha256'],
      'Local/network WAV bytes differ.',
    );
    online = OnlineMusicService(
      repository: OnlineMusicRepository(),
      store: FileOnlineSourceStore(Directory(paths.onlineDirectory)),
    );
    await online!.initialize().timeout(_shortTimeout);
    _require(
      await online!
          .upsertSource(OnlineSourceConfig.fromJson(server!.configJson()))
          .timeout(_operationTimeout),
      'Controlled network source setup failed.',
    );
    if (paths.phase == 'cold-network') {
      await _sample('network-cold', network: true, sequence: 0);
    } else {
      await _sample('network-warmup', network: true, sequence: 0);
      for (var i = 1; i <= 10; i++) {
        await _sample('network-warm', network: true, sequence: i);
      }
    }
    await _activeSilenceControl();
    for (final group
        in samples.map((sample) => sample['group'] as String).toSet()) {
      final values = samples
          .where((sample) => sample['group'] == group)
          .map((sample) => sample['renderPathLatencyMs'] as double)
          .toList();
      summaries[group] = outputLatencySummary(
        values,
        expectedCount: group.endsWith('-warm') ? 10 : 1,
        thresholdMs: group.startsWith('local') ? 1000 : 3000,
      );
      summaries[group]!['thresholdApplies'] = group.endsWith('-warm');
    }
  }

  Future<void> _sample(
    String group, {
    required bool network,
    required int sequence,
  }) async {
    final sample = <String, Object?>{
      'group': group,
      'sequence': sequence,
      'passed': false,
      'volume': _volume,
      'source': network ? 'loopback-http' : 'local-file',
      'thresholdMs': network ? 3000 : 1000,
      'thresholdApplies': group.endsWith('-warm'),
      'stage': 'quiet_before',
      'hasNonzeroPcm': false,
    };
    samples.add(sample);
    _activeSample = sample;
    _currentStage = '$group-$sequence';
    Stopwatch? sampleClock;
    var sawValidPcm = false;
    try {
      sample['beforeQuiet'] = await _pauseAndQuiet();
      final watch = sampleClock = Stopwatch()..start();
      sample['stage'] = 'capture_arm';
      final arm = capture!.arm();
      sample['armSerial'] = ++_armSerial;
      sample['armQpc100ns'] = arm;
      sample['armCallCompletedUs'] = watch.elapsedMicroseconds;
      final observed = audio!;
      observed.arm(watch);
      sample['stage'] = 'resolve';
      sample['resolveStartedUs'] = watch.elapsedMicroseconds;
      final uri = network
          ? await online!
                .resolveForPlayback(
                  Song.online(
                    sourceId: 'local-demo',
                    trackId: 'tone-a',
                    title: '输出测量固定音',
                  ),
                )
                .timeout(_shortTimeout)
          : File(paths.fixture).uri;
      final resolvedUs = watch.elapsedMicroseconds;
      sample.addAll({
        'resolveCompletedUs': resolvedUs,
        'resolveMs': resolvedUs / 1000,
        'stage': 'load',
        'loadStartedUs': watch.elapsedMicroseconds,
      });
      final duration = await observed.backend
          .load(uri)
          .timeout(_operationTimeout);
      sample.addAll({
        'loadCompletedUs': watch.elapsedMicroseconds,
        'loadReturnedDurationMs': duration?.inMilliseconds,
        'stage': 'load_ready',
      });
      _require(
        duration != null &&
            duration.inMilliseconds >= 5900 &&
            duration.inMilliseconds <= 6100,
        'Unexpected fixed WAV duration.',
      );
      await _until(() => !observed.loading && !observed.playing);
      final loadedUs = watch.elapsedMicroseconds;
      sample.addAll({
        'loadReadyCompletedUs': loadedUs,
        'loadReadyMs': (loadedUs - resolvedUs) / 1000,
        'loadReadyTotalMs': loadedUs / 1000,
        'stage': 'play_request',
        'playRequestStartedUs': watch.elapsedMicroseconds,
      });
      // Playback events are armed only after load. The separate render clock
      // starts BEFORE resolve/load, so neither network work nor loading is hidden.
      observed.playRequested = true;
      await observed.backend.play().timeout(_shortTimeout);
      sample.addAll({
        'playRequestCompletedUs': watch.elapsedMicroseconds,
        'stage': 'await_evidence',
      });
      final eventWait = Stopwatch()..start();
      NativeOutputSnapshot? firstOutput;
      while (true) {
        final snapshot = capture!.snapshot(arm);
        _require(
          snapshot.timestampErrors == 0,
          'Native packet timestamp error.',
        );
        if (snapshot.firstNonzero != null) {
          snapshot.requireOutputLatencyMs();
          sawValidPcm = true;
          sample['hasNonzeroPcm'] = true;
          firstOutput ??= snapshot;
        }
        _require(
          backgroundErrors.isEmpty,
          'Backend or framework reported a background error.',
        );
        if (firstOutput != null &&
            observed.firstPlayingUs != null &&
            observed.firstPositionUs != null) {
          break;
        }
        if (eventWait.elapsed > _shortTimeout) {
          final missing =
              observed.diagnostics(
                    hasNonzeroPcm: sawValidPcm,
                  )['missingEvidence']
                  as List<String>;
          throw TimeoutException(
            'No complete evidence within five seconds; missing: ${missing.join(', ')}.',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final native = capture!.snapshot(arm);
      final latency = native.requireOutputLatencyMs();
      sample['eventDiagnostics'] = observed.diagnostics(
        hasNonzeroPcm: sawValidPcm,
      );
      sample.addAll({
        'renderPathLatencyMs': latency,
        'withinThreshold': latency < (network ? 3000 : 1000),
        'resolveMs': resolvedUs / 1000,
        'loadReadyMs': (loadedUs - resolvedUs) / 1000,
        'loadReadyTotalMs': loadedUs / 1000,
        'firstPlayingEventMs': observed.firstPlayingUs! / 1000,
        'firstPositionEventMs': observed.firstPositionUs! / 1000,
        'firstPositionValueMs': observed.firstPositionMs,
        'firstOutputSnapshot': firstOutput.json,
        'nativeSnapshot': native.json,
      });
      sample['stage'] = 'quiet_after';
      observed.disarm();
      sample['afterQuiet'] = await _pauseAndQuiet();
      sample['passed'] = true;
      sample['stage'] = 'complete';
    } catch (error, stack) {
      final events = audio?.diagnostics(hasNonzeroPcm: sawValidPcm);
      sample.putIfAbsent('eventDiagnostics', () => events);
      final retainedEvents =
          sample['eventDiagnostics'] as Map<String, Object?>?;
      sample.addAll({
        'error': _safe(error),
        'stack': _safe(stack),
        'failureElapsedUs': sampleClock?.elapsedMicroseconds,
        'failureEventDiagnostics': events,
        'missingEvidence': retainedEvents?['missingEvidence'],
        'lastNativeSnapshot': capture?.lastRaw,
      });
      rethrow;
    } finally {
      audio?.disarm();
      _activeSample = null;
    }
  }

  Future<Map<String, Object?>> _pauseAndQuiet() async {
    final observed = audio!;
    observed.disarm();
    await observed.backend.pause().timeout(_shortTimeout);
    await _until(() => !observed.playing);
    final watch = Stopwatch()..start();
    final windows = <Map<String, dynamic>>[];
    var arm = capture!.arm();
    _armSerial++;
    while (watch.elapsed < const Duration(seconds: 4)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final snapshot = capture!.snapshot(arm);
      _require(
        snapshot.timestampErrors == 0,
        'Timestamp error in quiet window.',
      );
      _require(!observed.playing, 'Playback resumed during quiet window.');
      if (snapshot.nonzeroSamples != 0) {
        windows.add(snapshot.json);
        arm = capture!.arm();
        _armSerial++;
      } else if (snapshot.windowMs >= _quietMs) {
        snapshot.requireSilence(minimumMs: _quietMs.toDouble());
        return {
          'passed': true,
          'minimumQuietMs': _quietMs,
          'settlingElapsedMs': watch.elapsedMicroseconds / 1000,
          'discardedContaminatedWindows': windows,
          'nativeSnapshot': snapshot.json,
          'requiresPackets': false,
        };
      }
    }
    throw TimeoutException('PCM did not settle into a 450 ms quiet window.');
  }

  Future<void> _activeSilenceControl() async {
    _currentStage = 'active_silent_pcm_negative_control';
    final control = <String, Object?>{
      'name': _currentStage,
      'passed': false,
      'placement':
          'after latency samples to preserve first-load cold semantics',
      'threshold':
          'no signed16 PCM sample with abs(sample) > 1; not bit-exact zero',
    };
    controls.add(control);
    try {
      control['beforeQuiet'] = await _pauseAndQuiet();
      await audio!.backend
          .load(File(paths.silentFixture).uri)
          .timeout(_operationTimeout);
      final arm = capture!.arm();
      control['armSerial'] = ++_armSerial;
      await audio!.backend.play().timeout(_shortTimeout);
      await _until(() => audio!.playing && !audio!.loading);
      final watch = Stopwatch()..start();
      NativeOutputSnapshot snapshot;
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        snapshot = capture!.snapshot(arm);
        _require(
          snapshot.nonzeroSamples == 0 && snapshot.timestampErrors == 0,
          'Silent PCM control reported energy or invalid timestamps.',
        );
        if (watch.elapsedMilliseconds >= 650 &&
            snapshot.frames / 48 >= 400 &&
            snapshot.capturedThrough != null &&
            (snapshot.capturedThrough! - arm) / 10000 >= 400 &&
            (snapshot.observed - snapshot.capturedThrough!) / 10000 <= 150) {
          break;
        }
        if (watch.elapsedMilliseconds > 3000) {
          throw TimeoutException(
            'No fresh 400 ms PCM coverage in active silent control.',
          );
        }
      }
      snapshot.requireSilence(minimumMs: 400, requirePcm: true);
      _require(
        audio!.playing && backgroundErrors.isEmpty,
        'Silent control was not actively playing cleanly.',
      );
      control.addAll({
        'nativeSnapshot': snapshot.json,
        'playing': true,
        'minimumValidPcmMs': 400,
        'minimumObservationMs': 650,
        'maximumCaptureStalenessMs': 150,
        'requiresPackets': true,
      });
      control['afterQuiet'] = await _pauseAndQuiet();
      control['passed'] = true;
    } catch (error) {
      control.addAll({
        'error': _safe(error),
        'lastNativeSnapshot': capture?.lastRaw,
      });
      rethrow;
    }
  }

  Future<void> cleanup() async {
    if (_cleaned) return;
    _cleaned = true;
    _currentStage = 'cleanup';
    Future<void> step(String name, Future<void> Function() callback) async {
      try {
        await callback().timeout(_shortTimeout);
      } catch (error, stack) {
        cleanupErrors.add({
          'step': name,
          'error': _safe(error),
          'stack': _safe(stack),
        });
      }
    }

    if (audio != null) {
      await step('pause', audio!.backend.pause);
      await step('backend_dispose', audio!.close);
    }
    if (capture != null) {
      try {
        capture!.stop();
      } catch (error) {
        cleanupErrors.add({'step': 'capture_stop', 'error': _safe(error)});
      }
    }
    if (online != null) await step('online_close', online!.close);
    if (server != null) await step('fixture_server_close', server!.close);
  }

  Map<String, Object?> report() => {
    'schemaVersion': 1,
    'phase': paths.phase,
    'passed': passed,
    'pid': pid,
    'startedUtc': startedUtc,
    'elapsedMs': elapsed.elapsedMicroseconds / 1000,
    'mode': 'include-current-process-tree',
    'volume': _volume,
    'measurement': 'OS render-path: arm to first qualifying nonzero PCM frame',
    'timestampUnit': 'QPC 100 ns',
    'millisecondsDivisor': 10000,
    'captureNonzeroThreshold': 'abs(signed16 sample) > 1',
    'fixtures': fixtureEvidence,
    'samples': samples,
    'expectedSampleCount': paths.phase == 'all' ? 22 : 1,
    'controls': controls,
    'summaries': summaries,
    'backgroundErrors': backgroundErrors,
    'cleanupErrors': cleanupErrors,
    'fatal': fatal,
    'lastNativeSnapshot': capture?.lastRaw,
    'resolveCounts': server?.resolveCounts,
    'audioRequestCounts': server?.audioRequests,
    'limitations': [
      'Captures this process tree at the Windows OS render path; not the physical sound card, DAC, speaker or audible sound.',
      'QPC interval starts before resolve/load and includes scheduling and playback-call overhead; event Stopwatches are separate observations.',
      'Cold means the first backend.load in this fresh probe process; OS/filesystem/network caches are not flushed.',
      'Strict <1000 ms local / <3000 ms loopback thresholds apply only to warm groups. Cold and network-warmup values are observations, not acceptance thresholds.',
      'Network means an anonymous loopback fixture, not an Internet service or remote network latency.',
      'Uses the production JustAudioBackend and OnlineMusicService; this diagnostic UI is not the normal product entrypoint.',
      'Generated six-second mono PCM WAV only. Captured stereo format is fixed 48000 Hz / 16 bit, not an all-format or all-device claim.',
      'No PCM recording, no endpoint change, no system or device volume change; only diagnostic player volume 0.2. Pinned mpv applies cubic gain: the fixed 1000-LSB waveform is about 8 LSB before further output processing; volume 0.02 was below the unchanged >1-LSB detector.',
      'Quiet settling may have no packets; the additional active zero-WAV control must contain PCM frames and cannot pass with no capture data.',
      'Silence means no sample above the abs(signed16)>1 detection threshold; it is not a claim of bit-exact zero PCM. The active control requires at least 400 ms valid captured PCM and at most 150 ms capture staleness.',
      'Directory and DLL are trusted controlled fixtures; external mutation of the controlled tree during the run is unsupported.',
      'The two phases require separate processes and distinct result files. Warm groups retain every planned sample or fail as incomplete.',
    ],
  };

  void writeReport() {
    final handle = _reportHandle;
    if (_reportWritten || handle == null) return;
    _reportWritten = true;
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(report()),
    );
    handle.writeFromSync(bytes);
    handle.flushSync();
    handle.closeSync();
  }

  void watchdogFailure() {
    fatal = {
      'error': 'Global 175-second watchdog exceeded.',
      'stage': _currentStage,
    };
    _activeSample?.addAll({
      'passed': false,
      'error': 'Global watchdog exceeded.',
    });
    final active = _activeSample;
    if (active != null) {
      active.putIfAbsent(
        'eventDiagnostics',
        () =>
            audio?.diagnostics(hasNonzeroPcm: active['hasNonzeroPcm'] == true),
      );
      final events = active['eventDiagnostics'] as Map<String, Object?>?;
      active['missingEvidence'] = events?['missingEvidence'];
      active['lastNativeSnapshot'] = capture?.lastRaw;
    }
    try {
      writeReport();
    } catch (error) {
      stderr.writeln('Watchdog report failed: ${_safe(error)}');
    }
  }
}

/// Observable event evidence for this diagnostic only. Exposed so tests can
/// reproduce failure reporting with a fake backend, without invoking Windows.
class OutputProbeBackendObservation {
  OutputProbeBackendObservation(
    this.backend,
    void Function(String, Object, StackTrace?) onError,
  ) {
    void failed(Object error, StackTrace stack) =>
        onError('backend_stream', error, stack);
    subscriptions.addAll([
      backend.states.listen((value) {
        playing = value.playing;
        loading = value.loading;
        completed = value.completed;
        if (clock != null) {
          stateEvents++;
          if (stateTrace.length < 64) {
            stateTrace.add({
              'elapsedUs': clock!.elapsedMicroseconds,
              'playing': value.playing,
              'loading': value.loading,
              'completed': value.completed,
              'playRequested': playRequested,
            });
          }
        }
        if (playRequested &&
            value.playing &&
            !value.loading &&
            !value.completed) {
          firstPlayingUs ??= clock?.elapsedMicroseconds;
        }
      }, onError: failed),
      backend.positions.listen((value) {
        lastPosition = value;
        lastPositionElapsedUs = clock?.elapsedMicroseconds;
        if (clock != null) {
          positionEvents++;
          if (positionTrace.length < 64) {
            positionTrace.add({
              'elapsedUs': clock!.elapsedMicroseconds,
              'positionMs': value.inMilliseconds,
              'playRequested': playRequested,
            });
          }
        }
        if (playRequested &&
            value > Duration.zero &&
            value < const Duration(seconds: 1)) {
          if (firstPositionUs == null) {
            firstPositionUs = clock?.elapsedMicroseconds;
            firstPositionMs = value.inMilliseconds;
          }
        }
      }, onError: failed),
      backend.durations.listen(
        (value) => lastDuration = value,
        onError: failed,
      ),
      backend.errors.listen(
        (error) => onError('backend', error, null),
        onError: failed,
      ),
    ]);
  }
  final AudioBackend backend;
  final subscriptions = <StreamSubscription<dynamic>>[];
  bool playing = false,
      loading = false,
      completed = false,
      playRequested = false;
  Stopwatch? clock;
  int? firstPlayingUs, firstPositionUs, firstPositionMs;
  Duration lastPosition = Duration.zero;
  Duration? lastDuration;
  int? lastPositionElapsedUs;
  int stateEvents = 0, positionEvents = 0;
  final stateTrace = <Map<String, Object?>>[];
  final positionTrace = <Map<String, Object?>>[];
  void arm(Stopwatch value) {
    disarm();
    stateEvents = 0;
    positionEvents = 0;
    stateTrace.clear();
    positionTrace.clear();
    lastPositionElapsedUs = null;
    clock = value;
  }

  Map<String, Object?> diagnostics({required bool hasNonzeroPcm}) => {
    'diagnosticsArmed': clock != null,
    'playing': playing,
    'loading': loading,
    'completed': completed,
    'playRequested': playRequested,
    'observedElapsedUs': clock?.elapsedMicroseconds,
    'firstPlayingUs': firstPlayingUs,
    'firstPositionUs': firstPositionUs,
    'firstPositionValueMs': firstPositionMs,
    'lastPositionMs': lastPosition.inMilliseconds,
    'lastPositionEventElapsedUs': lastPositionElapsedUs,
    'lastDurationMs': lastDuration?.inMilliseconds,
    'stateEventCount': stateEvents,
    'positionEventCount': positionEvents,
    'stateTrace': stateTrace.map(Map<String, Object?>.of).toList(),
    'positionTrace': positionTrace.map(Map<String, Object?>.of).toList(),
    'traceLimitPerStream': 64,
    'positionEvidenceCondition': 'post-play-request position > 0 and < 1000 ms',
    'missingEvidence': <String>[
      if (!hasNonzeroPcm) 'nonzero_pcm_above_detection_threshold',
      if (firstPlayingUs == null) 'playing_event',
      if (firstPositionUs == null) 'positive_position_event_before_1000ms',
    ],
  };

  void disarm() {
    clock = null;
    playRequested = false;
    firstPlayingUs = null;
    firstPositionUs = null;
    firstPositionMs = null;
  }

  Future<void> close() async {
    try {
      await backend.dispose().timeout(_shortTimeout);
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel().timeout(const Duration(seconds: 1));
      }
    }
  }
}

class _Capture {
  _Capture(String dllPath) {
    final dll = DynamicLibrary.open(dllPath);
    _start = dll.lookupFunction<Int32 Function(), int Function()>(
      'hm_capture_start',
    );
    _arm = dll.lookupFunction<Int64 Function(), int Function()>(
      'hm_capture_arm',
    );
    _snapshot = dll
        .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
          'hm_capture_snapshot',
        );
    _stop = dll.lookupFunction<Void Function(), void Function()>(
      'hm_capture_stop',
    );
  }
  late final int Function() _start, _arm;
  late final Pointer<Uint8> Function() _snapshot;
  late final void Function() _stop;
  Object? lastRaw;
  bool _started = false;
  void start() {
    _started = true; // Also stop/inspect a failed activation during cleanup.
    final result = _start();
    _readSnapshot();
    _require(result == 0, 'Native capture start HRESULT=$result.');
  }

  int arm() {
    final result = _arm();
    _require(result > 0, 'Native capture arm failed.');
    return result;
  }

  NativeOutputSnapshot snapshot(int expectedArm) {
    return NativeOutputSnapshot.fromJson(
      _readSnapshot(),
      expectedPid: pid,
      expectedArm: expectedArm,
    );
  }

  Object? _readSnapshot() {
    final pointer = _snapshot();
    _require(pointer.address != 0, 'Native snapshot returned a null pointer.');
    final bytes = <int>[];
    var terminated = false;
    for (var i = 0; i < 65536; i++) {
      final value = pointer[i];
      if (value == 0) {
        terminated = true;
        break;
      }
      bytes.add(value);
    }
    _require(terminated, 'Native snapshot exceeds 64 KiB.');
    final text = utf8.decode(bytes, allowMalformed: false);
    lastRaw = text;
    final json = jsonDecode(text);
    lastRaw = json;
    return json;
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _stop();
    final stopped = _readSnapshot();
    _require(
      stopped is Map<String, dynamic> &&
          stopped['schemaVersion'] == 1 &&
          stopped['targetProcessId'] == pid &&
          stopped['mode'] == 'include-current-process-tree' &&
          stopped['running'] == false &&
          stopped['errorHresult'] == 0,
      'Native capture stop failed or timed out.',
    );
  }
}

/// Read-only Win32 attributes are needed to reject every reparse kind, including
/// dangling links and junctions, before opening a DLL or creating any output.
class _WindowsPathInspector {
  _WindowsPathInspector() {
    final kernel = DynamicLibrary.open('kernel32.dll');
    _allocate = kernel
        .lookupFunction<
          Pointer<Void> Function(Uint32, IntPtr),
          Pointer<Void> Function(int, int)
        >('LocalAlloc');
    _free = kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    _attributes = kernel
        .lookupFunction<
          Uint32 Function(Pointer<Uint16>),
          int Function(Pointer<Uint16>)
        >('GetFileAttributesW');
    _error = kernel.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    );
  }
  late final Pointer<Void> Function(int, int) _allocate;
  late final Pointer<Void> Function(Pointer<Void>) _free;
  late final int Function(Pointer<Uint16>) _attributes;
  late final int Function() _error;
  int? attributes(String value) {
    final utf16 = value.codeUnits;
    final allocation = _allocate(0, (utf16.length + 1) * 2);
    _require(allocation.address != 0, 'Unable to allocate a path buffer.');
    try {
      final pointer = allocation.cast<Uint16>();
      pointer.asTypedList(utf16.length + 1)
        ..setRange(0, utf16.length, utf16)
        ..[utf16.length] = 0;
      final result = _attributes(pointer);
      if (result == 0xffffffff) {
        final error = _error();
        if (error == 2 || error == 3) return null;
        throw FileSystemException('GetFileAttributesW failed ($error).', value);
      }
      return result;
    } finally {
      _free(allocation);
    }
  }
}

Future<void> _until(bool Function() predicate) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    if (watch.elapsed > _shortTimeout) {
      throw TimeoutException('Backend state timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String _safe(Object error) =>
    '$error'.replaceAll(RegExp(r'https?://[^\s]+'), '<stream-url>');
