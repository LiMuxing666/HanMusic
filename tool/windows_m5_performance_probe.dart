// Profile-only diagnostic of the actual library UI. Restore the normal entry
// point before distributing the app. No media files or user storage are read.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

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
      _previousOffset = offset;
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
      unawaited(_finish());
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

  Future<void> _finish() async {
    if (_finished) return;
    _finished = true;
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
    final completed =
        _endUs != null &&
        _timings.isNotEmpty &&
        widget.errors.isEmpty &&
        _metricsChanges == 0;
    final result = <String, Object?>{
      'schemaVersion': 1,
      'completed': completed,
      'startedAtUtc': _startedAt.toIso8601String(),
      'buildMode': 'profile',
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
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _ticker.dispose();
    _scroll.dispose();
    _memoryTimer?.cancel();
    _watchdog?.cancel();
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
