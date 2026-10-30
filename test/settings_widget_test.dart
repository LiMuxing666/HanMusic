import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:han_music/app/data/models/app_settings.dart';
import 'package:han_music/app/data/models/library_sort.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/services/app_persistence_service.dart';
import 'package:han_music/app/services/app_settings_service.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/online_music_service.dart';
import 'package:han_music/app/services/play_history_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/playlist_service.dart';
import 'package:han_music/app/services/sleep_timer_coordinator.dart';
import 'package:han_music/app/services/timer_service.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/main.dart';

import 'support/fake_audio_backend.dart';
import 'support/fake_online_music.dart';

void main() {
  testWidgets(
    'live light, dark and system themes preserve navigation and playback',
    (tester) async {
      await _withApp(tester, (fixture) async {
        await fixture.player.open(fixture.song);
        await tester.pumpAndSettle();
        final selection = fixture.player.selectionRevision;
        await _tap(tester, const Key('settings-theme-dark'));
        expect(fixture.settings.settings.value.themeMode, ThemeMode.dark);
        expect(_brightness(tester), Brightness.dark);
        expect(fixture.player.selectionRevision, selection);
        expect(fixture.player.currentSong.value?.id, fixture.song.id);
        expect(fixture.player.isPlaying.value, isTrue);
        expect(fixture.backend.playCalls, 1);

        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await _tap(tester, const Key('settings-theme-system'));
        expect(_brightness(tester), Brightness.dark);
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        await tester.pumpAndSettle();
        expect(_brightness(tester), Brightness.light);
        await _tap(tester, const Key('settings-theme-light'));
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await tester.pumpAndSettle();
        expect(_brightness(tester), Brightness.light);
        expect(fixture.backend.playCalls, 1);
      });
    },
  );

  testWidgets(
    'settings sort, error skipping and explicit save share the real services',
    (tester) async {
      await _withApp(tester, (fixture) async {
        await _tap(tester, const Key('settings-sort-importOrder'));
        await tester.tap(find.text('歌曲名称').last);
        await tester.pumpAndSettle();
        await _tap(tester, const Key('settings-sort-descending'));
        expect(fixture.controller.librarySort.value, LibrarySort.title);
        expect(fixture.settings.settings.value.librarySort, LibrarySort.title);
        expect(fixture.settings.settings.value.librarySortDescending, isTrue);
        await _tap(tester, const Key('settings-skip-errors'));
        expect(fixture.player.skipOnError.value, isFalse);
        await _tap(tester, const Key('settings-save'));
        expect(find.text('设置与播放状态已保存。'), findsOneWidget);
        expect(
          fixture.store.saved.last.settings.librarySort,
          LibrarySort.title,
        );
        expect(fixture.store.saved.last.settings.librarySortDescending, isTrue);
        expect(fixture.store.saved.last.skipOnError, isFalse);
        expect(fixture.store.saved.last.songs, hasLength(1));
        expect(fixture.store.saved.last.queue, hasLength(1));
        expect(fixture.store.saved.last.playlists, hasLength(1));
      });
    },
  );

  testWidgets(
    'reset confirmation cancels safely and becomes stale after a canceled exit',
    (tester) async {
      await _withApp(tester, (fixture) async {
        fixture.settings.restore(
          const AppSettings(
            themeMode: ThemeMode.dark,
            librarySort: LibrarySort.artist,
            librarySortDescending: true,
          ),
        );
        fixture.player.skipOnError.value = false;
        await tester.pumpAndSettle();
        await _tap(tester, const Key('settings-reset'));
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(fixture.settings.settings.value.themeMode, ThemeMode.dark);
        await _tap(tester, const Key('settings-reset'));
        fixture.controller.beginExit();
        fixture.controller.cancelExit();
        await _tap(tester, const Key('settings-confirm-reset'));
        expect(fixture.settings.settings.value.librarySort, LibrarySort.artist);
        await _tap(tester, const Key('settings-reset'));
        await _tap(tester, const Key('settings-confirm-reset'));
        expect(fixture.settings.settings.value, const AppSettings());
        expect(fixture.controller.librarySort.value, LibrarySort.importOrder);
        expect(fixture.player.skipOnError.value, isFalse);
        expect(fixture.player.queue, hasLength(1));
        expect(fixture.library.songs, hasLength(1));
      });
    },
  );

  testWidgets(
    'save errors and stale save completions never show a false success',
    (tester) async {
      await _withApp(tester, (fixture) async {
        fixture.store.fail = true;
        await _tap(tester, const Key('settings-save'));
        expect(find.text('保存失败，请检查数据目录的空间与权限后重试。'), findsOneWidget);
        fixture.store.fail = false;
        fixture.store.gate = Completer<void>();
        await _tap(tester, const Key('settings-save'));
        expect(find.text('正在保存…'), findsOneWidget);
        fixture.controller.beginExit();
        fixture.controller.cancelExit();
        fixture.store.gate!.complete();
        await tester.pumpAndSettle();
        expect(find.text('设置与播放状态已保存。'), findsNothing);
        fixture.store.gate = null;
      });
    },
  );

  testWidgets(
    'compact dark settings and component licenses remain reachable at 200 percent text',
    (tester) async {
      await _withApp(
        tester,
        (fixture) async {
          expect(_brightness(tester), Brightness.dark);
          await _tap(tester, const Key('settings-licenses'));
          expect(find.byType(LicensePage), findsOneWidget);
          expect(tester.takeException(), isNull);
          Navigator.of(tester.element(find.byType(LicensePage))).pop();
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('settings-scroll')), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
        size: const Size(800, 600),
        scale: 2,
        initial: const AppSettings(themeMode: ThemeMode.dark),
      );
    },
  );
}

Brightness _brightness(WidgetTester tester) => Theme.of(
  tester.element(find.byKey(const Key('settings-theme-light'))),
).brightness;

Future<void> _tap(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _withApp(
  WidgetTester tester,
  Future<void> Function(_Fixture) run, {
  Size size = const Size(1280, 800),
  double scale = 1,
  AppSettings initial = const AppSettings(),
}) async {
  Get.reset();
  Get.testMode = true;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  final fixture = _Fixture(initial);
  try {
    await fixture.initialize();
    await tester.pumpWidget(const HanMusicApp());
    await tester.pumpAndSettle();
    fixture.controller = Get.find<PlayerController>();
    await _tap(tester, const Key('nav-6'));
    await run(fixture);
  } finally {
    fixture.store.fail = false;
    if (fixture.store.gate case final gate?) {
      if (!gate.isCompleted) gate.complete();
    }
    fixture.store.gate = null;
    final observer =
        tester.state(find.byType(HanMusicApp)) as WidgetsBindingObserver;
    await tester.runAsync(observer.didRequestAppExit);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => fixture.persistence.close(flush: false));
    Get.reset();
    Get.testMode = false;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
  }
}

class _Fixture {
  _Fixture(this.initial);
  final AppSettings initial;
  final backend = FakeAudioBackend();
  final store = _Store();
  final song = Song(
    uri: Uri.file('D:/music/settings.wav', windows: true),
    fileName: 'settings.wav',
  );
  late final AppSettingsService settings;
  late final PlayerService player;
  late final LibraryService library;
  late final AppPersistenceService persistence;
  late final PlayerController controller;

  Future<void> initialize() async {
    settings = Get.put(AppSettingsService(initial: initial), permanent: true);
    library = Get.put(
      LibraryService(
        repository: LocalLibraryRepository(
          artworkDirectory: Directory('build/settings-widget-artwork'),
        ),
      ),
      permanent: true,
    )..replaceAll([song]);
    final online = Get.put(
      OnlineMusicService(
        repository: FakeOnlineMusicRepository(),
        store: MemoryOnlineSourceStore(),
      ),
      permanent: true,
    );
    await online.initialize();
    player = Get.put(PlayerService(backend), permanent: true);
    await player.restoreQueue([song]);
    final playlists = Get.put(PlaylistService(), permanent: true);
    final history = Get.put(PlayHistoryService(player), permanent: true);
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
  final saved = <AppSnapshot>[];
  bool fail = false;
  Completer<void>? gate;
  @override
  String? get warning => null;
  @override
  Future<AppSnapshot> load() async => const AppSnapshot();
  @override
  Future<void> save(AppSnapshot snapshot) async {
    if (fail) {
      throw const FileSystemException('controlled settings save failure');
    }
    if (gate case final pending?) await pending.future;
    saved.add(snapshot);
  }
}
