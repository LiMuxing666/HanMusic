import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/app_settings.dart';
import 'package:han_music/app/data/models/library_sort.dart';
import 'package:han_music/app/data/models/playlist.dart';
import 'package:han_music/app/data/models/play_history_entry.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/services/app_persistence_service.dart';
import 'package:han_music/app/services/app_settings_service.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/playlist_service.dart';
import 'package:han_music/app/services/play_history_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibraryService library;
  late PlayerService player;
  late FakeAudioBackend backend;
  late _MemoryStore store;
  late AppPersistenceService persistence;
  late List<String> errors;
  final song = Song(
    uri: Uri.file('D:/test-song.flac', windows: true),
    fileName: 'test-song.flac',
  );

  setUp(() {
    library = LibraryService(
      repository: LocalLibraryRepository(
        artworkDirectory: Directory(
          '${Directory.systemTemp.path}/unused-cover',
        ),
      ),
    );
    backend = FakeAudioBackend();
    player = PlayerService(backend);
    store = _MemoryStore();
    errors = [];
    persistence = AppPersistenceService(
      store: store,
      library: library,
      player: player,
      onError: errors.add,
    )..start();
  });
  tearDown(() async {
    store.gate?.complete();
    store.gate = null;
    await persistence.close();
    library.onClose();
    await player.shutdown();
  });

  test('coalesces a burst of library edits and syncs queue metadata', () async {
    await player.restoreQueue([song]);
    for (var i = 0; i < 100; i++) {
      library.replaceAll([song.copyWith(trackTitle: 'Title $i')]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 850));
    expect(store.saved, hasLength(1));
    expect(store.saved.single.songs.single.title, 'Title 99');
    expect(store.saved.single.queue.single.title, 'Title 99');
  });

  test(
    'closing awaits final persistence and keeps the latest paused position',
    () async {
      library.replaceAll([song]);
      await player.open(song);
      backend.emitPosition(const Duration(seconds: 32));
      await player.pause();
      store.gate = Completer<void>();
      var closed = false;
      final closing = persistence.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(store.saved.single.position, const Duration(seconds: 32));
      store.gate!.complete();
      store.gate = null;
      await closing;
      expect(closed, isTrue);
      player.volume.value = .2;
      await Future<void>.delayed(Duration.zero);
      expect(store.saved, hasLength(1));
    },
  );

  test(
    'save failure is reported without stopping playback and retry succeeds',
    () async {
      await player.open(song);
      store.failure = true;
      expect(await persistence.flush(), isFalse);
      expect(errors.single, contains('保存失败'));
      expect(player.isPlaying.value, isTrue);
      store.failure = false;
      expect(await persistence.flush(), isTrue);
      expect(store.saved.last.currentId, song.id);
      expect(player.isPlaying.value, isTrue);
    },
  );

  test(
    'close without flush stops listeners without repeating a final save',
    () async {
      await player.open(song);
      expect(await persistence.flush(), isTrue);
      final saves = store.saved.length;
      await persistence.close(flush: false);
      player.volume.value = .2;
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(store.saved, hasLength(saves));
    },
  );

  test(
    'playlist edits schedule persistence and library refresh updates snapshots',
    () async {
      await persistence.close(flush: false);
      final playlists = PlaylistService();
      addTearDown(playlists.onClose);
      persistence = AppPersistenceService(
        store: store,
        library: library,
        player: player,
        playlists: playlists,
        onError: errors.add,
      )..start();
      final custom = playlists.create('收藏测试');
      playlists.addSongs(custom.id, [song]);
      playlists.toggleFavorite(song);
      await Future<void>.delayed(const Duration(milliseconds: 850));
      expect(store.saved, hasLength(1));
      expect(store.saved.single.playlists, hasLength(2));
      final before = playlists.findById(custom.id)!;
      library.replaceAll([song.copyWith(trackTitle: '更新曲名', isMissing: true)]);
      expect(await persistence.flush(), isTrue);
      final saved = store.saved.last.playlists.firstWhere(
        (p) => p.id == custom.id,
      );
      expect(saved.songs.single.title, '更新曲名');
      expect(saved.songs.single.isMissing, isTrue);
      expect(saved.updatedAt, before.updatedAt);
      library.replaceAll([]);
      expect(await persistence.flush(), isTrue);
      expect(
        store.saved.last.playlists.firstWhere((p) => p.id == custom.id).songs,
        hasLength(1),
      );
    },
  );

  test(
    'legacy persistence without playlist service preserves loaded schema 3 playlists',
    () async {
      final date = DateTime.utc(2026, 10, 29);
      final playlist = Playlist(
        id: 'keep',
        name: '保留',
        songs: [song],
        createdAt: date,
        updatedAt: date,
      );
      final entry = PlayHistoryEntry(
        song: song,
        lastPlayedAt: date,
        playCount: 2,
      );
      store.loaded = AppSnapshot(playlists: [playlist], history: [entry]);
      player.volume.value = 0.4;
      expect(await persistence.flush(), isTrue);
      expect(store.saved.last.playlists.single.toJson(), playlist.toJson());
      expect(store.saved.last.history.single.toJson(), entry.toJson());
      player.volume.value = 0.5;
      expect(await persistence.flush(), isTrue);
      expect(store.saved.last.playlists.single.toJson(), playlist.toJson());
      expect(store.loadCalls, 1);
    },
  );

  test(
    'history edits and clearing are persisted with fresh library metadata',
    () async {
      await persistence.close(flush: false);
      final history = PlayHistoryService(player);
      addTearDown(history.onClose);
      persistence = AppPersistenceService(
        store: store,
        library: library,
        player: player,
        history: history,
        onError: errors.add,
      )..start();
      final date = DateTime.utc(2026, 10, 29);
      history.restore([
        PlayHistoryEntry(song: song, lastPlayedAt: date, playCount: 2),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 850));
      expect(store.saved.last.history.single.playCount, 2);
      library.replaceAll([song.copyWith(trackTitle: '新标题')]);
      expect(await persistence.flush(), isTrue);
      expect(store.saved.last.history.single.song.title, '新标题');
      expect(store.saved.last.history.single.lastPlayedAt, date);
      history.clear();
      expect(await persistence.flush(), isTrue);
      expect(store.saved.last.history, isEmpty);
    },
  );

  test(
    'settings alone schedule a save and closing stops their listener',
    () async {
      await persistence.close(flush: false);
      final settings = AppSettingsService();
      final playlists = PlaylistService();
      final history = PlayHistoryService(player);
      addTearDown(settings.onClose);
      addTearDown(playlists.onClose);
      addTearDown(history.onClose);
      persistence = AppPersistenceService(
        store: store,
        library: library,
        player: player,
        playlists: playlists,
        history: history,
        settings: settings,
        onError: errors.add,
      )..start();
      settings.setThemeMode(ThemeMode.system);
      settings.setLibrarySort(LibrarySort.title);
      settings.setLibrarySortDescending(true);
      await Future<void>.delayed(const Duration(milliseconds: 850));
      expect(store.saved, hasLength(1));
      expect(
        store.saved.single.settings,
        const AppSettings(
          themeMode: ThemeMode.system,
          librarySort: LibrarySort.title,
          librarySortDescending: true,
        ),
      );
      expect(store.loadCalls, 0);
      await persistence.close(flush: false);
      settings.restore(const AppSettings());
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(store.saved, hasLength(1));
    },
  );

  test(
    'missing settings service preserves saved preferences across checkpoints',
    () async {
      await persistence.close(flush: false);
      const savedSettings = AppSettings(
        themeMode: ThemeMode.dark,
        librarySort: LibrarySort.artist,
        librarySortDescending: true,
      );
      store.loaded = const AppSnapshot(settings: savedSettings);
      final playlists = PlaylistService();
      final history = PlayHistoryService(player);
      addTearDown(playlists.onClose);
      addTearDown(history.onClose);
      persistence = AppPersistenceService(
        store: store,
        library: library,
        player: player,
        playlists: playlists,
        history: history,
        onError: errors.add,
      )..start();
      player.volume.value = 0.4;
      expect(await persistence.flush(), isTrue);
      expect(store.saved.last.settings, savedSettings);
      player.volume.value = 0.5;
      expect(await persistence.flush(), isTrue);
      expect(store.saved.last.settings, savedSettings);
      expect(store.loadCalls, 1);
      expect(errors, isEmpty);
    },
  );
}

class _MemoryStore implements AppStateStore {
  final saved = <AppSnapshot>[];
  bool failure = false;
  Completer<void>? gate;
  AppSnapshot loaded = const AppSnapshot();
  int loadCalls = 0;
  @override
  String? get warning => null;
  @override
  Future<AppSnapshot> load() async {
    loadCalls++;
    return loaded;
  }

  @override
  Future<void> save(AppSnapshot snapshot) async {
    if (failure) throw const FileSystemException('Synthetic disk failure');
    saved.add(snapshot);
    if (gate case final pending?) await pending.future;
  }
}
