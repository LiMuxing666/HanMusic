import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/view.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/desktop_media_service.dart';
import 'package:han_music/app/services/online_music_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import 'support/fake_audio_backend.dart';
import 'support/fake_online_music.dart';

void main() {
  testWidgets('tray action is available and fits compact large text', (
    tester,
  ) async {
    const channel = MethodChannel('hanmusic/desktop_media');
    var hideCalls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'initialize') {
        return {'tray': true, 'mediaControls': true};
      }
      if (call.method == 'hideToTray') hideCalls++;
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await _withPlayer(
      tester,
      size: const Size(800, 600),
      scale: 2,
      run: (fixture) async {
        expect(find.byKey(const Key('hide-to-tray')), findsNothing);
        await fixture.desktopMedia.start();
        await tester.pumpAndSettle();
        await _tap(tester, find.byKey(const Key('hide-to-tray')));
        expect(hideCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets('song details copy the stable path and fit compact large text', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _withPlayer(
      tester,
      size: const Size(800, 600),
      scale: 2,
      run: (fixture) async {
        final song = fixture.library.songs.first;
        await _libraryAction(tester, song, '歌曲详情');
        expect(find.text('歌曲详情'), findsWidgets);
        expect(
          tester
              .widgetList<SelectableText>(find.byType(SelectableText))
              .map((widget) => widget.data),
          contains(song.path),
        );
        await _tap(tester, find.byKey(const Key('song-details-copy')));
        expect(copied, song.path);
        expect(fixture.backend.playCalls, 0);
        expect(tester.takeException(), isNull);
        await _tap(tester, find.text('关闭'));
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  });

  testWidgets(
    'library favorites and custom playlist complete an editing cycle',
    (tester) async {
      await _withPlayer(
        tester,
        run: (fixture) async {
          final first = fixture.library.songs[0];
          final second = fixture.library.songs[1];
          await _libraryAction(tester, first, '加入我喜欢');
          expect(fixture.controller.isFavorite(first), isTrue);
          await _libraryAction(tester, first, '添加到歌单');
          await _tap(tester, find.byKey(const Key('playlist-create-and-add')));
          await _tap(tester, find.byKey(const Key('playlist-name-confirm')));
          expect(find.textContaining('1–100'), findsWidgets);
          await tester.enterText(find.byKey(const Key('playlist-name')), '通勤');
          await _tap(tester, find.byKey(const Key('playlist-name-confirm')));
          final playlist = fixture.controller.playlists.playlists.last;
          expect(playlist.name, '通勤');
          expect(playlist.songs.single.id, first.id);
          await _libraryAction(tester, second, '添加到歌单');
          await _tap(
            tester,
            find.byKey(ValueKey('choose-playlist-${playlist.id}')),
          );
          await _libraryAction(tester, second, '添加到歌单');
          await _tap(
            tester,
            find.byKey(ValueKey('choose-playlist-${playlist.id}')),
          );
          expect(find.text('“通勤”中已存在这首歌曲。'), findsOneWidget);
          expect(fixture.controller.playlistSongs(playlist.id).length, 2);

          await _tap(tester, find.byKey(const Key('nav-4')));
          expect(
            find.byKey(ValueKey('playlist-row-${first.id}')),
            findsOneWidget,
          );
          expect(
            tester
                .widget<TextButton>(find.byKey(const Key('playlist-delete')))
                .onPressed,
            isNull,
          );
          await _tap(tester, find.byKey(const Key('playlist-select')));
          await _tap(tester, find.text('通勤'));
          await _tap(tester, find.byKey(const Key('playlist-play-all')));
          expect(fixture.player.queue.map((song) => song.id), [
            first.id,
            second.id,
          ]);
          await _tap(tester, find.byKey(const Key('playlist-rename')));
          await tester.enterText(
            find.byKey(const Key('playlist-name')),
            '通勤音乐',
          );
          await _tap(tester, find.byKey(const Key('playlist-name-confirm')));
          expect(
            fixture.controller.playlists.findById(playlist.id)!.name,
            '通勤音乐',
          );
          await _tap(
            tester,
            find.byKey(ValueKey('playlist-menu-${second.id}')),
          );
          await _tap(tester, find.byKey(ValueKey('playlist-up-${second.id}')));
          expect(
            fixture.controller
                .playlistSongs(playlist.id)
                .map((song) => song.id),
            [second.id, first.id],
          );
          await _tap(tester, find.byKey(ValueKey('playlist-menu-${first.id}')));
          await _tap(
            tester,
            find.byKey(ValueKey('playlist-remove-${first.id}')),
          );
          expect(
            fixture.controller.playlistSongs(playlist.id).single.id,
            second.id,
          );
          await _tap(tester, find.byKey(const Key('playlist-delete')));
          await _tap(tester, find.text('取消'));
          expect(fixture.controller.playlists.findById(playlist.id), isNotNull);
          await _tap(tester, find.byKey(const Key('playlist-delete')));
          await _tap(tester, find.byKey(const Key('playlist-delete-confirm')));
          expect(fixture.controller.playlists.findById(playlist.id), isNull);
          expect(fixture.library.songs.length, 3);
          expect(fixture.player.queue.length, 2);
          expect(fixture.player.isPlaying.value, isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets('online and queue actions share favorites and play next', (
    tester,
  ) async {
    await _withPlayer(
      tester,
      run: (fixture) async {
        await fixture.controller.playLibrarySong(fixture.library.songs.first);
        await tester.pumpAndSettle();
        await _tap(tester, find.byKey(const Key('current-favorite')));
        expect(
          fixture.controller.isFavorite(fixture.library.songs.first),
          isTrue,
        );
        await _tap(tester, find.byKey(const Key('nav-3')));
        await tester.enterText(find.byKey(const Key('online-query')), '夜色');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        final song = fixture.online.results.single;
        final menu = find.byKey(ValueKey('online-actions-${song.id}'));
        await _tap(tester, menu);
        await _tap(tester, find.text('加入我喜欢'));
        expect(fixture.controller.isFavorite(song), isTrue);
        await _tap(tester, menu);
        await _tap(tester, find.text('下一首播放'));
        expect(fixture.player.currentSong.value!.isOnline, isFalse);
        await _tap(tester, find.byKey(const Key('next-track')));
        expect(fixture.player.currentSong.value!.id, song.id);
        await _tap(tester, find.byKey(const Key('nav-2')));
        await _tap(tester, find.byKey(ValueKey('queue-actions-${song.id}')));
        await _tap(tester, find.text('取消喜欢'));
        expect(fixture.controller.isFavorite(song), isFalse);
        await _tap(tester, find.byKey(ValueKey('queue-actions-${song.id}')));
        await _tap(tester, find.text('添加到歌单'));
        await _tap(
          tester,
          find.byKey(const ValueKey('choose-playlist-favorites')),
        );
        expect(fixture.controller.isFavorite(song), isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets('playlist controls and dialogs remain reachable at 200 percent', (
    tester,
  ) async {
    await _withPlayer(
      tester,
      size: const Size(800, 600),
      scale: 2,
      run: (fixture) async {
        final song = fixture.library.songs.first;
        fixture.controller.toggleFavorite(song);
        await _tap(tester, find.byKey(const Key('nav-4')));
        await _tap(tester, find.byKey(const Key('playlist-create')));
        await tester.enterText(
          find.byKey(const Key('playlist-name')),
          '慢慢听音乐的长名字歌单',
        );
        await _tap(tester, find.byKey(const Key('playlist-name-confirm')));
        final playlist = fixture.controller.playlists.playlists.last;
        fixture.controller.addSongsToPlaylist(
          playlist.id,
          fixture.library.songs.toList(),
        );
        await tester.pumpAndSettle();
        await _tap(tester, find.byKey(const Key('playlist-enqueue-all')));
        expect(fixture.player.queue.length, 2);
        expect(fixture.player.isPlaying.value, isFalse);
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.byKey(ValueKey('playlist-menu-${song.id}')),
          180,
          scrollable: find.descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          ),
        );
        await _tap(tester, find.byKey(ValueKey('playlist-menu-${song.id}')));
        await _tap(tester, find.byKey(ValueKey('playlist-remove-${song.id}')));
        expect(fixture.controller.playlistSongs(playlist.id).length, 2);
        expect(tester.takeException(), isNull);
      },
    );
  });
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _libraryAction(
  WidgetTester tester,
  Song song,
  String action,
) async {
  await _tap(tester, find.byTooltip('${song.title}的操作'));
  await _tap(tester, find.text(action));
}

Future<void> _withPlayer(
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
  await fixture.online.initialize();
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
    await run(fixture);
  } finally {
    fixture.controller.onDelete();
    fixture.timer.onClose();
    fixture.library.onClose();
    await fixture.desktopMedia.close();
    await fixture.online.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.player.shutdown);
  }
}

class _Fixture {
  _Fixture() {
    online = OnlineMusicService(
      repository: FakeOnlineMusicRepository(),
      store: MemoryOnlineSourceStore(
        sources: [onlineTestSource()],
        selected: 'demo',
      ),
    );
    player = PlayerService(backend, resolver: online.resolveForPlayback);
    desktopMedia = DesktopMediaService(player, enabled: true);
    timer = TimerService(onExpired: player.pause);
    library = LibraryService(
      repository: LocalLibraryRepository(
        artworkDirectory: Directory('build/test-playlist-artwork'),
      ),
    );
    library.replaceAll(
      List.generate(
        3,
        (i) => Song(
          uri: Uri.file('D:/music/playlist-$i.mp3', windows: true),
          fileName: 'playlist-$i.mp3',
          trackTitle: '歌单歌曲 $i',
          artist: '测试歌手',
          duration: const Duration(minutes: 3),
          isMissing: i == 2,
        ),
      ),
    );
    controller = PlayerController(
      player: player,
      timer: timer,
      library: library,
      online: online,
      desktopMedia: desktopMedia,
      picker: _Picker(),
    );
  }
  final backend = FakeAudioBackend();
  late final PlayerService player;
  late final DesktopMediaService desktopMedia;
  late final LibraryService library;
  late final TimerService timer;
  late final OnlineMusicService online;
  late final PlayerController controller;
}

class _Picker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}
