import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/services/app_persistence_service.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/online_music_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/sleep_timer_coordinator.dart';
import 'package:han_music/app/services/timer_service.dart';
import 'package:han_music/main.dart' show HanMusicApp;

import 'support/fake_audio_backend.dart';
import 'support/fake_online_music.dart';

void main() {
  testWidgets('real app cancels a failed-save exit, then saves and exits', (
    tester,
  ) async {
    await _withApp(tester, (fixture) async {
      fixture.timer.start(const Duration(minutes: 30));
      fixture.store.fail = true;
      final firstExit = tester.binding.handleRequestAppExit();
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('更改尚未保存'), findsOneWidget);
      expect(fixture.backend.disposed, isFalse);
      expect(fixture.timer.isActive, isTrue);
      await tester.tap(find.text('返回播放器'));
      await tester.pumpAndSettle();
      expect(await _drain(tester, firstExit), AppExitResponse.cancel);
      expect(find.byType(AlertDialog), findsNothing);
      expect(fixture.backend.disposed, isFalse);

      // The actual UI remains editable, and persistence/source services were
      // not closed by the canceled request.
      fixture.store.fail = false;
      final savesBeforeEdit = fixture.store.saved.length;
      final volumeBefore = fixture.player.volume.value;
      await tester.tapAt(tester.getTopLeft(_volume) + const Offset(30, 24));
      await tester.pump(const Duration(milliseconds: 800));
      expect(fixture.player.volume.value, isNot(volumeBefore));
      expect(fixture.store.saved.length, greaterThan(savesBeforeEdit));
      expect(fixture.store.saved.last.volume, fixture.player.volume.value);
      await fixture.online.selectSource(null);
      expect(fixture.onlineStore.saves, 1);
      fixture.library.replaceAll([_song.copyWith(trackTitle: '取消后仍可编辑')]);
      expect(fixture.library.songs.single.title, '取消后仍可编辑');

      final secondExit = tester.binding.handleRequestAppExit();
      expect(await _drain(tester, secondExit), AppExitResponse.exit);
      expect(fixture.backend.disposed, isTrue);
      expect(
        fixture.backend.calls.where((call) => call == 'dispose'),
        hasLength(1),
      );
      expect(fixture.timer.isActive, isFalse);
      expect(fixture.store.saved.last.songs.single.title, '取消后仍可编辑');
      expect(fixture.store.saved.last.queue.single.title, '取消后仍可编辑');

      final finalSaves = fixture.store.saved.length;
      fixture.player.volume.value = .9;
      fixture.library.replaceAll([]);
      await fixture.online.selectSource(null);
      await tester.pump(const Duration(milliseconds: 800));
      expect(fixture.store.saved, hasLength(finalSaves));
      expect(fixture.library.songs, hasLength(1));
      expect(fixture.onlineStore.saves, 1);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('pending final save blocks pointer edits and keyboard focus', (
    tester,
  ) async {
    await _withApp(tester, (fixture) async {
      final search = find.byKey(const Key('library-search'));
      await tester.enterText(search, '测试');
      await tester.pump();
      final editable = tester.widget<EditableText>(
        find.descendant(of: search, matching: find.byType(EditableText)),
      );
      expect(editable.focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);

      final gate = Completer<void>();
      fixture.store.gate = gate;
      AppExitResponse? response;
      final exit = tester.binding.handleRequestAppExit().then((value) {
        response = value;
        return value;
      });
      await tester.pump();
      expect(response, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(fixture.store.attempts, greaterThan(0));
      expect(fixture.backend.disposed, isFalse);
      expect(editable.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);

      final volumeBefore = fixture.player.volume.value;
      final playCallsBefore = fixture.backend.playCalls;
      await tester.dragFrom(tester.getCenter(_volume), const Offset(-30, 0));
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('toggle-playback'))),
      );
      await tester.tapAt(tester.getCenter(search));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(fixture.player.volume.value, volumeBefore);
      expect(fixture.backend.playCalls, playCallsBefore);
      expect(editable.focusNode.hasFocus, isFalse);
      expect(editable.controller.text, '测试');
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(response, isNull);

      gate.complete();
      fixture.store.gate = null;
      await tester.pump();
      expect(await _drain(tester, exit), AppExitResponse.exit);
      expect(fixture.store.saved.last.volume, volumeBefore);
      expect(fixture.backend.disposed, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}

final _volume = find.byKey(const Key('volume-slider'));
final _song = Song(
  uri: Uri.file('D:/controlled-exit-test/test.wav', windows: true),
  fileName: '测试音频.wav',
);

Future<void> _withApp(
  WidgetTester tester,
  Future<void> Function(_Fixture fixture) run,
) async {
  Get.reset();
  Get.testMode = true;
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  final fixture = _Fixture();
  try {
    await fixture.initialize();
    await tester.pumpWidget(const HanMusicApp());
    await tester.pumpAndSettle();
    // This is populated by the real GetMaterialApp/Navigator, never assigned by
    // a test stub. It is the same context used by the production confirmation.
    expect(Get.key.currentContext, isNotNull);
    expect(_volume, findsOneWidget);
    await run(fixture);
  } finally {
    fixture.store.fail = false;
    final gate = fixture.store.gate;
    if (gate != null && !gate.isCompleted) gate.complete();
    fixture.store.gate = null;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await _drain(tester, fixture.dispose());
    Get.reset();
    Get.testMode = false;
    await tester.binding.setSurfaceSize(null);
  }
}

/// Native-style stream cancellation needs a real event-loop turn as well as
/// Flutter's fake microtasks. Advancing the fake clock instead could trigger a
/// shutdown timeout before those real Futures have had a chance to complete.
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
    await tester.pump();
  }
  expect(
    completed,
    isTrue,
    reason: 'Exit/cleanup must complete without advancing deadline timers.',
  );
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return result as T;
}

class _Fixture {
  final backend = FakeAudioBackend();
  final store = _MemoryStateStore();
  final onlineStore = MemoryOnlineSourceStore();
  late final PlayerService player;
  late final LibraryService library;
  late final OnlineMusicService online;
  late final AppPersistenceService persistence;
  late final TimerService timer;
  late final SleepTimerCoordinator sleep;

  Future<void> initialize() async {
    library = Get.put(
      LibraryService(
        repository: LocalLibraryRepository(
          artworkDirectory: Directory('D:/dev/tmp/unused-exit-test-artwork'),
        ),
      ),
      permanent: true,
    );
    library.replaceAll([_song]);
    online = Get.put(
      OnlineMusicService(
        repository: FakeOnlineMusicRepository(),
        store: onlineStore,
      ),
      permanent: true,
    );
    await online.initialize();
    player = Get.put(PlayerService(backend), permanent: true);
    await player.restoreQueue([_song]);
    persistence = Get.put(
      AppPersistenceService(
        store: store,
        library: library,
        player: player,
        onError: (message) => player.errorMessage.value = message,
      )..start(),
      permanent: true,
    );
    timer = Get.put(
      TimerService(onExpired: player.pauseForSleepTimer),
      permanent: true,
    );
    sleep = Get.put(
      SleepTimerCoordinator(player: player, timer: timer),
      permanent: true,
    );
  }

  Future<void> dispose() async {
    await persistence.close(flush: false);
    sleep.onClose();
    timer.onClose();
    await player.shutdown();
    await online.close();
    library.onClose();
  }
}

class _MemoryStateStore implements AppStateStore {
  bool fail = false;
  int attempts = 0;
  Completer<void>? gate;
  final saved = <AppSnapshot>[];

  @override
  String? get warning => null;

  @override
  Future<AppSnapshot> load() async => const AppSnapshot();

  @override
  Future<void> save(AppSnapshot snapshot) async {
    attempts++;
    if (fail) throw const FileSystemException('controlled final-save failure');
    if (gate case final pending?) await pending.future;
    saved.add(snapshot);
  }
}
