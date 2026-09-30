// Pure validation and statistics shared by the standalone output diagnostic.
import 'dart:math' as math;

import 'package:path/path.dart' as path;

final _windows = path.Context(style: path.Style.windows);

class OutputProbePaths {
  OutputProbePaths._(this.root, this.dll, this.phase);

  factory OutputProbePaths.parse(String? root, String? dll, String? phase) {
    String absolute(String? value) {
      if (value == null ||
          !RegExp(r'^[dD]:[\\/]').hasMatch(value) ||
          value
              .split(RegExp(r'[\\/]'))
              .any(
                (part) =>
                    part == '..' || part.endsWith(' ') || part.endsWith('.'),
              ) ||
          value.substring(2).contains(':')) {
        throw const FormatException(
          'Explicit controlled absolute D: paths required.',
        );
      }
      return _windows.normalize(value);
    }

    final normalizedRoot = absolute(root);
    final normalizedDll = absolute(dll);
    if (!RegExp(
          r'^D:\\dev\\tmp\\hanmusic-m5-output-[a-z0-9][a-z0-9._-]*[a-z0-9]$',
          caseSensitive: false,
        ).hasMatch(normalizedRoot) ||
        !normalizedDll.toLowerCase().startsWith(
          '${normalizedRoot.toLowerCase()}\\',
        ) ||
        _windows.extension(normalizedDll).toLowerCase() != '.dll' ||
        !{'all', 'cold-network'}.contains(phase)) {
      throw const FormatException('Invalid output probe root, DLL or phase.');
    }
    return OutputProbePaths._(normalizedRoot, normalizedDll, phase!);
  }

  final String root;
  final String dll;
  final String phase;
  String get result => child('result-output-$phase.json');
  String get fixture => child('benchmark-local.wav');
  String get silentFixture => child('benchmark-silence.wav');
  String get onlineDirectory => child('online-$phase');
  String child(String name) => _windows.join(root, name);
}

class NativeOutputSnapshot {
  NativeOutputSnapshot._(this.json);

  factory NativeOutputSnapshot.fromJson(
    Object? value, {
    required int expectedPid,
    required int expectedArm,
  }) {
    Never invalid() =>
        throw const FormatException('Invalid native capture report.');
    if (value is! Map<String, dynamic>) invalid();
    final json = value;
    int integer(String key, {int minimum = 0}) {
      final raw = json[key];
      if (raw is! int || raw < minimum) invalid();
      return raw;
    }

    if (integer('schemaVersion') != 1 ||
        integer('targetProcessId', minimum: 1) != expectedPid ||
        json['mode'] != 'include-current-process-tree' ||
        json['running'] != true ||
        integer('armQpc100ns', minimum: 1) != expectedArm ||
        integer('observedQpc100ns', minimum: 1) < expectedArm ||
        json['errorHresult'] is! int ||
        json['errorHresult'] != 0) {
      invalid();
    }
    for (final key in [
      'packets',
      'frames',
      'nonzeroSamples',
      'discontinuities',
      'timestampErrors',
    ]) {
      integer(key);
    }
    final format = json['captureFormat'];
    if (format is! Map<String, dynamic> ||
        format['sampleRateHz'] is! int ||
        format['channels'] is! int ||
        format['bitsPerSample'] is! int ||
        format['sampleRateHz'] != 48000 ||
        format['channels'] != 2 ||
        format['bitsPerSample'] != 16) {
      invalid();
    }
    final peak = json['peakAbs'];
    final first = json['firstNonzeroQpc100ns'];
    final through = json['capturedThroughQpc100ns'];
    if (peak is! num ||
        !peak.isFinite ||
        peak < 0 ||
        peak > 1 ||
        (first != null &&
            (first is! int ||
                first < expectedArm ||
                first > integer('observedQpc100ns'))) ||
        (through != null &&
            (through is! int ||
                through < expectedArm ||
                through > integer('observedQpc100ns') + 10000)) ||
        json['detectionThresholdS16AbsExclusive'] is! int ||
        json['detectionThresholdS16AbsExclusive'] != 1) {
      invalid();
    }
    // Timestamp-error windows deliberately withhold firstNonzero even if
    // energy was observed. They are representable but can never pass a check.
    if (integer('timestampErrors') == 0 &&
        ((integer('nonzeroSamples') > 0) != (first != null))) {
      invalid();
    }
    if (integer('nonzeroSamples') > integer('frames') * 2 ||
        (integer('frames') > 0 && integer('packets') == 0) ||
        (integer('timestampErrors') == 0 &&
            ((integer('frames') > 0) != (through != null))) ||
        (first is int && (through is! int || first >= through)) ||
        (integer('nonzeroSamples') > 0 && peak <= 1 / 32768)) {
      invalid();
    }
    return NativeOutputSnapshot._(Map<String, dynamic>.unmodifiable(json));
  }

  final Map<String, dynamic> json;
  int get arm => json['armQpc100ns'] as int;
  int get observed => json['observedQpc100ns'] as int;
  int? get firstNonzero => json['firstNonzeroQpc100ns'] as int?;
  int get frames => json['frames'] as int;
  int get nonzeroSamples => json['nonzeroSamples'] as int;
  int get timestampErrors => json['timestampErrors'] as int;
  int? get capturedThrough => json['capturedThroughQpc100ns'] as int?;
  double get windowMs => (observed - arm) / 10000;

  double requireOutputLatencyMs() {
    if (firstNonzero == null ||
        frames == 0 ||
        nonzeroSamples == 0 ||
        timestampErrors != 0) {
      throw const FormatException('No valid nonzero PCM timing evidence.');
    }
    return (firstNonzero! - arm) / 10000;
  }

  void requireSilence({required double minimumMs, bool requirePcm = false}) {
    if (windowMs < minimumMs ||
        timestampErrors != 0 ||
        firstNonzero != null ||
        nonzeroSamples != 0 ||
        (requirePcm &&
            (frames / 48 < minimumMs ||
                capturedThrough == null ||
                (capturedThrough! - arm) / 10000 < minimumMs ||
                (observed - capturedThrough!) / 10000 > 150))) {
      throw const FormatException(
        'Insufficient or contaminated silence evidence.',
      );
    }
  }
}

/// Never silently discard failed/nonfinite samples from an aggregate.
Map<String, Object?> outputLatencySummary(
  List<double> values, {
  required int expectedCount,
  required double thresholdMs,
}) {
  if (expectedCount <= 0 ||
      values.length != expectedCount ||
      !thresholdMs.isFinite ||
      thresholdMs <= 0 ||
      values.any((value) => !value.isFinite || value < 0)) {
    throw const FormatException('Incomplete or invalid latency series.');
  }
  final sorted = List<double>.of(values)..sort();
  final middle = sorted.length ~/ 2;
  return {
    'count': sorted.length,
    'minimumMs': sorted.first,
    'maximumMs': sorted.last,
    'medianMs': sorted.length.isEven
        ? (sorted[middle - 1] + sorted[middle]) / 2
        : sorted[middle],
    'p95NearestRankMs': sorted[math.max(0, (sorted.length * .95).ceil() - 1)],
    'thresholdMs': thresholdMs,
    'allSamplesWithinThreshold': sorted.every((value) => value < thresholdMs),
  };
}
