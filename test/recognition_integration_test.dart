import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:han_music/app/data/models/music_recognition.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/music_recognition_repository.dart';
import 'package:han_music/app/data/sources/music_capture.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/services/app_persistence_service.dart';
import 'package:han_music/app/services/app_settings_service.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/music_recognition_service.dart';
import 'package:han_music/app/services/online_music_service.dart';
import 'package:han_music/app/services/play_history_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/playlist_service.dart';
import 'package:han_music/app/services/sleep_timer_coordinator.dart';
import 'package:han_music/app/services/timer_service.dart';
import 'package:han_music/main.dart' show HanMusicApp;

import 'support/fake_audio_backend.dart';
import 'support/fake_online_music.dart';

void main() {
  testWidgets(
    'production recognition navigation searches the library and online without playing',
    (tester) async {
      await _withApp(tester, (fixture) async {
        await _tap(tester, const Key('nav-7'));
        expect(find.byKey(const Key('recognition-start')), findsOneWidget);
        await _tap(tester, const Key('recognition-start'));
        await _finishCapture(tester, fixture);
        fixture.repository.pending.single.complete(_match);
        await _frames(tester);
        await _tap(tester, const Key('recognition-search-library'));
        expect(find.byKey(const Key('library-search')), findsOneWidget);
        expect(fixture.controller.searchQuery.value, '夜航');
        expect(fixture.controller.visibleSongs.map((song) => song.title), [
          '夜航',
        ]);
        expect(fixture.backend.playCalls, 0);
        expect(fixture.backend.loadedUris, isEmpty);

        await _tap(tester, const Key('nav-7'));
        expect(fixture.recognition.result.value?.title, '夜航');
        await _tap(tester, const Key('recognition-search-online'));
        expect(find.byKey(const Key('online-query')), findsOneWidget);
        expect(fixture.online.query.value, '夜航');
        expect(fixture.online.results, isNotEmpty);
        expect(fixture.backend.playCalls, 0);
        expect(fixture.player.queue.map((song) => song.id), [
          fixture.songs.first.id,
        ]);
        expect(fixture.capture.pending, hasLength(1));
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'normal application exit cancels capture or upload and rejects late results',
    (tester) async {
      for (final uploading in [false, true]) {
        await _withApp(tester, (fixture) async {
          await _tap(tester, const Key('nav-7'));
          await _tap(tester, const Key('recognition-start'));
          if (uploading) await _finishCapture(tester, fixture);
          expect(
            await _drain(tester, tester.binding.handleRequestAppExit()),
            AppExitResponse.exit,
          );
          expect(fixture.capture.cancelCalls, 1);
          expect(fixture.recognition.acceptsCommands, isFalse);
          expect(fixture.repository.closed, isTrue);
          expect(fixture.backend.disposed, isTrue);
          expect(fixture.store.saved, isNotEmpty);

          if (uploading) {
            expect(fixture.repository.cancellations.single.isCancelled, isTrue);
            // Deliberately ignore cancellation in the fake to exercise the
            // production generation guard against an already-in-flight response.
            fixture.repository.pending.single.complete(_match);
          } else {
            fixture.capture.pending.single.complete(Uint8List(44));
          }
          await _frames(tester);
          expect(fixture.repository.pending.length, uploading ? 1 : 0);
          expect(fixture.recognition.result.value, isNull);
          expect(
            fixture.recognition.phase.value,
            isNot(RecognitionPhase.success),
          );
          await fixture.recognition.start();
          expect(fixture.capture.pending, hasLength(1));
          expect(tester.takeException(), isNull);
        });
      }
    },
  );

  testWidgets(
    'canceling a failed-save exit permits a new attempt but rejects the old capture',
    (tester) async {
      await _withApp(tester, (fixture) async {
        await _tap(tester, const Key('nav-7'));
        await _tap(tester, const Key('recognition-start'));
        fixture.store.fail = true;
        final exiting = tester.binding.handleRequestAppExit();
        await _turns(tester);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('更改尚未保存'), findsOneWidget);
        expect(fixture.capture.cancelCalls, 1);
        expect(fixture.recognition.acceptsCommands, isFalse);
        await tester.tap(find.text('返回播放器'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(await _drain(tester, exiting), AppExitResponse.cancel);
        expect(fixture.recognition.acceptsCommands, isTrue);
        expect(fixture.repository.closed, isFalse);
        fixture.store.fail = false;

        // Canceling exit must invalidate the page's disabled button even when
        // the recognition phase is already idle and no new result arrives.
        await _frames(tester);
        expect(fixture.recognition.phase.value, RecognitionPhase.idle);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('recognition-start')))
              .onPressed,
          isNotNull,
        );
        await _tap(tester, const Key('recognition-start'));
        expect(fixture.capture.pending, hasLength(2));
        fixture.capture.pending.first.complete(Uint8List(44));
        await _frames(tester);
        expect(fixture.repository.pending, isEmpty);
        expect(fixture.recognition.phase.value, RecognitionPhase.listening);
        await _finishCapture(tester, fixture);
        fixture.repository.pending.single.complete(_match);
        await _frames(tester);
        expect(fixture.recognition.result.value?.title, '夜航');
        expect(fixture.recognition.phase.value, RecognitionPhase.success);
        expect(fixture.backend.playCalls, 0);
        expect(tester.takeException(), isNull);
      });
    },
  );
}

const _match = MusicRecognitionResult(title: '夜航', artist: '测试歌手');

Future<void> _tap(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> _finishCapture(WidgetTester tester, _Fixture fixture) async {
  fixture.capture.pending.last.complete(Uint8List(44));
  await _frames(tester);
  expect(fixture.recognition.phase.value, RecognitionPhase.recognizing);
}

Future<void> _withApp(
  WidgetTester tester,
  Future<void> Function(_Fixture) run,
) async {
  Get.reset();
  Get.testMode = true;
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  final fixture = _Fixture();
  try {
    await fixture.initialize();
    await tester.pumpWidget(const HanMusicApp());
    await tester.pumpAndSettle();
    fixture.controller = Get.find<PlayerController>();
    expect(Get.key.currentContext, isNotNull);
    await run(fixture);
  } finally {
    fixture.store.fail = false;
    final observer =
        tester.state(find.byType(HanMusicApp)) as WidgetsBindingObserver;
    await _drain(tester, observer.didRequestAppExit());
    // Release deliberately late fakes after shutdown so teardown does not own
    // unresolved captures or requests, including when an assertion failed.
    for (final gate in fixture.capture.pending) {
      if (!gate.isCompleted) gate.complete(Uint8List(44));
    }
    await _frames(tester);
    for (final gate in fixture.repository.pending) {
      if (!gate.isCompleted) gate.complete(null);
    }
    await _frames(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await _drain(tester, fixture.persistence.close(flush: false));
    Get.reset();
    Get.testMode = false;
    await tester.binding.setSurfaceSize(null);
  }
}

/// Native stream disposal needs real event-loop turns without advancing the
/// coordinator's deadline timers, matching the existing exit integration tests.
Future<T> _drain<T>(WidgetTester tester, Future<T> operation) async {
  var completed = false;
  T? result;
  Object? failure;
  StackTrace? trace;
  unawaited(
    operation.then(
      (value) {
        result = value;
        completed = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        trace = stack;
        completed = true;
      },
    ),
  );
  for (var turn = 0; turn < 200 && !completed; turn++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(Duration.zero);
  }
  expect(
    completed,
    isTrue,
    reason: 'Production exit must finish without advancing deadline timers.',
  );
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return result as T;
}

Future<void> _turns(WidgetTester tester) async {
  for (var turn = 0; turn < 15; turn++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(Duration.zero);
  }
}

class _Fixture {
  final backend = FakeAudioBackend();
  final store = _Store();
  final capture = _Capture();
  final repository = _Repository();
  final songs = [
    Song(
      uri: Uri.file('D:/recognition-test/night.mp3', windows: true),
      fileName: 'night.mp3',
      trackTitle: '夜航',
    ),
    Song(
      uri: Uri.file('D:/recognition-test/morning.mp3', windows: true),
      fileName: 'morning.mp3',
      trackTitle: '清晨',
    ),
  ];
  late final MusicRecognitionService recognition;
  late final PlayerService player;
  late final OnlineMusicService online;
  late final AppPersistenceService persistence;
  late final PlayerController controller;

  Future<void> initialize() async {
    final settings = Get.put(AppSettingsService(), permanent: true);
    final library = Get.put(
      LibraryService(
        repository: LocalLibraryRepository(
          artworkDirectory: Directory('build/recognition-integration-artwork'),
        ),
      ),
      permanent: true,
    )..replaceAll(songs);
    online = Get.put(
      OnlineMusicService(
        repository: FakeOnlineMusicRepository(),
        store: MemoryOnlineSourceStore(
          sources: [onlineTestSource()],
          selected: 'demo',
        ),
      ),
      permanent: true,
    );
    await online.initialize();
    player = Get.put(PlayerService(backend), permanent: true);
    await player.restoreQueue([songs.first]);
    final playlists = Get.put(PlaylistService(), permanent: true);
    final history = Get.put(PlayHistoryService(player), permanent: true);
    recognition = Get.put(
      MusicRecognitionService(capture: capture, repository: repository),
      permanent: true,
    );
    persistence = Get.put(
      AppPersistenceService(
        store: store,
        library: library,
        player: player,
        playlists: playlists,
        history: history,
        settings: settings,
        onError: (message) => player.errorMessage.value = message,
      )..start(),
      permanent: true,
    );
    final timer = Get.put(
      TimerService(onExpired: player.pauseForSleepTimer),
      permanent: true,
    );
    Get.put(
      SleepTimerCoordinator(player: player, timer: timer),
      permanent: true,
    );
  }
}

class _Store implements AppStateStore {
  bool fail = false;
  final saved = <AppSnapshot>[];
  @override
  String? get warning => null;
  @override
  Future<AppSnapshot> load() async => const AppSnapshot();
  @override
  Future<void> save(AppSnapshot snapshot) async {
    if (fail) {
      throw const FileSystemException(
        'controlled recognition exit save failure',
      );
    }
    saved.add(snapshot);
  }
}

class _Capture implements MusicCapture {
  final pending = <Completer<Uint8List>>[];
  int cancelCalls = 0;
  @override
  Future<Uint8List> capture({
    required MusicCaptureSource source,
    required Duration duration,
  }) {
    final gate = Completer<Uint8List>();
    pending.add(gate);
    return gate.future;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }
}

class _Repository extends MusicRecognitionRepository {
  @override
  bool get isConfigured => true;
  final pending = <Completer<MusicRecognitionResult?>>[];
  final cancellations = <RecognitionCancellation>[];
  bool closed = false;
  @override
  Future<MusicRecognitionResult?> recognize({
    required Uint8List audio,
    required RecognitionCancellation cancellation,
  }) {
    cancellations.add(cancellation);
    final gate = Completer<MusicRecognitionResult?>();
    pending.add(gate);
    return gate.future;
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}
