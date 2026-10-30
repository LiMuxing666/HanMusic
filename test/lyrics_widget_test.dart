import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/view.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import 'support/fake_audio_backend.dart';

void main() {
  testWidgets(
    'lyrics highlight playback and pause following during manual scroll',
    (tester) async {
      final lrc = List.generate(
        60,
        (index) => '[00:${index.toString().padLeft(2, '0')}.00]第 $index 句歌词',
      ).join('\n');
      await _withLyrics(tester, lrc, (fixture) async {
        await _waitForLyrics(tester);
        await tester.ensureVisible(find.byKey(const Key('lyrics-card')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Semantics>(find.byKey(const Key('lyrics-line-0')))
              .properties
              .selected,
          isTrue,
        );

        fixture.backend.emitPosition(const Duration(seconds: 25));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Semantics>(find.byKey(const Key('lyrics-line-25')))
              .properties
              .selected,
          isTrue,
        );
        final scroll = _lyricsScroll(tester);
        expect(scroll.pixels, greaterThan(0));

        await tester.drag(
          find.byKey(const Key('lyrics-list')),
          const Offset(0, 130),
        );
        await tester.pumpAndSettle();
        expect(find.text('自动跟随已暂停'), findsOneWidget);
        final manualPosition = scroll.pixels;
        fixture.backend.emitPosition(const Duration(seconds: 40));
        await tester.pumpAndSettle();
        expect(scroll.pixels, closeTo(manualPosition, 0.1));

        await tester.tap(find.byKey(const Key('lyrics-follow-current')));
        await tester.pumpAndSettle();
        expect(find.text('自动跟随'), findsOneWidget);
        expect(scroll.pixels, greaterThan(manualPosition));
        expect(
          tester
              .widget<Semantics>(find.byKey(const Key('lyrics-line-40')))
              .properties
              .selected,
          isTrue,
        );

        await tester.drag(
          find.byKey(const Key('lyrics-list')),
          const Offset(0, 100),
        );
        await tester.pumpAndSettle();
        expect(find.text('自动跟随已暂停'), findsOneWidget);
        await tester.pump(const Duration(seconds: 9));
        await tester.pumpAndSettle();
        expect(find.text('自动跟随'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets('switching to online songs clears local lyrics immediately', (
    tester,
  ) async {
    await _withLyrics(tester, '[00:00]本地歌词', (fixture) async {
      await _waitForLyrics(tester);
      expect(find.text('本地歌词'), findsOneWidget);
      await fixture.player.playQueue([
        Song.online(sourceId: 'source', trackId: 'online', title: '在线歌曲'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('本地歌词'), findsNothing);
      expect(find.text('在线歌曲尚未关联本地歌词。'), findsOneWidget);
      expect(find.byKey(const Key('lyrics-list')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('plain lyrics and long content fit compact large text', (
    tester,
  ) async {
    await _withLyrics(
      tester,
      '没有时间标签的第一句歌词\n${'很长的歌词'.padRight(160, '词')}',
      (fixture) async {
        await _waitForLyrics(tester);
        await tester.ensureVisible(find.byKey(const Key('lyrics-card')));
        await tester.pumpAndSettle();
        expect(find.text('纯文本歌词，未检测到有效时间标签。'), findsOneWidget);
        expect(find.byKey(const Key('lyrics-follow-current')), findsNothing);
        expect(find.byKey(const Key('lyrics-current-line')), findsNothing);
        expect(tester.takeException(), isNull);
      },
      size: const Size(800, 600),
      textScale: 2,
    );
  });

  testWidgets('missing lyrics explain the sidecar convention and can reload', (
    tester,
  ) async {
    await _withLyrics(tester, null, (fixture) async {
      await _waitForLyrics(tester, expectList: false);
      expect(find.textContaining('未找到同名歌词'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('lyrics-reload')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await fixture.lyricFile.writeAsString('[00:00]后来补充的歌词');
        await tester.tap(find.byKey(const Key('lyrics-reload')));
        await tester.pump();
      });
      await _waitForLyrics(tester);
      expect(find.text('后来补充的歌词'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

ScrollPosition _lyricsScroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('lyrics-list')),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

Future<void> _waitForLyrics(
  WidgetTester tester, {
  bool expectList = true,
}) async {
  final expected = find.byKey(
    Key(expectList ? 'lyrics-list' : 'lyrics-message'),
  );
  await tester.runAsync(() async {
    for (
      var attempt = 0;
      attempt < 250 && expected.evaluate().isEmpty;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
  expect(expected, findsOneWidget);
}

Future<void> _withLyrics(
  WidgetTester tester,
  String? text,
  Future<void> Function(_LyricsFixture fixture) run, {
  Size size = const Size(1280, 1000),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final directory = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('hanmusic-lyrics-widget-'),
  ))!;
  final fixture = _LyricsFixture(directory);
  try {
    await tester.runAsync(() async {
      if (text != null) await fixture.lyricFile.writeAsString(text);
    });
    await fixture.player.playQueue([fixture.song]);
    await tester.pumpWidget(
      MaterialApp(
        theme: HanMusicTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: PlayerPage(controller: fixture.controller),
      ),
    );
    await tester.pumpAndSettle();
    // Start native file IO outside FakeAsync so its completion remains real.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('nav-1')));
      await tester.pump();
    });
    await run(fixture);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.controller.onClose();
    fixture.library.onClose();
    fixture.timer.onClose();
    await tester.runAsync(() async {
      await fixture.player.shutdown();
      await directory.delete(recursive: true);
    });
    await tester.pump();
  }
}

class _LyricsFixture {
  _LyricsFixture(this.directory) {
    player = PlayerService(backend);
    timer = TimerService(onExpired: player.pause);
    library = LibraryService(
      repository: LocalLibraryRepository(artworkDirectory: directory),
    );
    controller = PlayerController(
      player: player,
      timer: timer,
      picker: _NoSongPicker(),
      library: library,
    );
    controller.onInit();
  }

  final Directory directory;
  final backend = FakeAudioBackend();
  late final PlayerService player;
  late final TimerService timer;
  late final LibraryService library;
  late final PlayerController controller;
  File get lyricFile => File('${directory.path}/lyrics.lrc');
  Song get song => Song(
    uri: File('${directory.path}/lyrics.mp3').uri,
    fileName: 'lyrics.mp3',
  );
}

class _NoSongPicker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}
