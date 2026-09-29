// Build this diagnostic separately; restore lib/main.dart before packaging.
// Run in two NEW processes with HANMUSIC_RESTART_PHASE=write, then read.
// The fixture contract and measurement boundaries are recorded in each result.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:han_music/app/data/models/play_mode.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';
import 'package:han_music/app/data/repositories/online_source_store.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/online_music_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';
import 'package:han_music/main.dart' as app;
import 'package:path/path.dart' as path;

final _windows = path.Context(style: path.Style.windows);
const _operationTimeout = Duration(seconds: 40);

/// Pure lexical guard; physical directory and file checks run before app.main.
class RestartProbePaths {
  RestartProbePaths._(this.root, this.data, this.results);

  factory RestartProbePaths.parse(String? data, String? results) {
    String normalize(String? value) {
      if (value == null ||
          !RegExp(r'^[dD]:[\\/]').hasMatch(value) ||
          value.split(RegExp(r'[\\/]')).contains('..')) {
        throw const FormatException(
          'Explicit absolute controlled D: paths required.',
        );
      }
      return _windows.normalize(value);
    }

    final dataPath = normalize(data);
    final resultPath = normalize(results);
    final root = _windows.dirname(dataPath);
    if (!RegExp(
          r'^D:\\dev\\tmp\\hanmusic-m5-restart-[a-z0-9][a-z0-9._-]*[a-z0-9]$',
          caseSensitive: false,
        ).hasMatch(root) ||
        !_same(dataPath, _windows.join(root, 'data')) ||
        !_same(resultPath, _windows.join(root, 'results'))) {
      throw const FormatException(
        'Use one controlled restart root with data/results children.',
      );
    }
    return RestartProbePaths._(root, dataPath, resultPath);
  }

  final String root;
  final String data;
  final String results;
  final _validatedDirectories = <String>{};

  bool contains(String value) {
    if (!RegExp(r'^[dD]:[\\/]').hasMatch(value)) return false;
    final normalized = _windows.normalize(value).toLowerCase();
    return normalized.startsWith('${root.toLowerCase()}\\');
  }

  Future<void> validateDirectories() async {
    for (final value in [root, data, results]) {
      final directory = Directory(value);
      _require(
        await directory.exists(),
        'Controlled directories must already exist.',
      );
      _require(
        _same(await directory.resolveSymbolicLinks(), value),
        'Controlled directories must not redirect through a junction or symlink.',
      );
      _validatedDirectories.add(_windows.normalize(value).toLowerCase());
    }
  }

  /// Reject links before traversing them, including dangling links. Generated
  /// fixtures must not be changed externally while this process is running.
  Future<void> validateOwnedPath(String value) async {
    _require(contains(value), 'Fixture path escapes its controlled root.');
    var cursor = root;
    final segments = _windows.split(
      _windows.relative(_windows.normalize(value), from: root),
    );
    for (var index = 0; index < segments.length; index++) {
      cursor = _windows.join(cursor, segments[index]);
      if (_validatedDirectories.contains(cursor.toLowerCase())) continue;
      final type = await FileSystemEntity.type(cursor, followLinks: false);
      _require(
        type != FileSystemEntityType.link,
        'Fixture links/junctions are not allowed.',
      );
      if (type == FileSystemEntityType.notFound) return;
      if (index < segments.length - 1) {
        _require(
          type == FileSystemEntityType.directory,
          'Fixture parent is not a directory.',
        );
      }
      if (type == FileSystemEntityType.directory) {
        _validatedDirectories.add(cursor.toLowerCase());
      }
    }
  }

  static bool _same(String a, String b) =>
      _windows.normalize(a).toLowerCase() ==
      _windows.normalize(b).toLowerCase();
}

/// The manifest describes expected production state, not an alternate store.
class RestartProbeExpectation {
  RestartProbeExpectation._(this.value);

  factory RestartProbeExpectation.fromJson(Map<String, dynamic> value) {
    final count = value['libraryCount'];
    final position = value['positionMs'];
    final volume = value['volume'];
    final queue = _strings(value['queueIds']);
    final missing = _strings(value['missingIds']);
    if (count is! int ||
        count < 1 ||
        count > 20000 ||
        position is! int ||
        position < 0 ||
        volume is! num ||
        !volume.isFinite ||
        volume < 0 ||
        volume > 1 ||
        value['skipOnError'] is! bool ||
        !PlayMode.values.any((mode) => mode.name == value['mode']) ||
        queue.isEmpty ||
        queue.toSet().length != queue.length ||
        value['currentId'] is! String ||
        !queue.contains(value['currentId']) ||
        missing.toSet().length != missing.length ||
        missing.length > count) {
      throw const FormatException('Invalid restart expectation.');
    }
    return RestartProbeExpectation._(Map.unmodifiable(value));
  }

  final Map<String, dynamic> value;
  List<String> get queueIds => _strings(value['queueIds']);
  List<String> get missingIds => _strings(value['missingIds']);
  String get currentId => value['currentId'] as String;
  Duration get position => Duration(milliseconds: value['positionMs'] as int);
  PlayMode get mode => PlayMode.values.byName(value['mode'] as String);
  double get volume => (value['volume'] as num).toDouble();
  bool get skipOnError => value['skipOnError'] as bool;

  void verify(AppSnapshot snapshot) {
    _require(
      snapshot.songs.length == value['libraryCount'],
      'Library count differs.',
    );
    _require(
      listEquals(snapshot.queue.map((song) => song.id).toList(), queueIds),
      'Queue order/identity differs.',
    );
    _require(snapshot.currentId == currentId, 'Current song differs.');
    _require(snapshot.position == position, 'Restored position differs.');
    _require(snapshot.mode == mode, 'Play mode differs.');
    _require((snapshot.volume - volume).abs() < 0.000001, 'Volume differs.');
    _require(snapshot.skipOnError == skipOnError, 'Skip policy differs.');
    final actualMissing = snapshot.songs
        .where((song) => song.isMissing)
        .map((song) => song.id)
        .toSet();
    _require(
      setEquals(actualMissing, missingIds.toSet()),
      'Library missing flags differ.',
    );
  }
}

Future<void> main() async {
  final probeWatch = Stopwatch()..start();
  final startedAt = DateTime.now().toUtc();
  final phase = Platform.environment['HANMUSIC_RESTART_PHASE'];
  RestartProbePaths paths;
  late final File output;
  try {
    _require(Platform.isWindows, 'This probe requires Windows.');
    _require(
      phase == 'write' || phase == 'read',
      'Set HANMUSIC_RESTART_PHASE=write|read.',
    );
    paths = RestartProbePaths.parse(
      Platform.environment['HANMUSIC_DATA_DIR'],
      Platform.environment['HANMUSIC_PROBE_DIR'],
    );
    await paths.validateDirectories();
    output = File(_windows.join(paths.results, 'result-restart-$phase.json'));
    await paths.validateOwnedPath(output.path);
    _require(
      !await output.exists(),
      'Restart result already exists; use a fresh controlled root.',
    );
  } catch (error) {
    stderr.writeln('Restart probe refused unsafe configuration: $error');
    exit(2);
  }
  final frameworkErrors = <String>[];
  final checks = <Map<String, Object?>>[];
  final report = <String, Object?>{
    'schemaVersion': 1,
    'phase': phase,
    'pid': pid,
    'startedAt': startedAt.toIso8601String(),
    'passed': false,
    'productionEntryPoint': 'lib/main.dart',
    'dataDirectory': paths.data,
    'os': Platform.operatingSystemVersion,
    'buildMode': kReleaseMode
        ? 'release'
        : kProfileMode
        ? 'profile'
        : 'debug',
    'checks': checks,
    'frameworkErrors': frameworkErrors,
    'limitations': [
      'Production app.main and its actual services/page run in each new process.',
      'Startup timing starts immediately before app.main and ends at first rasterized frame.',
      'Process creation, probe preflight and OS cold-cache behavior are outside that timing.',
      'Safety preflight reads fixture/state files and warms file-system caches.',
      'Framework handleRequestAppExit followed by dart:io exit is not clicking the Windows close button.',
      'Native backend disposal completion/handle release is not separately observed; the production coordinator can time out a cleanup step.',
      'No audio playback, network requests, real file picker or clean-machine acceptance is performed.',
    ],
  };
  var finished = false;
  void finish(int code) {
    if (finished) return;
    finished = true;
    report['finishedAt'] = DateTime.now().toUtc().toIso8601String();
    report['probeElapsedMs'] = probeWatch.elapsedMicroseconds / 1000;
    try {
      output.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
      stdout.writeln(
        jsonEncode({
          'phase': phase,
          'passed': report['passed'],
          'result': output.path,
        }),
      );
    } catch (error) {
      stderr.writeln('Could not write controlled restart result: $error');
      code = 2;
    }
    exit(code);
  }

  final watchdog = Timer(const Duration(seconds: 150), () {
    report['fatal'] = 'Probe exceeded its 150-second watchdog.';
    finish(1);
  });
  void recordError(Object error) {
    if (frameworkErrors.length < 20) frameworkErrors.add('$error');
  }

  FlutterError.onError = (details) => recordError(details.exception);
  PlatformDispatcher.instance.onError = (error, stack) {
    recordError(error);
    return true;
  };
  Future<void> check(String name, FutureOr<void> Function() action) async {
    final watch = Stopwatch()..start();
    try {
      await Future<void>.sync(action).timeout(_operationTimeout);
      checks.add({
        'name': name,
        'passed': true,
        'elapsedMs': watch.elapsedMicroseconds / 1000,
      });
    } catch (error) {
      checks.add({'name': name, 'passed': false, 'error': '$error'});
      rethrow;
    }
  }

  try {
    final fixture = await _readJson(
      paths,
      _windows.join(paths.root, 'fixture.json'),
    );
    _require(fixture['schemaVersion'] == 1, 'Unsupported restart fixture.');
    final fixtureId = fixture['fixtureId'];
    _require(
      fixtureId is String &&
          RegExp(r'^[a-zA-Z0-9._-]{1,80}$').hasMatch(fixtureId),
      'Invalid fixture identity.',
    );
    report['fixtureId'] = fixtureId;
    final initial = RestartProbeExpectation.fromJson(
      _object(fixture['initial']),
    );
    final after = RestartProbeExpectation.fromJson(_object(fixture['after']));
    final rename = _object(fixture['rename']);
    _require(
      rename['songId'] is String &&
          rename['title'] is String &&
          (rename['title'] as String).trim().isNotEmpty &&
          (rename['title'] as String).length <= 512,
      'Invalid controlled rename.',
    );
    _require(
      initial.value['libraryCount'] == after.value['libraryCount'] &&
          setEquals(initial.queueIds.toSet(), after.queueIds.toSet()),
      'After state must retain the library and the same queue identities.',
    );

    await check('controlled_fixture_preflight', () async {
      for (final name in ['state.json', 'state.backup.json']) {
        final file = File(_windows.join(paths.data, name));
        await paths.validateOwnedPath(file.path);
        if (!await file.exists()) {
          _require(name != 'state.json', 'Seed state.json is required.');
          continue;
        }
        final state = AppSnapshot.fromJson(await _readJson(paths, file.path));
        final seen = <String>{};
        for (final song in [...state.songs, ...state.queue]) {
          if (!song.isOnline && seen.add(song.path)) {
            await paths.validateOwnedPath(song.path);
          }
          if (song.artworkPath case final artwork?) {
            await paths.validateOwnedPath(artwork);
          }
        }
      }
      for (final name in ['sources.json', 'sources.backup.json']) {
        final file = File(_windows.join(paths.data, 'online', name));
        await paths.validateOwnedPath(file.path);
        if (await file.exists()) {
          final sources = OnlineSourceSnapshot.fromJson(
            await _readJson(paths, file.path),
          );
          _require(
            sources.sources.isEmpty && sources.selectedSourceId == null,
            'The no-network restart fixture must have no online source configuration.',
          );
        }
      }
      // Check directories which production creates or writes during startup.
      for (final name in [
        'online',
        'artwork',
        '.hanmusic.lock',
        'state.next.json',
        _windows.join('online', 'sources.next.json'),
      ]) {
        await paths.validateOwnedPath(_windows.join(paths.data, name));
      }
      if (phase == 'read') {
        final previous = await _readJson(
          paths,
          _windows.join(paths.results, 'result-restart-write.json'),
        );
        _require(
          previous['passed'] == true &&
              previous['phase'] == 'write' &&
              previous['fixtureId'] == fixtureId &&
              previous['pid'] != pid,
          'Read phase requires a successful write result from a different process.',
        );
        final currentHash = sha256
            .convert(
              await File(_windows.join(paths.data, 'state.json')).readAsBytes(),
            )
            .toString();
        _require(
          previous['savedStateSha256'] == currentHash,
          'State changed between the two process runs.',
        );
        report['previousProcessId'] = previous['pid'];
      }
    });
    report['preflightElapsedMs'] = probeWatch.elapsedMicroseconds / 1000;

    final startupWatch = Stopwatch()..start();
    await app.main().timeout(const Duration(seconds: 60));
    report['productionMainReturnedMs'] =
        startupWatch.elapsedMicroseconds / 1000;
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized.timeout(
      _operationTimeout,
    );
    report['productionMainToFirstFrameMs'] =
        startupWatch.elapsedMicroseconds / 1000;
    report['probeEntryToFirstFrameMs'] = probeWatch.elapsedMicroseconds / 1000;
    _require(
      Get.isRegistered<LibraryService>() &&
          Get.isRegistered<PlayerService>() &&
          Get.isRegistered<OnlineMusicService>() &&
          Get.isRegistered<TimerService>(),
      'Production startup did not register all services.',
    );
    final library = Get.find<LibraryService>();
    final player = Get.find<PlayerService>();
    final timer = Get.find<TimerService>();
    final online = Get.find<OnlineMusicService>();

    AppSnapshot snapshot() => AppSnapshot(
      songs: library.songs.toList(),
      queue: player.queue.toList(),
      currentId: player.currentSong.value?.id,
      position: player.position.value,
      mode: player.playMode.value,
      volume: player.volume.value,
      skipOnError: player.skipOnError.value,
    );
    Future<void> verifyRuntime(RestartProbeExpectation expectation) async {
      expectation.verify(snapshot());
      _require(
        !player.isPlaying.value && !player.isLoading.value,
        'Restored player is not paused and idle.',
      );
      _require(
        player.errorMessage.value == null && online.errorMessage.value == null,
        'Production startup reported a state/backend error.',
      );
      _require(
        online.sources.isEmpty &&
            !online.isSearching.value &&
            !online.isLoadingMore.value &&
            !online.isTesting.value,
        'Online service unexpectedly started work.',
      );
      await _verifyQueueFlags(player.queue.toList());
    }

    await check('production_restored_state_after_first_frame', () async {
      await verifyRuntime(phase == 'write' ? initial : after);
      _require(!timer.isActive, 'Sleep timer must not be restored on startup.');
      if (phase == 'read') _verifyRename(snapshot(), rename);
      report['startupState'] = _summary(snapshot());
      report['sleepTimerActiveAtStartup'] = timer.isActive;
    });

    if (phase == 'write') {
      await check('controlled_paused_edits', () async {
        _require(
          library.songs.any((song) => song.id == rename['songId']),
          'Rename target is not in the library.',
        );
        library.replaceAll(
          library.songs
              .map(
                (song) => song.id == rename['songId']
                    ? song.copyWith(trackTitle: rename['title'] as String)
                    : song,
              )
              .toList(),
        );
        player.updateSongs(library.songs.toList());
        final byId = {for (final song in player.queue) song.id: song};
        await player.restoreQueue(
          after.queueIds.map((id) => byId[id]!).toList(),
          currentId: after.currentId,
          position: after.position,
          mode: after.mode,
          volume: after.volume,
          skipOnError: after.skipOnError,
        );
        await verifyRuntime(after);
        _verifyRename(snapshot(), rename);
        timer.start(const Duration(minutes: 30));
        _require(timer.isActive, 'Controlled sleep timer was not armed.');
        report['sleepTimerArmedBeforeExit'] = true;
        report['editedState'] = _summary(snapshot());
      });
    }
    await check('framework_exit_response_and_service_flags', () async {
      final watch = Stopwatch()..start();
      final response = await WidgetsBinding.instance
          .handleRequestAppExit()
          .timeout(_operationTimeout);
      report['frameworkExitResponse'] = response.name;
      report['frameworkExitMs'] = watch.elapsedMicroseconds / 1000;
      _require(
        response == AppExitResponse.exit,
        'Production exit was canceled.',
      );
      _require(
        !timer.isActive && !player.isPlaying.value && !player.canPlay,
        'Framework exit did not leave timer off and player unavailable.',
      );
      report['postExitServiceFlags'] = {
        'timerActive': timer.isActive,
        'playerIsPlaying': player.isPlaying.value,
        'playerCanPlay': player.canPlay,
        'nativeDisposeCompletionObserved': false,
      };
    });
    await check('saved_state_matches_controlled_edits', () async {
      final stateFile = File(_windows.join(paths.data, 'state.json'));
      final saved = AppSnapshot.fromJson(
        await _readJson(paths, stateFile.path),
      );
      after.verify(saved);
      _verifyRename(saved, rename);
      await _verifyQueueFlags(saved.queue);
      report['savedState'] = _summary(saved);
      report['savedStateBytes'] = await stateFile.length();
      report['savedStateSha256'] = sha256
          .convert(await stateFile.readAsBytes())
          .toString();
    });
    _require(
      frameworkErrors.isEmpty,
      'Framework or unhandled errors were observed.',
    );
    report['passed'] = true;
  } catch (error) {
    report['fatal'] = '$error';
  } finally {
    watchdog.cancel();
    finish(report['passed'] == true ? 0 : 1);
  }
}

Future<Map<String, dynamic>> _readJson(
  RestartProbePaths paths,
  String value,
) async {
  await paths.validateOwnedPath(value);
  final file = File(value);
  _require(
    await file.length() <= 16 * 1024 * 1024,
    'Fixture JSON exceeds 16 MiB.',
  );
  return _object(jsonDecode(await file.readAsString()));
}

Future<void> _verifyQueueFlags(List<Song> queue) async {
  for (final song in queue) {
    if (song.isOnline) {
      _require(
        !song.isMissing,
        'Online identity was marked as a missing local file.',
      );
    } else {
      _require(
        song.isMissing == !await File(song.path).exists(),
        'Queue missing flag does not match the fixture file.',
      );
    }
  }
}

void _verifyRename(AppSnapshot state, Map<String, dynamic> rename) {
  final song = state.songs.singleWhere((song) => song.id == rename['songId']);
  _require(
    song.title == rename['title'],
    'Library metadata edit was not retained.',
  );
  for (final item in state.queue.where((song) => song.id == rename['songId'])) {
    _require(
      item.title == rename['title'],
      'Queue metadata edit was not retained.',
    );
  }
}

Map<String, Object?> _summary(AppSnapshot state) => {
  'libraryCount': state.songs.length,
  'libraryMissingIds': state.songs
      .where((song) => song.isMissing)
      .map((song) => song.id)
      .toList(),
  'queue': state.queue
      .map(
        (song) => {
          'id': song.id,
          'title': song.title,
          'isOnline': song.isOnline,
          'isMissing': song.isMissing,
        },
      )
      .toList(),
  'currentId': state.currentId,
  'positionMs': state.position.inMilliseconds,
  'mode': state.mode.name,
  'volume': state.volume,
  'skipOnError': state.skipOnError,
};

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected JSON object.');
  }
  return value;
}

List<String> _strings(Object? value) {
  if (value is! List || value.any((item) => item is! String || item.isEmpty)) {
    throw const FormatException('Expected a list of nonempty IDs.');
  }
  return value.cast<String>();
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}
