import 'package:flutter_test/flutter_test.dart';

import '../../tool/windows_m5_output_evidence.dart';
import '../../tool/windows_m5_output_probe.dart';
import '../support/fake_audio_backend.dart';

const _arm = 10000000000;

Map<String, dynamic> _snapshot({bool signal = true}) => {
  'schemaVersion': 1,
  'targetProcessId': 42,
  'mode': 'include-current-process-tree',
  'running': true,
  'armQpc100ns': _arm,
  'firstNonzeroQpc100ns': signal ? _arm + 1234567 : null,
  'observedQpc100ns': _arm + 7000000,
  'capturedThroughQpc100ns': _arm + 6800000,
  'packets': 65,
  'frames': 31200,
  'nonzeroSamples': signal ? 120 : 0,
  'peakAbs': signal ? .01 : 1 / 32768,
  'discontinuities': 1,
  'timestampErrors': 0,
  'errorHresult': 0,
  'detectionThresholdS16AbsExclusive': 1,
  'captureFormat': {'sampleRateHz': 48000, 'channels': 2, 'bitsPerSample': 16},
};

NativeOutputSnapshot _parse(Map<String, dynamic> json) =>
    NativeOutputSnapshot.fromJson(json, expectedPid: 42, expectedArm: _arm);

void main() {
  test(
    'failure diagnostics distinguish missing PCM from successful playback events',
    () async {
      final backend = FakeAudioBackend();
      final observed = OutputProbeBackendObservation(backend, (_, _, _) {});
      observed.arm(Stopwatch()..start());
      backend.emitState(playing: false, loading: true);
      backend.emitDuration(const Duration(seconds: 6));
      backend.emitState(playing: false);
      observed.playRequested = true;
      await backend.play();
      backend.emitPosition(const Duration(milliseconds: 120));
      backend.emitPosition(const Duration(seconds: 5));
      final frozen = observed.diagnostics(hasNonzeroPcm: false);
      expect(frozen['missingEvidence'], [
        'nonzero_pcm_above_detection_threshold',
      ]);
      expect(frozen['playing'], true);
      expect(frozen['loading'], false);
      expect(frozen['firstPlayingUs'], isA<int>());
      expect(frozen['firstPositionUs'], isA<int>());
      expect(frozen['firstPositionValueMs'], 120);
      expect(frozen['lastPositionMs'], 5000);
      expect(frozen['lastDurationMs'], 6000);
      expect(frozen['positionEventCount'], 2);
      observed.disarm();
      observed.arm(Stopwatch()..start());
      backend.emitState(playing: false);
      expect(frozen['playing'], true);
      expect((frozen['stateTrace'] as List).length, 3);
      expect((frozen['positionTrace'] as List).length, 2);
      await observed.close();
    },
  );

  test(
    'late position evidence stays diagnostic without masquerading as an early position event',
    () async {
      final backend = FakeAudioBackend();
      final observed = OutputProbeBackendObservation(backend, (_, _, _) {});
      observed.arm(Stopwatch()..start());
      observed.playRequested = true;
      backend.emitPosition(const Duration(milliseconds: 1500));
      backend.emitState(playing: true, loading: true);
      final diagnostic = observed.diagnostics(hasNonzeroPcm: true);
      expect(diagnostic['missingEvidence'], [
        'playing_event',
        'positive_position_event_before_1000ms',
      ]);
      expect(diagnostic['lastPositionMs'], 1500);
      expect(diagnostic['positionEventCount'], 1);
      expect(diagnostic['firstPositionUs'], isNull);
      expect(diagnostic['playing'], true);
      expect(diagnostic['loading'], true);
      await observed.close();
    },
  );

  test(
    'event traces are bounded while final state and total counts remain available',
    () async {
      final backend = FakeAudioBackend();
      final observed = OutputProbeBackendObservation(backend, (_, _, _) {});
      observed.arm(Stopwatch()..start());
      for (var i = 0; i < 100; i++) {
        backend.emitState(playing: true);
        backend.emitPosition(Duration(milliseconds: i * 50));
      }
      final diagnostic = observed.diagnostics(hasNonzeroPcm: false);
      expect((diagnostic['stateTrace'] as List).length, 64);
      expect((diagnostic['positionTrace'] as List).length, 64);
      expect(diagnostic['stateEventCount'], 100);
      expect(diagnostic['positionEventCount'], 100);
      expect(diagnostic['lastPositionMs'], 4950);
      await observed.close();
    },
  );

  test('100 ns QPC subtraction happens before millisecond conversion', () {
    final snapshot = _parse(_snapshot());
    expect(snapshot.requireOutputLatencyMs(), closeTo(123.4567, .0000001));
    expect(snapshot.windowMs, 700);
    // A discontinuity is reported, not equated with a timestamp error.
    expect(snapshot.json['discontinuities'], 1);
  });

  test(
    'schema, identity, arm, format and impossible counters reject stale or malformed data',
    () {
      final invalid = <Map<String, dynamic>>[
        {'schemaVersion': 2},
        {'targetProcessId': 43},
        {'mode': 'system-mix'},
        {'running': false},
        {'armQpc100ns': _arm - 1},
        {'errorHresult': -1},
        {'observedQpc100ns': _arm - 1},
        {'firstNonzeroQpc100ns': _arm - 1},
        {'firstNonzeroQpc100ns': _arm + 8000000},
        {'capturedThroughQpc100ns': _arm + 8000000},
        {'capturedThroughQpc100ns': null},
        {'packets': 0},
        {'frames': -1},
        {'frames': 1.5},
        {'nonzeroSamples': 999999},
        {'firstNonzeroQpc100ns': null},
        {'peakAbs': double.nan},
        {'peakAbs': 1.1},
        {'peakAbs': 1 / 32768},
        {'detectionThresholdS16AbsExclusive': 0},
        {
          'captureFormat': {
            'sampleRateHz': 44100,
            'channels': 2,
            'bitsPerSample': 16,
          },
        },
      ];
      for (final replacement in invalid) {
        expect(
          () => _parse({..._snapshot(), ...replacement}),
          throwsFormatException,
          reason: '$replacement',
        );
      }
      expect(
        () => NativeOutputSnapshot.fromJson(
          'not JSON object',
          expectedPid: 42,
          expectedArm: _arm,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'only playing events or empty capture can never prove nonzero output',
    () {
      final silent = _parse(_snapshot(signal: false));
      expect(silent.requireOutputLatencyMs, throwsFormatException);
      final empty = _parse({
        ..._snapshot(signal: false),
        'frames': 0,
        'packets': 0,
        'capturedThroughQpc100ns': null,
      });
      expect(empty.requireOutputLatencyMs, throwsFormatException);
      expect(
        () => empty.requireSilence(minimumMs: 400, requirePcm: true),
        throwsFormatException,
      );
      // A no-packet paused window may be used only as a settling wait.
      expect(() => empty.requireSilence(minimumMs: 450), returnsNormally);
    },
  );

  test('timestamp errors invalidate positive and negative observations', () {
    final signal = _parse({
      ..._snapshot(),
      'timestampErrors': 1,
      'firstNonzeroQpc100ns': null,
    });
    expect(signal.requireOutputLatencyMs, throwsFormatException);
    final silence = _parse({..._snapshot(signal: false), 'timestampErrors': 1});
    expect(
      () => silence.requireSilence(minimumMs: 400, requirePcm: true),
      throwsFormatException,
    );
  });

  test(
    'active silence needs real frame duration, arm coverage and fresh capture progress',
    () {
      expect(
        () => _parse(
          _snapshot(signal: false),
        ).requireSilence(minimumMs: 400, requirePcm: true),
        returnsNormally,
      );
      for (final replacement in <Map<String, dynamic>>[
        {'frames': 1}, // One silent frame then a stalled worker must not pass.
        {'frames': 19199}, // Just short of 400 ms at 48 kHz.
        {'capturedThroughQpc100ns': _arm + 3999999},
        {'capturedThroughQpc100ns': _arm + 5000000}, // 200 ms stale.
        {
          'observedQpc100ns': _arm + 10000000,
        }, // Wall time alone is not evidence.
      ]) {
        final snapshot = _parse({..._snapshot(signal: false), ...replacement});
        expect(
          () => snapshot.requireSilence(minimumMs: 400, requirePcm: true),
          throwsFormatException,
          reason: '$replacement',
        );
      }
      expect(
        () => _parse(
          _snapshot(),
        ).requireSilence(minimumMs: 400, requirePcm: true),
        throwsFormatException,
      );
    },
  );

  test('nearest-rank p95 retains the slowest of ten warm trials', () {
    final values = <double>[60, 10, 100, 20, 50, 40, 90, 70, 30, 80];
    final result = outputLatencySummary(
      values,
      expectedCount: 10,
      thresholdMs: 1000,
    );
    expect(result['p95NearestRankMs'], 100);
    expect(result['medianMs'], 55);
    expect(result['minimumMs'], 10);
    expect(result['allSamplesWithinThreshold'], true);
    expect(values.first, 60); // Caller data remains in execution order.
  });

  test(
    'thresholds are strict and incomplete or invalid series cannot pass',
    () {
      for (final threshold in [1000.0, 3000.0]) {
        expect(
          outputLatencySummary(
            [threshold],
            expectedCount: 1,
            thresholdMs: threshold,
          )['allSamplesWithinThreshold'],
          false,
        );
        expect(
          outputLatencySummary(
            [threshold - .001],
            expectedCount: 1,
            thresholdMs: threshold,
          )['allSamplesWithinThreshold'],
          true,
        );
      }
      for (final invalid in <List<double>>[
        [],
        [1],
        [1, double.nan],
        [1, double.infinity],
        [1, -1],
      ]) {
        expect(
          () => outputLatencySummary(
            invalid,
            expectedCount: 2,
            thresholdMs: 1000,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'paths require a single controlled D root and both phases share immutable fixtures',
    () {
      final all = OutputProbePaths.parse(
        'D:/dev/tmp/hanmusic-m5-output-20260930-ab',
        'D:/dev/tmp/hanmusic-m5-output-20260930-ab/native/capture.dll',
        'all',
      );
      final cold = OutputProbePaths.parse(all.root, all.dll, 'cold-network');
      expect(all.fixture, cold.fixture);
      expect(all.result, isNot(cold.result));
      expect(all.onlineDirectory, isNot(cold.onlineDirectory));
      for (final root in [
        'C:/dev/tmp/hanmusic-m5-output-ab',
        'D:/dev/tmp/hanmusic-m5-output-ab/../other',
        'D:/dev/tmp/hanmusic-m5-output-ab/child',
        'D:dev/tmp/hanmusic-m5-output-ab',
        'D:/dev/tmp/hanmusic-m5-output-ab.',
      ]) {
        expect(
          () => OutputProbePaths.parse(root, all.dll, 'all'),
          throwsFormatException,
        );
      }
      expect(
        () => OutputProbePaths.parse(
          all.root,
          'D:/dev/tmp/hanmusic-m5-output-other/capture.dll',
          'all',
        ),
        throwsFormatException,
      );
      expect(
        () => OutputProbePaths.parse(all.root, '${all.dll}:alternate', 'all'),
        throwsFormatException,
      );
      expect(
        () => OutputProbePaths.parse(all.root, all.dll, 'other'),
        throwsFormatException,
      );
    },
  );
}
