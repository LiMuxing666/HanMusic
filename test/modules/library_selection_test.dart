import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/library_sort.dart';
import 'package:han_music/app/data/models/play_history_entry.dart';
import 'package:han_music/app/data/models/playlist.dart';
import 'package:han_music/app/data/models/queue_add_result.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/play_history_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAudioBackend backend;
  late PlayerService player;
  late TimerService timer;
  late LibraryService library;
  late PlayHistoryService history;
  late PlayerController controller;
  final a = _song('alpha');
  final b = _song('bravo');
  final c = _song('charlie');
  final missing = _song('missing', missing: true);

  setUp(() {
    backend = FakeAudioBackend();
    player = PlayerService(backend);
    timer = TimerService(onExpired: player.pause);
    library = LibraryService(
      repository: LocalLibraryRepository(
        artworkDirectory: Directory.systemTemp,
      ),
    );
    library.replaceAll([a, b, c, missing]);
    history = PlayHistoryService(player);
    controller = PlayerController(
      player: player,
      timer: timer,
      picker: _NoPicker(),
      library: library,
      history: history,
    )..onStart();
  });

  tearDown(() async {
    controller.onDelete();
    history.onClose();
    library.onClose();
    timer.onClose();
    await player.shutdown();
  });

  test(
    'toggle, shift range and additive range select identities without playing',
    () {
      controller.selectLibrarySong(a);
      controller.selectLibrarySong(c, toggle: false, range: true);
      expect(controller.selectedLibrarySongs, [a, b, c]);
      controller.selectLibrarySong(b);
      expect(controller.selectedLibrarySongs, [a, c]);
      controller.selectLibrarySong(missing, range: true);
      expect(controller.selectedLibrarySongs, [a, b, c, missing]);
      expect(controller.librarySelectionMode.value, isTrue);
      expect(backend.loadedUris, isEmpty);
      expect(player.queue, isEmpty);
      controller.exitLibrarySelection();
      expect(controller.selectedLibraryIds, isEmpty);
      expect(controller.librarySelectionMode.value, isFalse);
    },
  );

  test(
    'filter prunes hidden selection, sort resets the range anchor, removal prunes IDs',
    () {
      controller.selectAllVisibleLibrarySongs();
      controller.setSearchQuery('alpha');
      expect(controller.selectedLibrarySongs, [a]);
      controller.setSearchQuery('');
      expect(controller.selectedLibrarySongs, [a]);
      controller.setLibrarySort(LibrarySort.title);
      controller.toggleLibrarySortDirection();
      controller.selectLibrarySong(b, toggle: false, range: true);
      expect(controller.selectedLibrarySongs, [b]);
      controller.selectAllVisibleLibrarySongs();
      expect(controller.selectedLibrarySongs, [missing, c, b, a]);
      library.remove(b.id);
      expect(controller.selectedLibraryIds.contains(b.id), isFalse);
      expect(backend.calls, isEmpty);
    },
  );

  test(
    'batch queue and playlist deduplicate, keep visible order and count missing',
    () async {
      await player.restoreQueue([c]);
      controller.toggleLibrarySortDirection();
      controller.selectAllVisibleLibrarySongs();
      expect(controller.enqueueSelectedLibrarySongs(), (
        added: 2,
        existing: 1,
        unavailable: 1,
      ));
      expect(player.queue, [c, b, a]);
      expect(controller.enqueueSelectedLibrarySongs(), (
        added: 0,
        existing: 3,
        unavailable: 1,
      ));
      expect(
        controller.addSelectedLibrarySongsToPlaylist(Playlist.favoritesId),
        (added: 3, existing: 0, unavailable: 1),
      );
      expect(
        controller
            .playlistSongs(Playlist.favoritesId)
            .map((song) => song.toJson()),
        [c, b, a].map((song) => song.toJson()),
      );
      expect(
        controller.addSelectedLibrarySongsToPlaylist(Playlist.favoritesId),
        (added: 0, existing: 3, unavailable: 1),
      );
      expect(backend.playCalls, 0);
    },
  );

  test(
    'bulk removal keeps source files, playlists and history and uses captured identities',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hanmusic-selection-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/保留 & (音乐).mp3',
      ).writeAsString('audio');
      final local = Song(uri: file.uri, fileName: '保留 & (音乐).mp3');
      library.replaceAll([local, a]);
      controller.addSongsToPlaylist(Playlist.favoritesId, [local]);
      history.restore([_entry(local)]);
      await player.restoreQueue([local, a]);
      controller.selectLibrarySong(local);
      final captured = controller.selectedLibraryIds.toList();
      controller.selectLibrarySong(a);
      expect(await controller.removeSelectedLibrarySongs(songIds: captured), 1);
      expect(library.songs, [a]);
      expect(player.queue, [a]);
      expect(controller.selectedLibrarySongs, [a]);
      expect(
        controller.playlistSongs(Playlist.favoritesId).single.id,
        local.id,
      );
      expect(history.entries.single.song.id, local.id);
      expect(await file.exists(), isTrue);
    },
  );

  test(
    'loading, importing, exit and closed controllers reject selection mutations',
    () async {
      controller.selectLibrarySong(a);
      final gate = backend.loadCompleter = Completer<Duration?>();
      final loading = player.playQueue([b]);
      await Future<void>.delayed(Duration.zero);
      expect(player.isLoading.value, isTrue);
      controller.selectAllVisibleLibrarySongs();
      expect(controller.enqueueSelectedLibrarySongs().added, 0);
      expect(await controller.removeSelectedLibrarySongs(), 0);
      expect(controller.selectedLibrarySongs, [a]);
      gate.complete(const Duration(minutes: 1));
      await loading;
      library.isImporting.value = true;
      controller.selectLibrarySong(c);
      expect(
        controller
            .addSelectedLibrarySongsToPlaylist(Playlist.favoritesId)
            .added,
        0,
      );
      library.isImporting.value = false;
      final generation = controller.commandGeneration;
      controller.beginExit();
      controller.selectLibrarySong(c);
      await controller.playLibrarySong(a);
      expect(controller.enqueueSelectedLibrarySongs().added, 0);
      expect(await controller.removeSelectedLibrarySongs(), 0);
      controller.cancelExit();
      expect(controller.commandGeneration, isNot(generation));
      expect(controller.selectedLibrarySongs, [a]);
      controller.onDelete();
      controller.selectAllVisibleLibrarySongs();
      expect(controller.selectedLibrarySongs, [a]);
      expect(library.songs.length, 4);
    },
  );

  test(
    'history playback uses latest metadata and a single-song queue; history ownership stays external',
    () async {
      history.restore([_entry(a.copyWith(isMissing: true)), _entry(missing)]);
      expect(
        controller.isHistorySongAvailable(history.entries.first.song),
        isTrue,
      );
      await player.restoreQueue([b, c]);
      await controller.playHistorySong(history.entries.first.song);
      expect(player.queue, [a]);
      expect(player.currentSong.value, same(a));
      expect(
        controller.enqueueHistorySong(missing),
        QueueAddResult.unavailable,
      );
      controller.beginExit();
      controller.clearHistory();
      controller.removeHistorySong(a.id);
      await controller.playHistorySong(b);
      expect(history.entries.length, 2);
      expect(player.currentSong.value, a);
      controller.cancelExit();
      controller.removeHistorySong(a.id);
      expect(history.entries.single.song.id, missing.id);
      controller.onDelete();
      history.clear();
      expect(history.entries, isEmpty);
    },
  );

  test(
    'playlist transfer validates entire batch and preserves unknown local identities only when requested',
    () {
      final unknown = _song('outside-index', missing: true);
      expect(controller.addSongsToPlaylist(Playlist.favoritesId, [unknown]), (
        added: 0,
        existing: 0,
      ));
      expect(
        controller.addSongsToPlaylist(Playlist.favoritesId, [
          unknown,
        ], preserveUnknown: true),
        (added: 1, existing: 0),
      );
      final invalid = Song(
        uri: Uri.parse('https://example.com/transient.mp3'),
        fileName: 'invalid.mp3',
      );
      expect(
        () => controller.addSongsToPlaylist(Playlist.favoritesId, [
          a,
          invalid,
        ], preserveUnknown: true),
        throwsFormatException,
      );
      expect(
        controller
            .playlistSongs(Playlist.favoritesId)
            .map((song) => song.toJson()),
        [unknown.toJson()],
      );
    },
  );
}

PlayHistoryEntry _entry(Song song) => PlayHistoryEntry(
  song: song,
  lastPlayedAt: DateTime.utc(2026, 10, 29),
  playCount: 1,
);

Song _song(String name, {bool missing = false}) => Song(
  uri: Uri.file('D:/music/$name.mp3', windows: true),
  fileName: '$name.mp3',
  isMissing: missing,
);

class _NoPicker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}
