import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/playlist.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/services/playlist_service.dart';

void main() {
  late DateTime now;
  late PlaylistService service;
  final a = _local('a');
  final b = _local('b');
  final c = Song.online(sourceId: 'source', trackId: 'track', title: '在线歌曲');

  setUp(() {
    now = DateTime.utc(2026, 10, 29);
    service = PlaylistService(now: () => now);
  });
  tearDown(() => service.onClose());

  test(
    'favorites exist by default, survive restore and cannot be renamed/deleted',
    () {
      expect(service.playlists.single.id, Playlist.favoritesId);
      expect(service.playlists.single.name, Playlist.favoritesName);
      expect(
        () => service.rename(Playlist.favoritesId, '新名字'),
        throwsFormatException,
      );
      expect(() => service.delete(Playlist.favoritesId), throwsFormatException);
      expect(service.toggleFavorite(a), isTrue);
      expect(service.isFavorite(a.id), isTrue);
      final favorite = service.findById(Playlist.favoritesId)!;
      final custom = service.create('工作');
      service.restore([custom, favorite]);
      expect(service.playlists.first.id, Playlist.favoritesId);
      expect(service.isFavorite(a.id), isTrue);
      expect(service.toggleFavorite(a), isFalse);
      expect(service.isFavorite(a.id), isFalse);
      service.restore([custom]);
      expect(service.playlists.map((p) => p.id), [
        Playlist.favoritesId,
        custom.id,
      ]);
    },
  );

  test(
    'names are trimmed and invalid, reserved or duplicate names are rejected',
    () {
      final custom = service.create('  Work  ');
      expect(custom.name, 'Work');
      for (final name in [
        '',
        '  ',
        List.filled(101, 'a').join(),
        'a\nb',
        'work',
        '我喜欢',
      ]) {
        expect(() => service.create(name), throwsFormatException);
      }
      service.rename(custom.id, '  Work ');
      expect(service.findById(custom.id)!.name, 'Work');
      final second = service.create('Other');
      expect(() => service.rename(second.id, 'WORK'), throwsFormatException);
      now = now.add(const Duration(seconds: 3));
      service.rename(custom.id, '休息');
      expect(service.findById(custom.id)!.createdAt, custom.createdAt);
      expect(service.findById(custom.id)!.updatedAt, now);
      expect(
        service.create(List.filled(100, '🙂').join()).name.runes,
        hasLength(100),
      );
    },
  );

  test(
    'batch additions deduplicate identities and preserve original ordering',
    () {
      final playlist = service.create('Mixed');
      expect(service.addSongs(playlist.id, [a, b, a, c]), (
        added: 3,
        existing: 1,
      ));
      expect(service.findById(playlist.id)!.songs.map((s) => s.id), [
        a.id,
        b.id,
        c.id,
      ]);
      final previous = service.findById(playlist.id)!;
      now = now.add(const Duration(seconds: 2));
      expect(service.addSongs(playlist.id, [b, c]), (added: 0, existing: 2));
      expect(service.findById(playlist.id), same(previous));
      service.reorderSongs(playlist.id, 0, 3);
      expect(service.findById(playlist.id)!.songs.map((s) => s.id), [
        b.id,
        c.id,
        a.id,
      ]);
      service.reorderSongs(playlist.id, 2, 0);
      expect(service.findById(playlist.id)!.songs.map((s) => s.id), [
        a.id,
        b.id,
        c.id,
      ]);
      service.removeSong(playlist.id, b.id);
      expect(service.findById(playlist.id)!.songs.map((s) => s.id), [
        a.id,
        c.id,
      ]);
      service.removeSong(playlist.id, 'absent');
      expect(service.findById(playlist.id)!.songs, hasLength(2));
      service.delete(playlist.id);
      expect(service.findById(playlist.id), isNull);
    },
  );

  test(
    'invalid references, reorders and unsafe songs do not partially mutate data',
    () {
      final playlist = service.create('Safe');
      service.addSongs(playlist.id, [a]);
      final before = service.findById(playlist.id)!;
      final unsafe = Song(
        uri: Uri.parse('https://host/audio?token=secret'),
        fileName: 'unsafe',
      );
      expect(
        () => service.addSongs(playlist.id, [b, unsafe]),
        throwsFormatException,
      );
      expect(() => service.toggleFavorite(unsafe), throwsFormatException);
      expect(() => service.rename('absent', 'Name'), throwsFormatException);
      expect(() => service.delete('absent'), throwsFormatException);
      expect(() => service.addSongs('absent', [a]), throwsFormatException);
      expect(() => service.removeSong('absent', a.id), throwsFormatException);
      expect(
        () => service.reorderSongs(playlist.id, -1, 0),
        throwsFormatException,
      );
      expect(
        () => service.reorderSongs(playlist.id, 0, 2),
        throwsFormatException,
      );
      expect(service.findById(playlist.id), same(before));
      expect(service.isFavorite(unsafe.id), isFalse);
    },
  );

  test(
    'playlist snapshots copy input and expose immutable songs and UTC times',
    () {
      final input = [a];
      final playlist = Playlist(
        id: 'custom',
        name: '副本',
        songs: input,
        createdAt: DateTime(2026, 10, 29),
        updatedAt: DateTime(2026, 10, 29),
      );
      input.add(b);
      expect(playlist.songs, hasLength(1));
      expect(() => playlist.songs.add(b), throwsUnsupportedError);
      expect(playlist.createdAt.isUtc, isTrue);
      expect(playlist.updatedAt.isUtc, isTrue);
      final copy = playlist.copyWith(songs: [a, c]);
      expect(playlist.songs, hasLength(1));
      expect(copy.songs, hasLength(2));
      expect(copy.createdAt, playlist.createdAt);
      final restored = Playlist.fromJson(copy.toJson());
      expect(restored.toJson(), copy.toJson());
      expect(
        () => Playlist.fromJson({
          ...copy.toJson(),
          'songs': [a.toJson(), a.toJson()],
        }),
        throwsFormatException,
      );
      expect(
        () => Playlist.fromJson({
          ...copy.toJson(),
          'createdAt': '2026-02-31T00:00:00.000Z',
        }),
        throwsFormatException,
      );
      expect(
        () => Playlist.fromJson({
          ...copy.toJson(),
          'updatedAt': DateTime.utc(2020).toIso8601String(),
        }),
        throwsFormatException,
      );
    },
  );

  test('restore validates atomically and rejects duplicate ids or names', () {
    final first = service.create('First');
    final second = service.create('Second');
    expect(() => service.restore([first, first]), throwsFormatException);
    expect(
      () => service.restore([first, second.copyWith(name: ' FIRST ')]),
      throwsFormatException,
    );
    expect(service.playlists.map((p) => p.id), [
      Playlist.favoritesId,
      first.id,
      second.id,
    ]);
  });

  test(
    'metadata updates preserve order, unindexed songs and edit timestamps',
    () {
      final playlist = service.create('同步');
      service.addSongs(playlist.id, [a, c, b]);
      service.toggleFavorite(a);
      final previous = service.findById(playlist.id)!;
      now = now.add(const Duration(days: 2));
      service.updateSongs([a.copyWith(trackTitle: '最新标题', isMissing: true)]);
      final updated = service.findById(playlist.id)!;
      expect(updated.songs.map((s) => s.id), [a.id, c.id, b.id]);
      expect(updated.songs.first.title, '最新标题');
      expect(updated.songs.first.isMissing, isTrue);
      expect(updated.updatedAt, previous.updatedAt);
      expect(updated.createdAt, previous.createdAt);
      expect(
        service.findById(Playlist.favoritesId)!.songs.single.title,
        '最新标题',
      );
      service.updateSongs([]);
      expect(service.findById(playlist.id), same(updated));
    },
  );

  test(
    'missing refresh checks songs outside index and leaves source bytes intact',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hanmusic-playlists-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/available.mp3');
      await file.writeAsString('source bytes');
      final available = Song(
        uri: file.uri,
        fileName: 'available.mp3',
        isMissing: true,
      );
      final missing = Song(
        uri: File('${directory.path}/gone.mp3').uri,
        fileName: 'gone.mp3',
      );
      final playlist = service.create('检查');
      service.addSongs(playlist.id, [a, available, missing, c]);
      final previous = service.findById(playlist.id)!;
      await service.refreshMissing([
        a.copyWith(trackTitle: '曲库信息', isMissing: true),
      ]);
      final updated = service.findById(playlist.id)!;
      expect(updated.songs.map((s) => s.isMissing), [true, false, true, false]);
      expect(updated.songs.first.title, '曲库信息');
      expect(updated.updatedAt, previous.updatedAt);
      expect(updated.songs.last.toJson(), c.toJson());
      service.removeSong(playlist.id, available.id);
      service.delete(playlist.id);
      expect(await file.readAsString(), 'source bytes');
    },
  );

  test('closing drops a pending refresh and rejects later mutations', () async {
    final exists = Completer<bool>();
    service.onClose();
    service = PlaylistService(now: () => now, fileExists: (_) => exists.future);
    final playlist = service.create('Close');
    service.addSongs(playlist.id, [a]);
    final previous = service.findById(playlist.id)!;
    final pending = service.refreshMissing([]);
    service.onClose();
    exists.complete(false);
    await pending;
    expect(service.findById(playlist.id), same(previous));
    expect(() => service.create('Late'), throwsStateError);
    expect(() => service.toggleFavorite(a), throwsStateError);
    expect(() => service.addSongs(playlist.id, [b]), throwsStateError);
  });

  test(
    'a newer indexed update wins over an older missing-file check',
    () async {
      final exists = Completer<bool>();
      service.onClose();
      service = PlaylistService(
        now: () => now,
        fileExists: (_) => exists.future,
      );
      final playlist = service.create('刷新竞争');
      service.addSongs(playlist.id, [a]);
      final pending = service.refreshMissing([]);
      service.updateSongs([a.copyWith(trackTitle: '最新信息', isMissing: false)]);
      exists.complete(false);
      await pending;
      final updated = service.findById(playlist.id)!.songs.single;
      expect(updated.title, '最新信息');
      expect(updated.isMissing, isFalse);
    },
  );

  test(
    'indexed sync does not discard unrelated checks and merges status into current snapshots',
    () async {
      final exists = Completer<bool>();
      final checkedUris = <Uri>[];
      service.onClose();
      service = PlaylistService(
        now: () => now,
        fileExists: (uri) {
          checkedUris.add(uri);
          return exists.future;
        },
      );
      final playlist = service.create('独立歌曲');
      service.addSongs(playlist.id, [a, b]);
      final pending = service.refreshMissing([a]);
      expect(checkedUris, [b.uri]);
      service.updateSongs([a.copyWith(trackTitle: '曲库更新')]);
      service.toggleFavorite(b.copyWith(trackTitle: '扫描中加入的收藏'));
      exists.complete(false);
      await pending;

      final songs = service.findById(playlist.id)!.songs;
      expect(songs.first.title, '曲库更新');
      expect(songs.last.isMissing, isTrue);
      final favorite = service.findById(Playlist.favoritesId)!.songs.single;
      expect(favorite.title, '扫描中加入的收藏');
      expect(favorite.isMissing, isTrue);
    },
  );

  test('newer refresh supersedes an older pending file check', () async {
    final first = Completer<bool>();
    final second = Completer<bool>();
    var calls = 0;
    service.onClose();
    service = PlaylistService(
      now: () => now,
      fileExists: (_) => ++calls == 1 ? first.future : second.future,
    );
    final playlist = service.create('连续刷新');
    service.addSongs(playlist.id, [a]);
    final old = service.refreshMissing([]);
    final current = service.refreshMissing([]);
    second.complete(true);
    await current;
    first.complete(false);
    await old;
    expect(service.findById(playlist.id)!.songs.single.isMissing, isFalse);
  });

  test(
    'restore invalidates old checks and file-check errors mark missing',
    () async {
      final exists = Completer<bool>();
      var calls = 0;
      service.onClose();
      service = PlaylistService(
        now: () => now,
        fileExists: (_) {
          if (++calls == 1) return exists.future;
          throw const FileSystemException('synthetic access failure');
        },
      );
      final playlist = service.create('恢复');
      service.addSongs(playlist.id, [a]);
      final pending = service.refreshMissing([]);
      final restored = service.findById(playlist.id)!.copyWith(name: '恢复后的歌单');
      service.restore([restored]);
      exists.complete(false);
      await pending;
      expect(service.findById(playlist.id)!.songs.single.isMissing, isFalse);
      expect(service.findById(playlist.id)!.name, '恢复后的歌单');
      await service.refreshMissing([]);
      expect(service.findById(playlist.id)!.songs.single.isMissing, isTrue);
    },
  );
}

Song _local(String name) => Song(
  uri: Uri.file('D:/music/$name.mp3', windows: true),
  fileName: '$name.mp3',
);
