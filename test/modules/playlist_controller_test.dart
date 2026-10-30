import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/play_mode.dart';
import 'package:han_music/app/data/models/playlist.dart';
import 'package:han_music/app/data/models/queue_add_result.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/online_music_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/playlist_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import '../support/fake_audio_backend.dart';
import '../support/fake_online_music.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAudioBackend backend;
  late PlayerService player;
  late TimerService timer;
  late LibraryService library;
  late PlaylistService playlists;
  late OnlineMusicService online;
  late PlayerController controller;
  final a = _local('a');
  final b = _local('b');
  final missing = _local('missing').copyWith(isMissing: true);
  final remote = Song.online(sourceId: 'demo', trackId: 'track', title: '在线歌曲');
  final removedRemote = Song.online(
    sourceId: 'removed',
    trackId: 'track',
    title: '已移除音乐源',
  );

  setUp(() async {
    online = OnlineMusicService(
      repository: FakeOnlineMusicRepository(),
      store: MemoryOnlineSourceStore(
        sources: [onlineTestSource()],
        selected: 'demo',
      ),
    );
    await online.initialize();
    backend = FakeAudioBackend();
    player = PlayerService(backend, resolver: online.resolveForPlayback);
    timer = TimerService(onExpired: player.pause);
    library = LibraryService(
      repository: LocalLibraryRepository(
        artworkDirectory: Directory.systemTemp,
      ),
    )..replaceAll([a, b, missing]);
    playlists = PlaylistService();
    controller = PlayerController(
      player: player,
      timer: timer,
      picker: _NoSongPicker(),
      library: library,
      playlists: playlists,
      online: online,
    )..onStart();
  });

  tearDown(() async {
    controller.onDelete();
    playlists.onClose();
    library.onClose();
    timer.onClose();
    await player.shutdown();
    await online.close();
  });

  test(
    'local and online favorites keep restorable metadata without changing playback',
    () async {
      await player.playQueue([b]);
      await player.seek(const Duration(seconds: 26));
      final calls = backend.calls.toList();
      expect(controller.toggleFavorite(a), isTrue);
      expect(controller.toggleFavorite(remote), isTrue);
      expect(controller.isFavorite(a), isTrue);
      expect(controller.isFavorite(remote), isTrue);
      final favorites = playlists.findById(Playlist.favoritesId)!;
      expect(favorites.songs.map((song) => song.id), [a.id, remote.id]);
      expect(favorites.songs.last.uri.scheme, 'hanmusic');
      expect(controller.toggleFavorite(a), isFalse);
      expect(controller.isFavorite(a), isFalse);
      expect(controller.isFavorite(remote), isTrue);
      expect(player.currentSong.value?.id, b.id);
      expect(player.position.value, const Duration(seconds: 26));
      expect(player.isPlaying.value, isTrue);
      expect(backend.calls, calls);
    },
  );

  for (final mode in PlayMode.values) {
    test(
      'playlist playback skips unavailable songs and preserves ${mode.name}',
      () async {
        final playlist = controller.createPlaylist('混合歌单');
        controller.addSongsToPlaylist(playlist.id, [
          missing,
          a,
          removedRemote,
          remote,
          b,
        ]);
        player.playMode.value = mode;

        await controller.playPlaylist(playlist.id);

        expect(player.queue.map((song) => song.id), [a.id, remote.id, b.id]);
        expect(player.currentSong.value?.id, a.id);
        expect(player.isPlaying.value, isTrue);
        expect(player.playMode.value, mode);
        expect(backend.loadedUris, [a.uri]);
        expect(controller.playlistSongs(playlist.id), hasLength(5));
      },
    );

    test(
      'playlist enqueue preserves playback and ${mode.name} while counting unavailable songs',
      () async {
        final playlist = controller.createPlaylist('追加歌单');
        controller.addSongsToPlaylist(playlist.id, [
          missing,
          a,
          removedRemote,
          remote,
          b,
        ]);
        await player.playQueue([b]);
        await player.seek(const Duration(seconds: 19));
        player.playMode.value = mode;
        final revision = player.selectionRevision;
        final calls = backend.calls.toList();

        expect(controller.enqueuePlaylist(playlist.id), (
          added: 2,
          existing: 1,
          unavailable: 2,
        ));
        expect(controller.enqueuePlaylist(playlist.id), (
          added: 0,
          existing: 3,
          unavailable: 2,
        ));
        expect(player.queue.map((song) => song.id), [b.id, a.id, remote.id]);
        expect(player.currentSong.value?.id, b.id);
        expect(player.position.value, const Duration(seconds: 19));
        expect(player.isPlaying.value, isTrue);
        expect(player.playMode.value, mode);
        expect(player.selectionRevision, revision);
        expect(backend.calls, calls);
      },
    );
  }

  test(
    'selected online playlist song resolves a fresh URL and removed source becomes unavailable',
    () async {
      final playlist = controller.createPlaylist('在线');
      controller.addSongsToPlaylist(playlist.id, [a, remote]);
      await controller.playPlaylist(playlist.id, startSongId: remote.id);
      expect(player.currentSong.value?.id, remote.id);
      expect(
        backend.loadedUris.last,
        Uri.parse('https://media.example.test/audio.mp3'),
      );
      await online.removeSource('demo');
      expect(controller.isSongAvailable(remote), isFalse);
      final calls = backend.calls.toList();
      await controller.playPlaylist(playlist.id, startSongId: remote.id);
      expect(backend.calls, calls);
      expect(controller.addToQueue(remote), QueueAddResult.unavailable);
      expect(controller.playNext(remote), QueueAddResult.unavailable);
      await player.clearQueue();
      expect(controller.enqueuePlaylist(playlist.id), (
        added: 1,
        existing: 0,
        unavailable: 1,
      ));
      expect(player.queue.map((song) => song.id), [a.id]);
      expect(controller.playlistSongs(playlist.id).map((song) => song.id), [
        a.id,
        remote.id,
      ]);
    },
  );

  test(
    'a local playlist snapshot outside the library can enqueue and play next',
    () async {
      final playlist = controller.createPlaylist('保留曲目');
      controller.addSongsToPlaylist(playlist.id, [b]);
      library.remove(b.id);
      await player.playQueue([a]);
      player.playMode.value = PlayMode.shuffle;
      expect(controller.addToQueue(b), QueueAddResult.added);
      expect(controller.playNext(b), QueueAddResult.added);
      expect(player.currentSong.value?.id, a.id);
      await player.next();
      expect(player.currentSong.value?.id, b.id);
      expect(player.playMode.value, PlayMode.shuffle);
      expect(library.songs.any((song) => song.id == b.id), isFalse);
    },
  );

  test(
    'stale local menu references without library, queue or playlist membership are ignored',
    () async {
      library.remove(b.id);
      await player.playQueue([a]);
      final calls = backend.calls.toList();
      expect(controller.addToQueue(b), QueueAddResult.unavailable);
      expect(controller.playNext(b), QueueAddResult.unavailable);
      expect(controller.toggleFavorite(b), isFalse);
      expect(player.queue.map((song) => song.id), [a.id]);
      expect(backend.calls, calls);
    },
  );

  test(
    'deleting a playlist preserves library, queue and current playback',
    () async {
      final playlist = controller.createPlaylist('删除测试');
      controller.addSongsToPlaylist(playlist.id, [a, b]);
      await controller.playPlaylist(playlist.id);
      final calls = backend.calls.toList();
      final revision = player.selectionRevision;
      final libraryIds = library.songs.map((song) => song.id).toList();

      controller.deletePlaylist(playlist.id);

      expect(playlists.findById(playlist.id), isNull);
      expect(library.songs.map((song) => song.id), libraryIds);
      expect(player.queue.map((song) => song.id), [a.id, b.id]);
      expect(player.currentSong.value?.id, a.id);
      expect(player.isPlaying.value, isTrue);
      expect(player.selectionRevision, revision);
      expect(backend.calls, calls);
    },
  );

  test(
    'playlist reads, favorite and queue additions use the latest indexed metadata',
    () async {
      final playlist = controller.createPlaylist('旧快照');
      controller.addSongsToPlaylist(playlist.id, [a, b]);
      final latestA = a.copyWith(trackTitle: '最新曲名', artist: '最新歌手');
      final latestB = b.copyWith(isMissing: true);
      library.replaceAll([latestA, latestB]);

      expect(controller.playlistSongs(playlist.id).first.title, '最新曲名');
      expect(controller.playlistSongs(playlist.id).last.isMissing, isTrue);
      expect(controller.toggleFavorite(a), isTrue);
      expect(
        playlists.findById(Playlist.favoritesId)!.songs.single.artist,
        '最新歌手',
      );
      final fresh = controller.createPlaylist('新副本');
      controller.addSongsToPlaylist(fresh.id, [a]);
      expect(playlists.findById(fresh.id)!.songs.single.title, '最新曲名');
      expect(controller.enqueuePlaylist(playlist.id), (
        added: 1,
        existing: 0,
        unavailable: 1,
      ));
      expect(player.queue.single.title, '最新曲名');
      await controller.playPlaylist(playlist.id);
      expect(player.currentSong.value!.artist, '最新歌手');
      expect(player.queue.single.id, a.id);
    },
  );

  test(
    'play next recovers a stale missing queue snapshot from current library metadata',
    () async {
      final playlist = controller.createPlaylist('恢复文件');
      controller.addSongsToPlaylist(playlist.id, [b]);
      await player.playQueue([a, b.copyWith(isMissing: true)]);
      final recovered = b.copyWith(trackTitle: '已恢复曲目', isMissing: false);
      library.replaceAll([a, recovered]);

      expect(controller.playNext(b), QueueAddResult.added);
      final queued = player.queue.firstWhere((song) => song.id == b.id);
      expect(queued.isMissing, isFalse);
      expect(queued.title, '已恢复曲目');
      expect(player.currentSong.value?.id, a.id);
      await player.next();
      expect(player.currentSong.value?.id, b.id);
      expect(player.currentSong.value?.title, '已恢复曲目');
      expect(backend.loadedUris, [a.uri, b.uri]);
    },
  );

  test(
    'empty, deleted, wholly unavailable and invalid selection playlists leave playback intact',
    () async {
      final empty = controller.createPlaylist('空');
      final unavailable = controller.createPlaylist('不可用');
      controller.addSongsToPlaylist(unavailable.id, [missing, removedRemote]);
      final partial = controller.createPlaylist('部分可用');
      controller.addSongsToPlaylist(partial.id, [a, missing]);
      await player.playQueue([b]);
      final calls = backend.calls.toList();
      for (final id in [empty.id, unavailable.id, 'deleted']) {
        await controller.playPlaylist(id);
        expect(controller.enqueuePlaylist(id), (
          added: 0,
          existing: 0,
          unavailable: id == unavailable.id ? 2 : 0,
        ));
      }
      await controller.playPlaylist(partial.id, startSongId: missing.id);
      expect(player.queue.map((song) => song.id), [b.id]);
      expect(player.currentSong.value?.id, b.id);
      expect(backend.calls, calls);
    },
  );

  test('playlist playback does not interrupt a pending load', () async {
    final playlist = controller.createPlaylist('待播');
    controller.addSongsToPlaylist(playlist.id, [b]);
    final gate = backend.loadCompleter = Completer<Duration?>();
    final opening = player.playQueue([a]);
    await Future<void>.delayed(Duration.zero);
    expect(player.isLoading.value, isTrue);
    final revision = player.selectionRevision;
    await controller.playPlaylist(playlist.id);
    expect(player.queue.map((song) => song.id), [a.id]);
    expect(player.selectionRevision, revision);
    gate.complete(const Duration(minutes: 3));
    await opening;
    expect(backend.loadedUris, [a.uri]);
  });

  for (final closed in [false, true]) {
    test(
      '${closed ? "closed" : "exiting"} controller protects all new playlist mutations',
      () async {
        final playlist = controller.createPlaylist('Protected');
        controller.addSongsToPlaylist(playlist.id, [a, b]);
        controller.toggleFavorite(a);
        await player.playQueue([a]);
        final snapshots = playlists.playlists.map((p) => p.toJson()).toList();
        final calls = backend.calls.toList();
        if (closed) {
          controller.onDelete();
        } else {
          controller.beginExit();
        }

        expect(controller.toggleFavorite(a), isTrue);
        expect(controller.toggleFavorite(b), isFalse);
        expect(
          () => controller.createPlaylist('Forbidden'),
          throwsFormatException,
        );
        expect(
          () => controller.renamePlaylist(playlist.id, 'Forbidden'),
          throwsFormatException,
        );
        controller.deletePlaylist(playlist.id);
        expect(controller.addSongsToPlaylist(playlist.id, [remote]), (
          added: 0,
          existing: 0,
        ));
        controller.removePlaylistSong(playlist.id, a.id);
        controller.reorderPlaylistSongs(playlist.id, 0, 2);
        await controller.playPlaylist(playlist.id);
        expect(controller.enqueuePlaylist(playlist.id), (
          added: 0,
          existing: 0,
          unavailable: 0,
        ));
        expect(controller.addToQueue(b), QueueAddResult.unavailable);
        expect(controller.playNext(b), QueueAddResult.unavailable);
        expect(playlists.playlists.map((p) => p.toJson()).toList(), snapshots);
        expect(player.queue.map((song) => song.id), [a.id]);
        expect(backend.calls, calls);

        controller.cancelExit();
        if (!closed) {
          controller.renamePlaylist(playlist.id, 'Recovered');
          expect(playlists.findById(playlist.id)!.name, 'Recovered');
        } else {
          expect(controller.acceptsPlaybackCommands, isFalse);
        }
      },
    );
  }
}

Song _local(String name) => Song(
  uri: Uri.file('D:/music/$name.mp3', windows: true),
  fileName: '$name.mp3',
);

class _NoSongPicker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}
