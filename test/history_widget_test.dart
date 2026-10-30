import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/play_history_entry.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/view.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/play_history_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import 'support/fake_audio_backend.dart';

void main() {
  testWidgets(
    'history search, replay and removing one entry preserve the library',
    (tester) async {
      await _withHistory(
        tester,
        run: (fixture) async {
          expect(find.text('最近播放'), findsWidgets);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          final input = tester.widget<TextField>(
            find.descendant(
              of: find.byKey(const Key('history-search')),
              matching: find.byType(TextField),
            ),
          );
          expect(input.focusNode!.hasFocus, isTrue);
          await tester.enterText(find.byKey(const Key('history-search')), '晨光');
          await tester.pumpAndSettle();
          expect(
            find.byKey(ValueKey('history-row-${fixture.first.id}')),
            findsOneWidget,
          );
          expect(
            find.byKey(ValueKey('history-row-${fixture.missing.id}')),
            findsNothing,
          );
          await _tap(
            tester,
            find.byKey(ValueKey('history-play-${fixture.first.id}')),
          );
          expect(fixture.player.currentSong.value?.id, fixture.first.id);
          expect(fixture.player.queue.map((song) => song.id), [
            fixture.first.id,
          ]);
          expect(fixture.backend.playCalls, 1);
          await _tap(
            tester,
            find.byKey(ValueKey('history-menu-${fixture.first.id}')),
          );
          await _tap(tester, find.text('移除这条记录'));
          expect(
            fixture.history.entries.any(
              (entry) => entry.song.id == fixture.first.id,
            ),
            isFalse,
          );
          expect(fixture.library.songs.map((song) => song.id), [
            fixture.first.id,
            fixture.missing.id,
          ]);
          expect(fixture.player.isPlaying.value, isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'missing local files and removed online sources remain visible but cannot play',
    (tester) async {
      await _withHistory(
        tester,
        run: (fixture) async {
          for (final song in [fixture.missing, fixture.online]) {
            await tester.enterText(
              find.byKey(const Key('history-search')),
              song.title,
            );
            await tester.pumpAndSettle();
            final play = tester.widget<IconButton>(
              find.byKey(ValueKey('history-play-${song.id}')),
            );
            expect(play.onPressed, isNull);
            await _tap(tester, find.byKey(ValueKey('history-menu-${song.id}')));
            expect(
              tester
                  .widget<PopupMenuItem<String>>(
                    find.widgetWithText(PopupMenuItem<String>, '下一首播放'),
                  )
                  .enabled,
              isFalse,
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
          }
          expect(fixture.backend.playCalls, 0);
          expect(fixture.history.entries, hasLength(3));
        },
      );
    },
  );

  testWidgets(
    'clear history confirms and keeps playback, including compact large text',
    (tester) async {
      await _withHistory(
        tester,
        size: const Size(800, 600),
        scale: 2,
        run: (fixture) async {
          await fixture.player.open(fixture.first);
          await tester.pumpAndSettle();
          await _tap(tester, find.byKey(const Key('history-clear')));
          await _tap(tester, find.text('取消'));
          expect(fixture.history.entries, hasLength(3));
          await _tap(tester, find.byKey(const Key('history-clear')));
          await _tap(tester, find.byKey(const Key('history-confirm-clear')));
          expect(fixture.history.entries, isEmpty);
          expect(fixture.player.currentSong.value?.id, fixture.first.id);
          expect(fixture.player.isPlaying.value, isTrue);
          expect(fixture.library.songs, hasLength(2));
          expect(find.text('还没有播放记录'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'an exit cancellation invalidates an earlier history clear confirmation',
    (tester) async {
      await _withHistory(
        tester,
        run: (fixture) async {
          await _tap(tester, find.byKey(const Key('history-clear')));
          fixture.controller.beginExit();
          fixture.controller.cancelExit();
          await _tap(tester, find.byKey(const Key('history-confirm-clear')));
          expect(fixture.history.entries, hasLength(3));
        },
      );
    },
  );
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _withHistory(
  WidgetTester tester, {
  required Future<void> Function(_Fixture) run,
  Size size = const Size(1280, 800),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixture = _Fixture();
  fixture.controller.onStart();
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: HanMusicTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: PlayerPage(controller: fixture.controller),
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const Key('nav-5')));
    await run(fixture);
  } finally {
    fixture.controller.onDelete();
    fixture.history.onClose();
    fixture.timer.onClose();
    fixture.library.onClose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.player.shutdown);
  }
}

class _Fixture {
  final first = Song(
    uri: Uri.file('D:/music/morning.mp3', windows: true),
    fileName: 'morning.mp3',
    trackTitle: '晨光',
    artist: '测试歌手',
  );
  final missing = Song(
    uri: Uri.file('D:/music/missing.mp3', windows: true),
    fileName: 'missing.mp3',
    trackTitle: '缺失歌曲',
    isMissing: true,
  );
  final online = Song.online(
    sourceId: 'removed',
    trackId: 'song',
    title: '在线歌曲',
  );
  final backend = FakeAudioBackend();
  late final player = PlayerService(backend);
  late final history = PlayHistoryService(player)
    ..restore([
      PlayHistoryEntry(
        song: first,
        lastPlayedAt: DateTime.utc(2026, 10, 29, 12),
        playCount: 2,
      ),
      PlayHistoryEntry(
        song: missing,
        lastPlayedAt: DateTime.utc(2026, 10, 29, 11),
        playCount: 1,
      ),
      PlayHistoryEntry(
        song: online,
        lastPlayedAt: DateTime.utc(2026, 10, 29, 10),
        playCount: 1,
      ),
    ]);
  late final timer = TimerService(onExpired: player.pause);
  late final library = LibraryService(
    repository: LocalLibraryRepository(
      artworkDirectory: Directory('build/history-widget-artwork'),
    ),
  )..replaceAll([first, missing]);
  late final controller = PlayerController(
    player: player,
    timer: timer,
    picker: _Picker(),
    library: library,
    history: history,
  );
}

class _Picker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}
