// Profile-only diagnostic of the actual library UI. Restore the normal entry
// point before distributing the app. No media files or user storage are read.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/data/sources/audio_backend.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/view.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

// Adds row Element lifecycle counters only to a separate diagnostic build.
// The wrapper changes the measured widget tree, so this run is not an FPS test.
const _rowLifecycleDiagnostic = bool.fromEnvironment(
  'HANMUSIC_M5_ROW_LIFECYCLE_DIAGNOSTIC',
);

final class _FileTime extends ffi.Struct {
  @ffi.Uint32()
  external int low;

  @ffi.Uint32()
  external int high;

  int get ticks => (high << 32) | low;
}

typedef _GetCurrentThreadIdNative = ffi.Uint32 Function();
typedef _GetCurrentThreadNative = ffi.Pointer<ffi.Void> Function();
typedef _GetThreadTimesNative =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<_FileTime>,
      ffi.Pointer<_FileTime>,
      ffi.Pointer<_FileTime>,
      ffi.Pointer<_FileTime>,
    );

final class _UiThreadCpuSnapshot {
  const _UiThreadCpuSnapshot({
    required this.processId,
    required this.threadId,
    required this.rawFrameTimestampUs,
    required this.scrollTick,
    required this.monotonicUs,
    required this.user100ns,
    required this.kernel100ns,
  });

  final int processId;
  final int threadId;
  final int rawFrameTimestampUs;
  final int scrollTick;
  final int monotonicUs;
  final int user100ns;
  final int kernel100ns;

  Map<String, int> toJson() => {
    'processId': processId,
    'threadId': threadId,
    'rawFrameTimestampUs': rawFrameTimestampUs,
    'scrollTick': scrollTick,
    'monotonicUs': monotonicUs,
    'user100ns': user100ns,
    'kernel100ns': kernel100ns,
  };
}

/// Two synchronous reads on the Dart UI isolate; no profiler or per-frame FFI.
final class _UiThreadCpuClock {
  _UiThreadCpuClock() {
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    _getCurrentThreadId = kernel32
        .lookupFunction<_GetCurrentThreadIdNative, int Function()>(
          'GetCurrentThreadId',
        );
    _getCurrentThread = kernel32
        .lookupFunction<
          _GetCurrentThreadNative,
          ffi.Pointer<ffi.Void> Function()
        >('GetCurrentThread');
    _getThreadTimes = kernel32
        .lookupFunction<
          _GetThreadTimesNative,
          int Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<_FileTime>,
            ffi.Pointer<_FileTime>,
            ffi.Pointer<_FileTime>,
            ffi.Pointer<_FileTime>,
          )
        >('GetThreadTimes');
    // All allocation and symbol lookup happen before the five-second warmup.
    _times = calloc<_FileTime>(4);
    _wall.start();
  }

  late final int Function() _getCurrentThreadId;
  late final ffi.Pointer<ffi.Void> Function() _getCurrentThread;
  late final int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<_FileTime>,
    ffi.Pointer<_FileTime>,
    ffi.Pointer<_FileTime>,
    ffi.Pointer<_FileTime>,
  )
  _getThreadTimes;
  late final ffi.Pointer<_FileTime> _times;
  final Stopwatch _wall = Stopwatch();
  bool _disposed = false;

  _UiThreadCpuSnapshot read(int rawFrameTimestampUs, int scrollTick) {
    if (_disposed) throw StateError('UI thread CPU clock has been disposed.');
    final threadId = _getCurrentThreadId();
    final creation = _times;
    final exit = _times + 1;
    final kernel = _times + 2;
    final user = _times + 3;
    final succeeded = _getThreadTimes(
      _getCurrentThread(),
      creation,
      exit,
      kernel,
      user,
    );
    if (succeeded == 0) {
      throw StateError('GetThreadTimes failed for the current UI thread.');
    }
    return _UiThreadCpuSnapshot(
      processId: pid,
      threadId: threadId,
      rawFrameTimestampUs: rawFrameTimestampUs,
      scrollTick: scrollTick,
      monotonicUs: _wall.elapsedMicroseconds,
      user100ns: user.ref.ticks,
      kernel100ns: kernel.ref.ticks,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _wall.stop();
    calloc.free(_times);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const outputPath = String.fromEnvironment('HANMUSIC_PROBE_DIR');
  if (outputPath.isEmpty) exit(2);
  final output = Directory(outputPath);
  await output.create(recursive: true);
  if (!kProfileMode) {
    await File('${output.path}/result-m5-performance.json').writeAsString(
      jsonEncode({
        'completed': false,
        'error': 'This probe requires --profile.',
      }),
      flush: true,
    );
    exit(2);
  }
  final errors = <String>[];
  FlutterError.onError = (details) => errors.add('${details.exception}');
  PlatformDispatcher.instance.onError = (error, stack) {
    errors.add('$error');
    return true;
  };
  final beforeIndexRss = ProcessInfo.currentRss;
  final library = LibraryService(
    repository: LocalLibraryRepository(
      artworkDirectory: Directory('${output.path}/unused-artwork'),
    ),
  );
  library.replaceAll(
    List.generate(10000, (index) {
      final suffix = index.toString().padLeft(5, '0');
      return Song(
        uri: Uri.file(
          'D:/HanMusicSyntheticIndex/track-$suffix.flac',
          windows: true,
        ),
        fileName: 'track-$suffix.flac',
        trackTitle: '性能测试曲目 $suffix',
        artist: '测试歌手 ${index % 100}',
        album: '确定性测试专辑 ${index % 250}',
        duration: Duration(seconds: 150 + index % 180),
      );
    }),
  );
  library.statusMessage.value = 'Profile 性能探针 · 10000 条测试索引 · 5 秒预热后连续滚动 30 秒';
  final player = PlayerService(_IdleBackend());
  final timer = TimerService(onExpired: player.pause);
  final controller = PlayerController(
    player: player,
    timer: timer,
    picker: _NoPicker(),
    library: library,
  )..onInit();
  runApp(
    _PerformanceProbe(
      output: output,
      library: library,
      player: player,
      timer: timer,
      controller: controller,
      errors: errors,
      beforeIndexRss: beforeIndexRss,
      afterIndexRss: ProcessInfo.currentRss,
    ),
  );
}

class _PerformanceProbe extends StatefulWidget {
  const _PerformanceProbe({
    required this.output,
    required this.library,
    required this.player,
    required this.timer,
    required this.controller,
    required this.errors,
    required this.beforeIndexRss,
    required this.afterIndexRss,
  });
  final Directory output;
  final LibraryService library;
  final PlayerService player;
  final TimerService timer;
  final PlayerController controller;
  final List<String> errors;
  final int beforeIndexRss;
  final int afterIndexRss;

  @override
  State<_PerformanceProbe> createState() => _PerformanceProbeState();
}

class _PerformanceProbeState extends State<_PerformanceProbe>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _warmup = Duration(seconds: 5);
  static const _measurement = Duration(seconds: 30);
  static const _oneWaySeconds = 10.0;
  final _scroll = ScrollController();
  final _timings = <FrameTiming>[];
  final _memory = <Map<String, Object?>>[];
  final _lifecycle = <String>[];
  final _accessibilityChanges = <Map<String, Object?>>[];
  final _uiThreadCpuClock = _UiThreadCpuClock();
  final LibraryRowLifecycleDiagnostics? _rowLifecycle = _rowLifecycleDiagnostic
      ? LibraryRowLifecycleDiagnostics()
      : null;
  _UiThreadCpuSnapshot? _uiCpuStart;
  _UiThreadCpuSnapshot? _uiCpuEnd;
  Map<String, int>? _rowStart;
  Map<String, int>? _rowEnd;
  late final Map<String, Object?> _initialAccessibility;
  Map<String, Object?>? _measurementStartAccessibility;
  Map<String, Object?>? _measurementEndAccessibility;
  late bool _lastSemanticsEnabled;
  late AccessibilityFeatures _lastAccessibilityFeatures;
  late final Ticker _ticker;
  Timer? _memoryTimer;
  Timer? _watchdog;
  int? _startUs;
  int? _endUs;
  int _warmupFrames = 0;
  int _scrollTicks = 0;
  int _directionChanges = 0;
  int _metricsChanges = 0;
  bool? _forward;
  bool _finished = false;
  double _minimumOffset = double.infinity;
  double _maximumOffset = 0;
  double _distance = 0;
  double _previousOffset = 0;
  double _maximumExtent = 0;
  Duration _lastElapsed = Duration.zero;
  Duration? _measurementStartedAt;
  Size _logicalSize = Size.zero;
  double _devicePixelRatio = 1;
  double _refreshRate = 60;
  DateTime _startedAt = DateTime.now().toUtc();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastSemanticsEnabled = WidgetsBinding.instance.semanticsEnabled;
    _lastAccessibilityFeatures = WidgetsBinding.instance.accessibilityFeatures;
    _initialAccessibility = _accessibilitySnapshot();
    WidgetsBinding.instance.addSemanticsEnabledListener(_onSemanticsChanged);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _ticker = createTicker(_onTick);
    _watchdog = Timer(const Duration(seconds: 90), () {
      widget.errors.add(
        'Probe timed out before completing the 30 second sample.',
      );
      unawaited(_finish());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final view = View.of(context);
      _logicalSize = view.physicalSize / view.devicePixelRatio;
      _devicePixelRatio = view.devicePixelRatio;
      _refreshRate = view.display.refreshRate;
      _startedAt = DateTime.now().toUtc();
      _sampleMemory();
      _memoryTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _sampleMemory(),
      );
      _ticker.start();
    });
  }

  void _onTick(Duration elapsed) {
    if (_finished || !_scroll.hasClients) return;
    _lastElapsed = elapsed;
    final position = _scroll.position;
    if (!position.hasContentDimensions || position.maxScrollExtent <= 0) return;
    _maximumExtent = position.maxScrollExtent;
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final phase = (seconds / _oneWaySeconds) % 2;
    final forward = phase < 1;
    final offset = (forward ? phase : 2 - phase) * _maximumExtent;
    if (elapsed >= _warmup && _startUs == null) {
      _startUs =
          SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
      _measurementStartedAt = elapsed;
      // One boundary snapshot, not a query on every measured frame.
      _measurementStartAccessibility = _accessibilitySnapshot();
      _previousOffset = offset;
      final startRawTimestampUs = _startUs!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_finished) return;
        _rowStart = _rowLifecycle?.snapshot();
        try {
          _uiCpuStart = _uiThreadCpuClock.read(
            startRawTimestampUs,
            _scrollTicks,
          );
        } catch (error) {
          widget.errors.add('UI thread CPU start: $error');
        }
      });
    }
    if (_startUs != null) {
      _scrollTicks++;
      _minimumOffset = math.min(_minimumOffset, offset);
      _maximumOffset = math.max(_maximumOffset, offset);
      _distance += (offset - _previousOffset).abs();
      _previousOffset = offset;
      if (_forward != null && _forward != forward) _directionChanges++;
      _forward = forward;
    }
    _scroll.jumpTo(offset);
    if (_measurementStartedAt != null &&
        elapsed - _measurementStartedAt! >= _measurement) {
      _endUs =
          SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
      final endRawTimestampUs = _endUs!;
      _ticker.stop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_finished) return;
        _rowEnd = _rowLifecycle?.snapshot();
        try {
          _uiCpuEnd = _uiThreadCpuClock.read(endRawTimestampUs, _scrollTicks);
        } catch (error) {
          widget.errors.add('UI thread CPU end: $error');
        }
        unawaited(_finish());
      });
    }
  }

  void _onTimings(List<FrameTiming> frames) {
    for (final frame in frames) {
      final timestamp = frame.timestampInMicroseconds(FramePhase.vsyncStart);
      if (_startUs == null || timestamp < _startUs!) {
        _warmupFrames++;
      } else if (_endUs == null || timestamp <= _endUs!) {
        _timings.add(frame);
      }
    }
  }

  void _sampleMemory() => _memory.add({
    'elapsedMs': _lastElapsed.inMilliseconds,
    'phase': _startUs == null ? 'warmup' : 'measurement',
    'currentRssBytes': ProcessInfo.currentRss,
    'processLifetimeMaxRssBytes': ProcessInfo.maxRss,
  });

  @override
  void didChangeMetrics() {
    if (_startUs != null && !_finished) _metricsChanges++;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle.add('${_lastElapsed.inMilliseconds}ms:${state.name}');
  }

  Map<String, Object?> _accessibilitySnapshot() {
    final binding = WidgetsBinding.instance;
    final features = binding.accessibilityFeatures;
    return {
      // Framework semantics can also be requested by a SemanticsHandle; this
      // value is not evidence that a particular OS screen reader is running.
      'semanticsEnabled': binding.semanticsEnabled,
      'features': {
        'accessibleNavigation': features.accessibleNavigation,
        'invertColors': features.invertColors,
        'disableAnimations': features.disableAnimations,
        'boldText': features.boldText,
        'reduceMotion': features.reduceMotion,
        'highContrast': features.highContrast,
        'onOffSwitchLabels': features.onOffSwitchLabels,
        'supportsAnnounce': features.supportsAnnounce,
      },
    };
  }

  void _onSemanticsChanged() => _recordAccessibilityChange('semanticsEnabled');

  @override
  void didChangeAccessibilityFeatures() =>
      _recordAccessibilityChange('accessibilityFeatures');

  void _recordAccessibilityChange(String source) {
    if (_finished) return;
    final binding = WidgetsBinding.instance;
    final semantics = binding.semanticsEnabled;
    final features = binding.accessibilityFeatures;
    final changed =
        semantics != _lastSemanticsEnabled ||
        features != _lastAccessibilityFeatures;
    _lastSemanticsEnabled = semantics;
    _lastAccessibilityFeatures = features;
    if (!changed || _startUs == null) return;
    _accessibilityChanges.add({
      // Like lifecycle events, this is the most recent probe tick timestamp.
      'elapsedMs': _lastElapsed.inMilliseconds,
      'source': source,
      'snapshot': _accessibilitySnapshot(),
    });
  }

  Map<String, Object?> _summarizeUiThreadCpu() {
    final start = _uiCpuStart;
    final end = _uiCpuEnd;
    if (start == null || end == null) {
      widget.errors.add(
        'UI thread CPU post-frame boundary snapshot is missing.',
      );
      return {'valid': false, 'start': start?.toJson(), 'end': end?.toJson()};
    }

    final user100ns = end.user100ns - start.user100ns;
    final kernel100ns = end.kernel100ns - start.kernel100ns;
    final wallUs = end.monotonicUs - start.monotonicUs;
    final firstVsyncUs = _timings.isEmpty
        ? null
        : _timings.first.timestampInMicroseconds(FramePhase.vsyncStart);
    final lastVsyncUs = _timings.isEmpty
        ? null
        : _timings.last.timestampInMicroseconds(FramePhase.vsyncStart);
    final firstOffsetUs = firstVsyncUs == null
        ? null
        : firstVsyncUs - start.rawFrameTimestampUs;
    final lastOffsetUs = lastVsyncUs == null
        ? null
        : lastVsyncUs - end.rawFrameTimestampUs;
    final displayPeriodUs = 1000000 / _refreshRate;
    // Pre-registered window guard: at least 25 ms or four display periods.
    // Proximity does not claim equal phases or an exact frame/CPU pairing.
    final maxBoundaryOffsetUs = math.max(25000, (4 * displayPeriodUs).ceil());
    final measuredUs = _measurementStartedAt == null
        ? 0
        : (_lastElapsed - _measurementStartedAt!).inMicroseconds;
    final rawTimestampSpanUs =
        end.rawFrameTimestampUs - start.rawFrameTimestampUs;
    final frameVsyncSpanUs = firstVsyncUs == null || lastVsyncUs == null
        ? 0
        : lastVsyncUs - firstVsyncUs;
    final nearbyBuildUs = _timings
        .map((frame) => frame.buildDuration.inMicroseconds)
        .toList();
    final valid =
        start.processId == pid &&
        end.processId == pid &&
        start.threadId != 0 &&
        start.threadId == end.threadId &&
        start.scrollTick == 1 &&
        end.scrollTick == _scrollTicks &&
        firstOffsetUs != null &&
        lastOffsetUs != null &&
        firstOffsetUs.abs() <= maxBoundaryOffsetUs &&
        lastOffsetUs.abs() <= maxBoundaryOffsetUs &&
        nearbyBuildUs.isNotEmpty &&
        wallUs >= 29500000 &&
        wallUs <= 32500000 &&
        rawTimestampSpanUs >= 29500000 &&
        rawTimestampSpanUs <= 32500000 &&
        (wallUs - measuredUs).abs() <= 1000000 &&
        (frameVsyncSpanUs - measuredUs).abs() <= 1000000 &&
        user100ns >= 0 &&
        kernel100ns >= 0 &&
        // Allow for timer resolution and native call boundary uncertainty.
        (user100ns + kernel100ns) / 10 <= wallUs + 100000;
    if (!valid && !_rowLifecycleDiagnostic) {
      widget.errors.add(
        'UI thread CPU identity, nearby window or counter validation failed.',
      );
    }
    return {
      'valid': valid,
      'method': 'GetThreadTimes(current Dart UI isolate thread)',
      'boundary':
          'Two post-frame CPU snapshots bracket an approximately 30-second scroll workload. Raw onBeginFrame timestamps and FrameTiming OS vsyncStart timestamps have different phases; nearby frame rows are not exactly paired to the CPU interval.',
      'scope':
          'Aggregate CPU execution on the Dart UI isolate thread, including frame and other same-thread work. This is not process or host CPU and cannot attribute CPU or waiting to individual frames; boundary-frame uncertainty is not quantified.',
      'start': start.toJson(),
      'end': end.toJson(),
      'userMs': user100ns / 10000,
      'kernelMs': kernel100ns / 10000,
      'totalMs': (user100ns + kernel100ns) / 10000,
      'monotonicWallMs': wallUs / 1000,
      'rawTimestampSpanMs': rawTimestampSpanUs / 1000,
      'reportedTickerMeasurementMs': measuredUs / 1000,
      'frameVsyncSpanMs': frameVsyncSpanUs / 1000,
      'boundaryOffsetsUs': {
        'firstCsvVsyncMinusStartRaw': firstOffsetUs,
        'lastCsvVsyncMinusEndRaw': lastOffsetUs,
        'maxAllowedAbs': maxBoundaryOffsetUs,
        'displayPeriod': displayPeriodUs,
      },
      'nearbyFrameCount': nearbyBuildUs.length,
      'nearbyFramesBuildWallSumMs':
          nearbyBuildUs.fold<int>(0, (a, b) => a + b) / 1000,
      'nearbyFramesBuildWallP95Ms': _distribution(nearbyBuildUs)['p95'],
    };
  }

  Map<String, Object?> _summarizeRowLifecycle() {
    if (!_rowLifecycleDiagnostic) return {'enabled': false};
    final start = _rowStart;
    final end = _rowEnd;
    if (start == null || end == null) {
      widget.errors.add('Row lifecycle boundary snapshot is missing.');
      return {'enabled': true, 'valid': false};
    }
    final difference = <String, int>{};
    for (final entry in end.entries) {
      final previous = start[entry.key];
      if (previous == null || entry.value < previous) {
        widget.errors.add('Row lifecycle counter regressed: ${entry.key}.');
        return {'enabled': true, 'valid': false};
      }
      difference[entry.key] = entry.value - previous;
    }
    final wide = difference['wideMounts'] ?? 0;
    final narrow = difference['narrowMounts'] ?? 0;
    final wideBuilds = difference['wideBuilds'] ?? 0;
    final narrowBuilds = difference['narrowBuilds'] ?? 0;
    return {
      'enabled': true,
      'valid': true,
      'performanceComparable': false,
      'method':
          'Transparent StatefulWidget wrapper around each library row in this diagnostic build; initState and dispose count row Element lifecycle.',
      'start': start,
      'end': end,
      'delta': difference,
      'expectedTextWidgetsOnMountedRows': wide * 5 + narrow * 3,
      'expectedTextWidgetConstructionsInRowBuilds':
          wideBuilds * 5 + narrowBuilds * 3,
      'limitations':
          'Five Text widgets per wide row and three per narrow row are static code counts, not measured RenderParagraph allocations. Row builds and lifecycle counts do not attribute frame CPU time.',
    };
  }

  Future<void> _finish() async {
    if (_finished) return;
    _finished = true;
    _measurementEndAccessibility = _accessibilitySnapshot();
    WidgetsBinding.instance.removeSemanticsEnabledListener(_onSemanticsChanged);
    _ticker.stop();
    _watchdog?.cancel();
    _memoryTimer?.cancel();
    _sampleMemory();
    // FrameTiming batches can arrive after the last measured frame rasterizes.
    await Future<void>.delayed(const Duration(seconds: 1));
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _timings.sort((a, b) => a.frameNumber.compareTo(b.frameNumber));
    final budgetUs = 1000000 / (_refreshRate > 0 ? _refreshRate : 60);
    final uiTimes = _timings
        .map((frame) => frame.buildDuration.inMicroseconds)
        .toList();
    final rasterTimes = _timings
        .map((frame) => frame.rasterDuration.inMicroseconds)
        .toList();
    final totalTimes = _timings
        .map((frame) => frame.totalSpan.inMicroseconds)
        .toList();
    final measuredSeconds = _measurementStartedAt == null
        ? 0.0
        : (_lastElapsed - _measurementStartedAt!).inMicroseconds / 1000000;
    final uiThreadCpu = _summarizeUiThreadCpu();
    final rowLifecycle = _summarizeRowLifecycle();
    _uiThreadCpuClock.dispose();
    final completed =
        _endUs != null &&
        _timings.isNotEmpty &&
        (_rowLifecycleDiagnostic || uiThreadCpu['valid'] == true) &&
        (!_rowLifecycleDiagnostic || rowLifecycle['valid'] == true) &&
        widget.errors.isEmpty &&
        _metricsChanges == 0 &&
        _accessibilityChanges.isEmpty;
    final result = <String, Object?>{
      'schemaVersion': 2,
      'completed': completed,
      'startedAtUtc': _startedAt.toIso8601String(),
      'buildMode': 'profile',
      'rowLifecycleDiagnostic': rowLifecycle,
      'scope':
          'Actual PlayerPage/_LibraryView with 10000 deterministic synthetic Song index entries. Programmatic ScrollController.jumpTo on every vsync; no OS wheel/input, directory import, metadata/artwork IO, audio playback or network load.',
      'dataset': {
        'songs': widget.library.songs.length,
        'synthetic': true,
        'artwork': false,
        'seed': 'index-0-through-9999-v1',
      },
      'environment': {
        'os': Platform.operatingSystemVersion,
        'processors': Platform.numberOfProcessors,
        'logicalWidth': _logicalSize.width,
        'logicalHeight': _logicalSize.height,
        'devicePixelRatio': _devicePixelRatio,
        'displayRefreshRateHz': _refreshRate,
        'textScale': 1.0,
        'metricsChangesDuringMeasurement': _metricsChanges,
        'lifecycleEvents': _lifecycle,
        'accessibility': {
          'initial': _initialAccessibility,
          'measurementStart': _measurementStartAccessibility,
          'measurementEnd': _measurementEndAccessibility,
          'changesDuringMeasurement': _accessibilityChanges,
        },
      },
      'sampling': {
        'requestedWarmupSeconds': 5,
        'warmupFramesIncludingInitialBuild': _warmupFrames,
        'requestedMeasurementSeconds': 30,
        'actualMeasurementSeconds': measuredSeconds,
        'frames': _timings.length,
        'scrollTicks': _scrollTicks,
        'sampledFramesPerSecond': measuredSeconds > 0
            ? _timings.length / measuredSeconds
            : 0,
        'frameTimingBatchDrainMs': 1000,
      },
      'scroll': {
        'oneWaySeconds': _oneWaySeconds,
        'maximumExtentLogicalPx': _maximumExtent,
        'speedLogicalPxPerSecond': _maximumExtent / _oneWaySeconds,
        'minSampledOffset': _minimumOffset.isFinite ? _minimumOffset : null,
        'maxSampledOffset': _maximumOffset,
        'distanceLogicalPx': _distance,
        'directionChanges': _directionChanges,
      },
      'timingsMs': {
        'ui': _distribution(uiTimes),
        'raster': _distribution(rasterTimes),
        'totalSpan': _distribution(totalTimes),
      },
      'uiThreadCpu': uiThreadCpu,
      'jank': {
        'definition':
            'A sampled frame is over budget when UI build OR raster duration exceeds one display interval. totalSpan is latency, reported separately.',
        'displayBudgetMs': budgetUs / 1000,
        'displayBudget': _jank(uiTimes, rasterTimes, budgetUs),
        'fixed60Hz': _jank(uiTimes, rasterTimes, 1000000 / 60),
      },
      'memory': {
        'metric':
            'OS process RSS; includes native engine. Max RSS covers process lifetime, not Dart heap.',
        'beforeIndexRssBytes': widget.beforeIndexRss,
        'afterIndexRssBytes': widget.afterIndexRss,
        'lastRssBytes': ProcessInfo.currentRss,
        'processLifetimeMaxRssBytes': ProcessInfo.maxRss,
        'peakSampledRssBytes': _memory.fold<int>(
          0,
          (max, sample) => math.max(max, sample['currentRssBytes']! as int),
        ),
        'samplingIntervalMs': 1000,
        'samples': _memory,
      },
      'frameworkErrors': widget.errors,
      'performanceThresholdVerdict':
          'Not assigned automatically. completed means valid capture, not a universal performance pass.',
    };
    final csv = StringBuffer('frame,vsync_us,ui_us,raster_us,total_us\n');
    for (final frame in _timings) {
      csv.writeln(
        '${frame.frameNumber},${frame.timestampInMicroseconds(FramePhase.vsyncStart)},${frame.buildDuration.inMicroseconds},${frame.rasterDuration.inMicroseconds},${frame.totalSpan.inMicroseconds}',
      );
    }
    await File(
      '${widget.output.path}/frames-m5-performance.csv',
    ).writeAsString(csv.toString(), flush: true);
    await File(
      '${widget.output.path}/result-m5-performance.json',
    ).writeAsString(
      const JsonEncoder.withIndent('  ').convert(result),
      flush: true,
    );
    widget.controller.onClose();
    widget.timer.onClose();
    widget.library.onClose();
    await widget.player.shutdown();
    exit(completed ? 0 : 1);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HanMusicTheme.light,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: child!,
    ),
    home: PlayerPage(
      controller: widget.controller,
      libraryScrollController: _scroll,
      libraryRowDiagnostics: _rowLifecycle,
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.removeSemanticsEnabledListener(_onSemanticsChanged);
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _ticker.dispose();
    _scroll.dispose();
    _memoryTimer?.cancel();
    _watchdog?.cancel();
    _uiThreadCpuClock.dispose();
    super.dispose();
  }
}

Map<String, Object?> _distribution(List<int> values) {
  final sorted = values.toList()..sort();
  double? percentile(double value) =>
      sorted.isEmpty ? null : sorted[(sorted.length * value).ceil() - 1] / 1000;
  return {
    'p50': percentile(.50),
    'p95': percentile(.95),
    'p99': percentile(.99),
    'max': sorted.isEmpty ? null : sorted.last / 1000,
    'mean': sorted.isEmpty
        ? null
        : sorted.fold<int>(0, (a, b) => a + b) / sorted.length / 1000,
  };
}

Map<String, Object?> _jank(List<int> ui, List<int> raster, double budgetUs) {
  var uiOver = 0;
  var rasterOver = 0;
  var eitherOver = 0;
  for (var index = 0; index < ui.length; index++) {
    final slowUi = ui[index] > budgetUs;
    final slowRaster = raster[index] > budgetUs;
    if (slowUi) uiOver++;
    if (slowRaster) rasterOver++;
    if (slowUi || slowRaster) eitherOver++;
  }
  return {
    'uiFrames': uiOver,
    'rasterFrames': rasterOver,
    'eitherFrames': eitherOver,
    'eitherPercent': ui.isEmpty ? null : 100 * eitherOver / ui.length,
  };
}

class _NoPicker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}

class _IdleBackend implements AudioBackend {
  @override
  Stream<BackendPlaybackState> get states => const Stream.empty();
  @override
  Stream<Duration> get positions => const Stream.empty();
  @override
  Stream<Duration?> get durations => const Stream.empty();
  @override
  Stream<Object> get errors => const Stream.empty();
  @override
  Future<Duration?> load(Uri uri) async => null;
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {}
}
