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
        expect(find.byKey(const Key('lyrics-earlier')), findsNothing);
        expect(
          tester.widget<InkWell>(find.byKey(const Key('lyrics-seek-0'))).onTap,
          isNull,
        );
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

  testWidgets('clicking timed lyrics seeks without changing pause or play', (
    tester,
  ) async {
    const source = '[00:00]开头\n[00:10]第二句\n[00:20]第三句';
    await _withLyrics(tester, source, (fixture) async {
      await _waitForLyrics(tester);
      await fixture.player.pause();
      await tester.pumpAndSettle();
      final playCalls = fixture.backend.playCalls;
      final seekRevision = fixture.player.seekRevision;
      await _tapLyricsControl(tester, 'lyrics-seek-1');
      expect(fixture.backend.seekPositions.last, const Duration(seconds: 10));
      expect(fixture.player.position.value, const Duration(seconds: 10));
      expect(fixture.player.isPlaying.value, isFalse);
      expect(fixture.backend.playCalls, playCalls);
      expect(fixture.player.seekRevision, greaterThan(seekRevision));
      await fixture.player.togglePlayback();
      await tester.pumpAndSettle();
      final thirdLine = find.text('第三句');
      await tester.ensureVisible(thirdLine);
      Focus.of(tester.element(thirdLine)).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(fixture.backend.seekPositions.last, const Duration(seconds: 20));
      expect(fixture.player.isPlaying.value, isTrue);
      expect(await tester.runAsync(fixture.lyricFile.readAsString), source);
    });
  });

  testWidgets('offset display and seeking share LRC offset plus user timing', (
    tester,
  ) async {
    await _withLyrics(
      tester,
      '[offset:1000]\n[00:00]开头\n[00:10]第二句\n[00:20]第三句',
      (fixture) async {
        await _waitForLyrics(tester);
        fixture.backend.emitPosition(const Duration(milliseconds: 9000));
        await tester.pumpAndSettle();
        expect(_selectedLine(tester, 1), isTrue);
        await _tapLyricsControl(tester, 'lyrics-later');
        expect(find.text('歌词延后 0.5 秒'), findsOneWidget);
        expect(_selectedLine(tester, 0), isTrue);
        await _tapLyricsControl(tester, 'lyrics-seek-1');
        expect(
          fixture.backend.seekPositions.last,
          const Duration(milliseconds: 9500),
        );
        expect(_selectedLine(tester, 1), isTrue);
        await _tapLyricsControl(tester, 'lyrics-reset-offset');
        expect(find.text('歌词同步：原始时间'), findsOneWidget);
        await _tapLyricsControl(tester, 'lyrics-earlier');
        await _tapLyricsControl(tester, 'lyrics-seek-1');
        expect(
          fixture.backend.seekPositions.last,
          const Duration(milliseconds: 8500),
        );
        expect(_selectedLine(tester, 1), isTrue);
        expect(fixture.controller.lyricsOffsetMilliseconds, -500);
      },
    );
  });

  testWidgets(
    'timing is bounded, per song and survives page changes only in memory',
    (tester) async {
      await _withLyrics(tester, '[00:00]开头\n[00:10]第二句', (fixture) async {
        await _waitForLyrics(tester);
        final original = fixture.song;
        fixture.controller.setLyricsOffset(99999, songId: original.id);
        await tester.pumpAndSettle();
        expect(fixture.controller.lyricsOffsetMilliseconds, 30000);
        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('lyrics-later')))
              .onPressed,
          isNull,
        );
        await fixture.controller.seekToLyricsLine(
          const Duration(minutes: 10),
          songId: original.id,
          selectionRevision: fixture.controller.selectionRevision,
        );
        expect(
          fixture.backend.seekPositions.last,
          fixture.player.duration.value,
        );
        fixture.controller.setLyricsOffset(-99999, songId: original.id);
        await fixture.controller.seekToLyricsLine(
          const Duration(seconds: 10),
          songId: original.id,
          selectionRevision: fixture.controller.selectionRevision,
        );
        expect(fixture.backend.seekPositions.last, Duration.zero);
        fixture.controller.setLyricsOffset(500, songId: original.id);
        final other = Song(
          uri: File('${fixture.directory.path}/other.mp3').uri,
          fileName: 'other.mp3',
        );
        await tester.runAsync(() async {
          await fixture.player.playQueue([other]);
          await tester.pump();
        });
        expect(fixture.controller.lyricsOffsetMilliseconds, 0);
        fixture.controller.setLyricsOffset(1500, songId: other.id);
        await tester.runAsync(() async {
          await fixture.player.playQueue([original]);
          await tester.pump();
        });
        await _waitForLyrics(tester);
        expect(fixture.controller.lyricsOffsetMilliseconds, 500);
        await _tapLyricsControl(tester, 'nav-0');
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('nav-1')));
          await tester.pump();
        });
        await _waitForLyrics(tester);
        expect(find.text('歌词延后 0.5 秒'), findsOneWidget);
      });
    },
  );

  testWidgets(
    'exit and stale lyric actions cannot seek and canceled exit recovers',
    (tester) async {
      await _withLyrics(tester, '[00:00]开头\n[00:10]第二句', (fixture) async {
        await _waitForLyrics(tester);
        final oldAction = tester
            .widget<InkWell>(find.byKey(const Key('lyrics-seek-1')))
            .onTap!;
        final oldRevision = fixture.controller.selectionRevision;
        final initialSeeks = fixture.backend.seekPositions.length;
        fixture.controller.beginExit();
        await tester.pumpAndSettle();
        expect(
          tester.widget<InkWell>(find.byKey(const Key('lyrics-seek-1'))).onTap,
          isNull,
        );
        oldAction();
        fixture.controller.setLyricsOffset(500, songId: fixture.song.id);
        await tester.pumpAndSettle();
        expect(fixture.backend.seekPositions.length, initialSeeks);
        expect(fixture.controller.lyricsOffsetMilliseconds, 0);
        fixture.controller.cancelExit();
        await tester.pumpAndSettle();
        expect(
          tester.widget<InkWell>(find.byKey(const Key('lyrics-seek-1'))).onTap,
          isNotNull,
        );
        await _tapLyricsControl(tester, 'lyrics-seek-1');
        expect(fixture.backend.seekPositions.length, initialSeeks + 1);
        await fixture.player.playQueue([fixture.song]);
        await fixture.controller.seekToLyricsLine(
          const Duration(seconds: 20),
          songId: fixture.song.id,
          selectionRevision: oldRevision,
        );
        expect(fixture.backend.seekPositions.length, initialSeeks + 1);
      });
    },
  );

  testWidgets('unknown duration disables lyric seeking', (tester) async {
    await _withLyrics(tester, '[00:00]开头\n[00:10]第二句', (fixture) async {
      await _waitForLyrics(tester);
      fixture.backend.emitDuration(Duration.zero);
      await tester.pumpAndSettle();
      expect(
        tester.widget<InkWell>(find.byKey(const Key('lyrics-seek-1'))).onTap,
        isNull,
      );
      expect(fixture.controller.canSeekLyrics, isFalse);
    });
  });

  testWidgets('timed lyric controls wrap at compact width and large text', (
    tester,
  ) async {
    await _withLyrics(
      tester,
      '[00:00]第一句歌词\n[00:10]第二句歌词',
      (fixture) async {
        await _waitForLyrics(tester);
        await _tapLyricsControl(tester, 'lyrics-later');
        expect(find.text('歌词延后 0.5 秒'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      size: const Size(800, 600),
      textScale: 2,
    );
  });
}

bool _selectedLine(WidgetTester tester, int index) => tester
    .widget<Semantics>(find.byKey(Key('lyrics-line-$index')))
    .properties
    .selected!;

Future<void> _tapLyricsControl(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
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
