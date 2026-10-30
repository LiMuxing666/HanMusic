import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/play_history_entry.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/view.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/online_music_service.dart';
import 'package:han_music/app/services/play_history_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import 'support/fake_audio_backend.dart';
import 'support/fake_online_music.dart';

void main() {
  for (final theme in [HanMusicTheme.light, HanMusicTheme.dark]) {
    test('${theme.brightness.name} reading and action colors meet 4.5:1', () {
      final colors = theme.extension<HanMusicColors>()!;
      final scheme = theme.colorScheme;
      for (final background in [
        scheme.surface,
        theme.scaffoldBackgroundColor,
        colors.selectedSurface,
        colors.subtleSurface,
      ]) {
        for (final foreground in [
          scheme.onSurface,
          colors.muted,
          scheme.primary,
        ]) {
          expect(
            _contrast(foreground, background),
            greaterThanOrEqualTo(4.5),
            reason: '$foreground on $background',
          );
        }
      }
      expect(
        _contrast(scheme.onPrimary, scheme.primary),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(colors.onWarning, colors.warningSurface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(scheme.error, scheme.surface),
        greaterThanOrEqualTo(4.5),
      );
    });
  }

  testWidgets(
    'switching theme repaints selection, missing text and errors without changing playback',
    (tester) async {
      await _withPlayer(
        tester,
        run: (fixture, mode) async {
          fixture.controller.selectLibrarySong(fixture.first);
          fixture.player.errorMessage.value = '主题测试：播放失败';
          await tester.pumpAndSettle();
          final position = fixture.player.position.value;
          final queue = fixture.player.queue.map((song) => song.id).toList();
          for (final themeMode in [ThemeMode.dark, ThemeMode.light]) {
            mode.value = themeMode;
            await tester.pumpAndSettle();
            final colors = themeMode == ThemeMode.dark
                ? HanMusicColors.dark
                : HanMusicColors.light;
            final row = find.byKey(
              ValueKey('library-song-${fixture.first.id}'),
            );
            final materials = tester.widgetList<Material>(
              find.ancestor(of: row, matching: find.byType(Material)),
            );
            expect(
              materials.any(
                (material) => material.color == colors.selectedSurface,
              ),
              isTrue,
            );
            expect(
              tester.widget<Text>(find.text('文件缺失 · 可检查或移除索引')).style!.color,
              colors.muted,
            );
            expect(
              tester.widget<Text>(find.text('主题测试：播放失败')).style!.color,
              colors.onWarning,
            );
            expect(
              fixture.controller.selectedLibraryIds,
              contains(fixture.first.id),
            );
            expect(fixture.player.position.value, position);
            expect(fixture.player.queue.map((song) => song.id), queue);
            expect(tester.takeException(), isNull);
          }
        },
      );
    },
  );

  testWidgets(
    'dark main pages, playlist dialog, history menu and clear dialog inherit the active theme',
    (tester) async {
      await _withPlayer(
        tester,
        run: (fixture, mode) async {
          mode.value = ThemeMode.dark;
          await tester.pumpAndSettle();
          for (final index in [1, 2, 3, 4, 5]) {
            await _tap(tester, find.byKey(Key('nav-$index')));
            final pageContext = tester.element(find.byKey(Key('nav-$index')));
            expect(Theme.of(pageContext).brightness, Brightness.dark);
            expect(tester.takeException(), isNull);
          }

          await _tap(
            tester,
            find.byKey(ValueKey('history-menu-${fixture.first.id}')),
          );
          final menu = find.text('移除这条记录');
          expect(Theme.of(tester.element(menu)).brightness, Brightness.dark);
          // Dismiss a menu without editing the saved history.
          Navigator.of(tester.element(menu)).pop();
          await tester.pumpAndSettle();
          await _tap(tester, find.byKey(const Key('history-clear')));
          expect(
            Theme.of(tester.element(find.byType(AlertDialog))).brightness,
            Brightness.dark,
          );
          await _tap(tester, find.text('取消'));
          expect(fixture.history.entries, hasLength(2));

          await _tap(tester, find.byKey(const Key('nav-4')));
          await _tap(tester, find.byKey(const Key('playlist-create')));
          expect(
            Theme.of(tester.element(find.byType(AlertDialog))).brightness,
            Brightness.dark,
          );
          await _tap(tester, find.text('取消'));
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'all navigation including settings remains reachable in a short dark window',
    (tester) async {
      await _withPlayer(
        tester,
        size: const Size(800, 600),
        scale: 2,
        run: (fixture, mode) async {
          mode.value = ThemeMode.dark;
          await tester.pumpAndSettle();
          for (final index in [6, 3, 5, 4, 2, 1, 0]) {
            await _tap(tester, find.byKey(Key('nav-$index')));
            expect(find.byKey(Key('nav-$index')).hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
        },
      );
    },
  );
}

double _contrast(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  return first > second
      ? (first + .05) / (second + .05)
      : (second + .05) / (first + .05);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _withPlayer(
  WidgetTester tester, {
  required Future<void> Function(_Fixture, ValueNotifier<ThemeMode>) run,
  Size size = const Size(1280, 800),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixture = _Fixture();
  final mode = ValueNotifier(ThemeMode.light);
  await fixture.online.initialize();
  await fixture.player.restoreQueue(
    [fixture.playing, fixture.first, fixture.missing],
    currentId: fixture.playing.id,
    position: const Duration(seconds: 17),
  );
  fixture.controller.onStart();
  try {
    await tester.pumpWidget(
      ValueListenableBuilder<ThemeMode>(
        valueListenable: mode,
        builder: (context, value, child) => MaterialApp(
          theme: HanMusicTheme.light,
          darkTheme: HanMusicTheme.dark,
          themeMode: value,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: PlayerPage(controller: fixture.controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await run(fixture, mode);
  } finally {
    fixture.controller.onDelete();
    fixture.history.onClose();
    fixture.timer.onClose();
    fixture.library.onClose();
    await fixture.online.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.player.shutdown);
    mode.dispose();
  }
}

class _Fixture {
  final playing = Song.online(
    sourceId: 'demo',
    trackId: 'theme-playing',
    title: '当前在线歌曲',
  );
  final first = Song(
    uri: Uri.file('D:/theme-fixture/first.mp3', windows: true),
    fileName: 'first.mp3',
    trackTitle: '主题歌曲',
  );
  final missing = Song(
    uri: Uri.file('D:/theme-fixture/missing.mp3', windows: true),
    fileName: 'missing.mp3',
    trackTitle: '缺失主题歌曲',
    isMissing: true,
  );
  final backend = FakeAudioBackend();
  late final player = PlayerService(backend);
  late final timer = TimerService(onExpired: player.pause);
  late final history = PlayHistoryService(player)
    ..restore([
      for (final song in [first, missing])
        PlayHistoryEntry(
          song: song,
          lastPlayedAt: DateTime.utc(2026, 10, 29),
          playCount: 1,
        ),
    ]);
  late final library = LibraryService(
    repository: LocalLibraryRepository(
      artworkDirectory: Directory('build/theme-widget-artwork'),
    ),
  )..replaceAll([first, missing]);
  final online = OnlineMusicService(
    repository: FakeOnlineMusicRepository(),
    store: MemoryOnlineSourceStore(
      sources: [onlineTestSource()],
      selected: 'demo',
    ),
  );
  late final controller = PlayerController(
    player: player,
    timer: timer,
    picker: _Picker(),
    library: library,
    history: history,
    online: online,
  );
}

class _Picker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}
