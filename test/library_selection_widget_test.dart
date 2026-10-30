import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/playlist.dart';
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
    'explicit checkbox selection has checked semantics and Esc restores ordinary playback',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await _withLibrary(tester, (fixture) async {
          await _tap(tester, find.byKey(const Key('library-selection-mode')));
          final checkbox = find.byKey(
            ValueKey('library-select-${fixture.songs.first.id}'),
          );
          await _tap(tester, checkbox);
          expect(find.text('已选 1 首'), findsOneWidget);
          expect(
            tester.getSemantics(checkbox).flagsCollection.isChecked,
            ui.CheckedState.isTrue,
          );
          expect(fixture.backend.playCalls, 0);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(fixture.controller.librarySelectionMode.value, isFalse);
          expect(checkbox, findsNothing);
          await _tap(tester, _row(fixture.songs.first));
          expect(fixture.player.currentSong.value?.id, fixture.songs.first.id);
          expect(fixture.backend.playCalls, 1);
        });
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'Ctrl toggles and Shift ranges follow displayed rows without playing, including missing songs',
    (tester) async {
      await _withLibrary(tester, (fixture) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await _tap(tester, _row(fixture.songs[0]));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await _tap(tester, _row(fixture.songs[2]));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        expect(fixture.controller.selectedLibrarySongs, fixture.songs.take(3));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await _tap(tester, _row(fixture.songs[1]));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        expect(fixture.controller.selectedLibrarySongs, [
          fixture.songs[0],
          fixture.songs[2],
        ]);
        fixture.controller.exitLibrarySelection();
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await _tap(tester, _row(fixture.songs.last));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        expect(fixture.controller.selectedLibrarySongs, [fixture.songs.last]);
        expect(fixture.backend.loadedUris, isEmpty);
      });
    },
  );

  testWidgets(
    'Ctrl+A selects visible songs but leaves text editing and modal dialogs alone',
    (tester) async {
      await _withLibrary(tester, (fixture) async {
        await _chord(tester, LogicalKeyboardKey.keyA);
        expect(fixture.controller.selectedLibrarySongs.length, 4);
        final search = find.byKey(const ValueKey('library-search'));
        await tester.enterText(search, 'alpha');
        await tester.pumpAndSettle();
        expect(fixture.controller.selectedLibrarySongs, [fixture.songs.first]);
        await _chord(tester, LogicalKeyboardKey.keyA);
        final editable = tester.widget<EditableText>(
          find.descendant(of: search, matching: find.byType(EditableText)),
        );
        expect(
          editable.controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: 5),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(fixture.controller.librarySelectionMode.value, isTrue);
        await _tap(tester, find.byKey(const Key('library-remove-selected')));
        expect(find.byType(AlertDialog), findsOneWidget);
        await _chord(tester, LogicalKeyboardKey.keyA);
        expect(fixture.controller.selectedLibrarySongs, [fixture.songs.first]);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(fixture.controller.librarySelectionMode.value, isTrue);
        expect(fixture.backend.loadedUris, isEmpty);
      });
    },
  );

  testWidgets(
    'batch actions report missing files and index removal requires an explicit confirmation',
    (tester) async {
      await _withLibrary(tester, (fixture) async {
        await _chord(tester, LogicalKeyboardKey.keyA);
        await _tap(tester, find.byKey(const Key('library-enqueue-selected')));
        expect(fixture.player.queue.length, 3);
        expect(find.textContaining('跳过缺失或不可用 1 首'), findsOneWidget);
        await _tap(tester, find.byKey(const Key('library-playlist-selected')));
        await _tap(
          tester,
          find.byKey(const ValueKey('batch-playlist-${Playlist.favoritesId}')),
        );
        expect(
          fixture.controller.playlistSongs(Playlist.favoritesId).length,
          3,
        );
        expect(fixture.backend.playCalls, 0);
        fixture.controller.exitLibrarySelection();
        fixture.controller.selectLibrarySong(fixture.songs.first);
        await tester.pumpAndSettle();
        await _tap(tester, find.byKey(const Key('library-remove-selected')));
        expect(find.textContaining('不会删除源文件'), findsOneWidget);
        await _tap(tester, find.text('取消'));
        expect(fixture.library.songs.length, 4);
        await _tap(tester, find.byKey(const Key('library-remove-selected')));
        // A changed selection while the confirmation is open cannot expand its scope.
        fixture.controller.selectLibrarySong(fixture.songs[1]);
        await _tap(
          tester,
          find.byKey(const Key('library-remove-selected-confirm')),
        );
        expect(
          fixture.library.songs.map((song) => song.id),
          fixture.songs.skip(1).map((song) => song.id),
        );
        expect(
          fixture.controller.playlistSongs(Playlist.favoritesId).length,
          3,
        );
        expect(find.text('已从曲库移除 1 首，源文件已保留。'), findsOneWidget);
      });
    },
  );

  testWidgets(
    'exit cancellation invalidates old bulk dialogs and importing disables selection commands',
    (tester) async {
      await _withLibrary(tester, (fixture) async {
        fixture.controller.selectLibrarySong(fixture.songs.first);
        await tester.pumpAndSettle();
        await _tap(tester, find.byKey(const Key('library-remove-selected')));
        fixture.controller.beginExit();
        fixture.controller.cancelExit();
        await _tap(
          tester,
          find.byKey(const Key('library-remove-selected-confirm')),
        );
        expect(fixture.library.songs.length, 4);
        await _tap(tester, find.byKey(const Key('library-playlist-selected')));
        fixture.controller.beginExit();
        fixture.controller.cancelExit();
        await _tap(
          tester,
          find.byKey(const ValueKey('batch-playlist-${Playlist.favoritesId}')),
        );
        expect(fixture.controller.playlistSongs(Playlist.favoritesId), isEmpty);
        fixture.library.isImporting.value = true;
        await tester.pump();
        expect(
          tester
              .widget<TextButton>(
                find.byKey(const Key('library-enqueue-selected')),
              )
              .onPressed,
          isNull,
        );
        // Import intentionally keeps its indeterminate progress animation active.
        await _chord(tester, LogicalKeyboardKey.keyA, settle: false);
        expect(fixture.controller.selectedLibrarySongs.length, 1);
        fixture.library.isImporting.value = false;
        fixture.controller.beginExit();
        await _chord(tester, LogicalKeyboardKey.keyA);
        expect(fixture.controller.selectedLibrarySongs.length, 1);
        expect(fixture.backend.loadedUris, isEmpty);
      });
    },
  );
}

Finder _row(Song song) => find.byKey(ValueKey('library-song-${song.id}'));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool settle = true,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _withLibrary(
  WidgetTester tester,
  Future<void> Function(_Fixture) run,
) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  final fixture = _Fixture();
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: HanMusicTheme.light,
        home: PlayerPage(controller: fixture.controller),
      ),
    );
    await tester.pumpAndSettle();
    await run(fixture);
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.controller.onDelete();
    fixture.library.onClose();
    fixture.timer.onClose();
    await tester.runAsync(fixture.player.shutdown);
    await tester.binding.setSurfaceSize(null);
  }
}

class _Fixture {
  _Fixture() {
    player = PlayerService(backend);
    timer = TimerService(onExpired: player.pause);
    library = LibraryService(
      repository: LocalLibraryRepository(
        artworkDirectory: Directory.systemTemp,
      ),
    );
    library.replaceAll(songs);
    controller = PlayerController(
      player: player,
      timer: timer,
      picker: _NoPicker(),
      library: library,
    )..onStart();
  }
  final backend = FakeAudioBackend();
  final songs = [
    for (final name in ['alpha', 'bravo', 'charlie', 'missing'])
      Song(
        uri: Uri.file('D:/music/$name.mp3', windows: true),
        fileName: '$name.mp3',
        isMissing: name == 'missing',
      ),
  ];
  late final PlayerService player;
  late final TimerService timer;
  late final LibraryService library;
  late final PlayerController controller;
}

class _NoPicker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}
