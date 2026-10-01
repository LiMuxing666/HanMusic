import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/data/repositories/online_source_store.dart';
import 'package:han_music/app/modules/player/controller.dart';
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
  for (final entry in ['files', 'directory', 'single']) {
    testWidgets('exit invalidates pending $entry picker before final save', (
      tester,
    ) async {
      final selected = await _copyPickerFixture(tester);
      final pickers = _ExitPickers();
      await _withApp(
        tester,
        (fixture) async {
          final controller = Get.find<PlayerController>();
          final importing = entry == 'directory'
              ? controller.importDirectory()
              : controller.importFile();
          final gate = fixture.store.gate = Completer<void>();
          final exiting = tester.binding.handleRequestAppExit();
          await _pumpTurns(tester);
          expect(fixture.store.attempts, greaterThan(0));
          expect(fixture.store.saved, isEmpty);

          pickers.complete(entry, selected);
          await _drain(tester, importing);
          final observedIds = fixture.library.songs
              .map((song) => song.id)
              .toList();
          final loadedUris = fixture.backend.loadedUris.toList();
          gate.complete();
          fixture.store.gate = null;
          expect(await _drain(tester, exiting), AppExitResponse.exit);

          // The store captured its snapshot before the native picker replied.
          // A late result must not start indexing or revive audio afterward.
          expect(fixture.store.saved.last.songs.map((song) => song.id), [
            _song.id,
          ]);
          expect(observedIds, [_song.id]);
          expect(loadedUris, isEmpty);
          expect(tester.takeException(), isNull);
        },
        pickers: pickers,
        controllerHasLibrary: entry != 'single',
      );
    });

    testWidgets('canceled exit waits for old $entry picker before retry', (
      tester,
    ) async {
      final selected = await _copyPickerFixture(tester);
      final pickers = _ExitPickers();
      await _withApp(
        tester,
        (fixture) async {
          final controller = Get.find<PlayerController>();
          Future<void> import() => entry == 'directory'
              ? controller.importDirectory()
              : controller.importFile();
          final original = import();
          fixture.store.fail = true;
          final exiting = tester.binding.handleRequestAppExit();
          await _pumpTurns(tester);
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('更改尚未保存'), findsOneWidget);
          await import();
          expect(pickers.calls, 1);

          await tester.tap(find.text('返回播放器'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(await _drain(tester, exiting), AppExitResponse.cancel);
          expect(controller.isImporting.value, isTrue);
          await import();
          expect(pickers.calls, 1);
          pickers.complete(entry, selected);
          await _drain(tester, original);
          expect(fixture.library.songs.map((song) => song.id), [_song.id]);
          expect(fixture.backend.loadedUris, isEmpty);
          expect(controller.isImporting.value, isFalse);

          fixture.store.fail = false;
          pickers.reset();
          final retry = import();
          expect(controller.isImporting.value, isTrue);
          expect(pickers.calls, 2);
          pickers.complete(entry, selected);
          await _drain(tester, retry);
          expect(controller.isImporting.value, isFalse);
          if (entry == 'single') {
            expect(fixture.backend.loadedUris, [selected.uri]);
          } else {
            expect(fixture.library.songs, hasLength(2));
          }
          expect(
            await _drain(tester, tester.binding.handleRequestAppExit()),
            AppExitResponse.exit,
          );
          expect(
            fixture.store.saved.last.songs,
            hasLength(entry == 'single' ? 1 : 2),
          );
          expect(tester.takeException(), isNull);
        },
        pickers: pickers,
        controllerHasLibrary: entry != 'single',
      );
    });
  }

  testWidgets(
    'pending online disk failure requires cancelable exit confirmation',
    (tester) async {
      await _withApp(tester, (fixture) async {
        final gate = fixture.onlineStore.gate = Completer<void>();
        final saving = fixture.online.upsertSource(
          onlineTestSource(name: '新配置'),
        );
        await _drain(tester, fixture.onlineStore.started.future);
        final pause = fixture.backend.pauseGate = Completer<void>();
        AppExitResponse? response;
        final exiting = tester.binding.handleRequestAppExit().then((value) {
          response = value;
          return value;
        });
        await _pumpTurns(tester);
        expect(response, isNull);
        fixture.onlineStore.fail = true;
        gate.complete();
        expect(await _drain(tester, saving), isFalse);
        // The write fails while shutdown is still awaiting pause. The exit
        // checkpoint must have been captured before that first async wait.
        pause.complete();
        fixture.backend.pauseGate = null;
        await _pumpTurns(tester);

        expect(find.text('更改尚未保存'), findsOneWidget);
        expect(response, isNull);
        expect(fixture.backend.disposed, isFalse);
        expect(fixture.onlineStore.snapshot.sources, isEmpty);
        await tester.tap(find.text('返回播放器'));
        await tester.pumpAndSettle();
        expect(await _drain(tester, exiting), AppExitResponse.cancel);

        fixture.onlineStore.fail = false;
        fixture.onlineStore.gate = null;
        expect(
          await _drain(
            tester,
            fixture.online.upsertSource(onlineTestSource(name: '重试后的配置')),
          ),
          isTrue,
        );
        expect(fixture.onlineStore.snapshot.sources.single.name, '重试后的配置');
        expect(
          await _drain(tester, tester.binding.handleRequestAppExit()),
          AppExitResponse.exit,
        );
        expect(tester.takeException(), isNull);
      });
    },
  );

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

  testWidgets(
    'late editor save cannot dismiss the timed-out exit confirmation',
    (tester) async {
      await _withApp(tester, (fixture) async {
        final gate = fixture.onlineStore.gate = Completer<void>();
        await tester.tap(find.byKey(const Key('nav-3')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('online-add-source')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('online-source-json')),
          jsonEncode(onlineTestSource(name: '稍后保存成功').toJson()),
        );
        final query = find.byKey(const Key('online-test-query'));
        await tester.ensureVisible(query);
        await tester.enterText(query, '退出测试');
        await tester.tap(find.byKey(const Key('online-source-save')));
        await tester.pump();
        await _drain(tester, fixture.onlineStore.started.future);

        AppExitResponse? response;
        final exiting = tester.binding.handleRequestAppExit().then((value) {
          response = value;
          return value;
        });
        await _pumpTurns(tester);
        await tester.pump(const Duration(seconds: 9));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('更改尚未保存'), findsOneWidget);
        expect(response, isNull);
        expect(fixture.backend.disposed, isFalse);

        gate.complete();
        fixture.onlineStore.gate = null;
        await _pumpTurns(tester);
        await tester.pump(const Duration(milliseconds: 300));
        expect(fixture.onlineStore.snapshot.sources.single.name, '稍后保存成功');
        expect(
          find.byKey(const Key('online-source-json'), skipOffstage: false),
          findsOneWidget,
        );
        expect(find.text('更改尚未保存'), findsOneWidget);
        expect(response, isNull);
        await tester.tap(find.text('返回播放器'));
        await tester.pumpAndSettle();
        expect(await _drain(tester, exiting), AppExitResponse.cancel);
        expect(fixture.backend.disposed, isFalse);
        expect(find.byKey(const Key('online-source-json')), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('online-source-json')), findsNothing);
        await tester.tap(find.byKey(const Key('online-source-actions')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('编辑音乐源'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('online-source-json')),
          jsonEncode(onlineTestSource(name: '返回后再次编辑').toJson()),
        );
        await tester.ensureVisible(find.byKey(const Key('online-source-save')));
        await tester.tap(find.byKey(const Key('online-source-save')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('online-source-json')), findsNothing);
        expect(fixture.onlineStore.snapshot.sources.single.name, '返回后再次编辑');
        expect(
          await _drain(tester, tester.binding.handleRequestAppExit()),
          AppExitResponse.exit,
        );
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'editor save during exit pause keeps lifecycle observers mounted',
    (tester) async {
      await _withApp(tester, (fixture) async {
        final gate = fixture.onlineStore.gate = Completer<void>();
        await tester.tap(find.byKey(const Key('nav-3')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('online-add-source')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('online-source-json')),
          jsonEncode(onlineTestSource(name: '暂停期间保存成功').toJson()),
        );
        final query = find.byKey(const Key('online-test-query'));
        await tester.ensureVisible(query);
        await tester.enterText(query, '退出测试');
        await tester.tap(find.byKey(const Key('online-source-save')));
        await tester.pump();
        await _drain(tester, fixture.onlineStore.started.future);

        final pause = fixture.backend.pauseGate = Completer<void>();
        Object? exitFailure;
        final exiting = tester.binding.handleRequestAppExit().then(
          (response) => response,
          onError: (Object error) {
            exitFailure = error;
            return AppExitResponse.cancel;
          },
        );
        await _pumpTurns(tester);
        gate.complete();
        fixture.onlineStore.gate = null;
        await _pumpTurns(tester);
        await tester.pump(const Duration(milliseconds: 400));
        final editorStayedMounted = find
            .byKey(const Key('online-source-json'), skipOffstage: false)
            .evaluate()
            .isNotEmpty;
        pause.complete();
        fixture.backend.pauseGate = null;
        final response = await _drain(tester, exiting);

        expect(editorStayedMounted, isTrue);
        expect(exitFailure, isNull);
        expect(response, AppExitResponse.exit);
        expect(fixture.onlineStore.snapshot.sources.single.name, '暂停期间保存成功');
        expect(fixture.backend.disposed, isTrue);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'canceling an online save timeout permits a late commit and newer edit',
    (tester) async {
      await _withApp(tester, (fixture) async {
        final gate = fixture.onlineStore.gate = Completer<void>();
        final saving = fixture.online.upsertSource(
          onlineTestSource(name: '旧请求'),
        );
        await _drain(tester, fixture.onlineStore.started.future);
        final exiting = tester.binding.handleRequestAppExit();
        await _pumpTurns(tester);
        await tester.pump(const Duration(seconds: 9));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('更改尚未保存'), findsOneWidget);
        expect(fixture.backend.disposed, isFalse);
        await tester.tap(find.text('返回播放器'));
        await tester.pumpAndSettle();
        expect(await _drain(tester, exiting), AppExitResponse.cancel);

        final editing = fixture.online.upsertSource(
          onlineTestSource(name: '取消后新编辑'),
        );
        gate.complete();
        fixture.onlineStore.gate = null;
        expect(await _drain(tester, saving), isTrue);
        expect(await _drain(tester, editing), isTrue);
        expect(fixture.onlineStore.snapshot.sources.single.name, '取消后新编辑');
        expect(fixture.online.sources.single.name, '取消后新编辑');
        expect(
          await _drain(tester, tester.binding.handleRequestAppExit()),
          AppExitResponse.exit,
        );
        expect(tester.takeException(), isNull);
      });
    },
  );

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

Future<File> _copyPickerFixture(WidgetTester tester) async {
  final copied = await tester.runAsync(() async {
    final directory = await Directory(
      'D:/dev/tmp',
    ).createTemp('hanmusic-exit-picker-');
    final normalized = directory.absolute.path
        .replaceAll('\\', '/')
        .toLowerCase();
    if (!normalized.startsWith('d:/dev/tmp/hanmusic-exit-picker-')) {
      throw StateError('Unexpected test fixture directory.');
    }
    final file = File('${directory.path}/picked.wav');
    addTearDown(() async {
      if (await file.exists()) await file.delete();
      // Only remove the owned file and its empty private directory.
      if (await directory.exists()) await directory.delete();
    });
    return File('test/library/fixtures/tagged.wav').copy(file.path);
  });
  return copied!;
}

Future<void> _withApp(
  WidgetTester tester,
  Future<void> Function(_Fixture fixture) run, {
  _ExitPickers? pickers,
  bool controllerHasLibrary = true,
}) async {
  Get.reset();
  Get.testMode = true;
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  final fixture = _Fixture();
  try {
    await fixture.initialize();
    if (pickers != null) {
      Get.put(
        PlayerController(
          player: fixture.player,
          timer: fixture.timer,
          picker: pickers,
          library: controllerHasLibrary ? fixture.library : null,
          libraryPicker: pickers,
          online: fixture.online,
        ),
      );
    }
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
    fixture.onlineStore.fail = false;
    final onlineGate = fixture.onlineStore.gate;
    if (onlineGate != null && !onlineGate.isCompleted) onlineGate.complete();
    fixture.onlineStore.gate = null;
    final pauseGate = fixture.backend.pauseGate;
    if (pauseGate != null && !pauseGate.isCompleted) pauseGate.complete();
    fixture.backend.pauseGate = null;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
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
    await tester.pump(Duration.zero);
  }
  expect(
    completed,
    isTrue,
    reason: 'Exit/cleanup must complete without advancing deadline timers.',
  );
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return result as T;
}

Future<void> _pumpTurns(WidgetTester tester) async {
  for (var turn = 0; turn < 15; turn++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(Duration.zero);
  }
}

class _Fixture {
  final backend = _ExitAudioBackend();
  final store = _MemoryStateStore();
  final onlineStore = _GatedOnlineSourceStore();
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
          metadataReader: (_) => throw const FormatException('Use filename'),
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

class _GatedOnlineSourceStore extends MemoryOnlineSourceStore {
  Completer<void>? gate;
  final started = Completer<void>();
  bool fail = false;

  @override
  Future<void> save(OnlineSourceSnapshot next) async {
    if (!started.isCompleted) started.complete();
    if (gate case final pending?) await pending.future;
    if (fail) throw const FileSystemException('controlled source-save failure');
    await super.save(next);
  }
}

class _ExitAudioBackend extends FakeAudioBackend {
  Completer<void>? pauseGate;

  @override
  Future<void> pause() async {
    await super.pause();
    if (pauseGate case final pending?) await pending.future;
  }
}

class _ExitPickers implements SongPicker, LibraryPicker {
  var files = Completer<List<String>>();
  var directory = Completer<String?>();
  var song = Completer<Song?>();
  int calls = 0;

  @override
  Future<List<String>> pickFiles() {
    calls++;
    return files.future;
  }

  @override
  Future<String?> pickDirectory() {
    calls++;
    return directory.future;
  }

  @override
  Future<Song?> pick() {
    calls++;
    return song.future;
  }

  void reset() {
    files = Completer<List<String>>();
    directory = Completer<String?>();
    song = Completer<Song?>();
  }

  void complete(String entry, File file) {
    switch (entry) {
      case 'files':
        files.complete([file.path]);
      case 'directory':
        directory.complete(file.parent.path);
      case 'single':
        song.complete(Song(uri: file.uri, fileName: 'picked.wav'));
    }
  }
}
