import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';

void main() {
  final local = Song(
    uri: Uri.file('D:/music/local.mp3', windows: true),
    fileName: 'local.mp3',
  );
  final online = Song.online(
    sourceId: 'MySource',
    trackId: '曲目/A?',
    title: '在线曲目',
    artist: '作者',
  );

  test(
    'online identity survives round trip and never requires a file path',
    () {
      final restored = Song.fromJson(online.toJson());
      expect(restored.isOnline, isTrue);
      expect(restored.sourceId, 'MySource');
      expect(restored.trackId, '曲目/A?');
      expect(restored.id, online.id);
      expect(restored.uri.scheme, 'hanmusic');
      expect(restored.path, 'MySource / 曲目/A?');
      expect(restored.extension, '在线');
      expect(restored.copyWith(trackTitle: '新标题').id, online.id);
      expect(
        Song.online(
          sourceId: 'mysource',
          trackId: online.trackId!,
          title: 'x',
        ).id,
        isNot(online.id),
      );
      expect(
        () =>
            online.copyWith(uri: Uri.parse('https://host/audio?token=secret')),
        throwsFormatException,
      );
    },
  );

  test(
    'schema one local state migrates to schema two without changing identity',
    () {
      final old = {
        ...AppSnapshot(
          songs: [local],
          queue: [local],
          currentId: local.id,
        ).toJson(),
        'schemaVersion': 1,
      };
      final migrated = AppSnapshot.fromJson(old);
      expect(migrated.toJson()['schemaVersion'], 2);
      expect(migrated.queue.single.id, local.id);
      expect(migrated.currentId, local.id);
    },
  );

  test('mixed queue restores while the library stays local', () {
    final snapshot = AppSnapshot(
      songs: [local],
      queue: [local, online],
      currentId: online.id,
      position: const Duration(seconds: 22),
    );
    final restored = AppSnapshot.fromJson(snapshot.toJson());
    expect(restored.songs.single.isOnline, isFalse);
    expect(restored.queue.map((song) => song.isOnline), [false, true]);
    expect(restored.currentId, online.id);
    expect(restored.position, const Duration(seconds: 22));
    expect(snapshot.toJson().toString(), isNot(contains('https://')));
    expect(() => AppSnapshot(songs: [online]).toJson(), throwsFormatException);
    expect(
      () => AppSnapshot.fromJson({...snapshot.toJson(), 'schemaVersion': 1}),
      throwsFormatException,
    );
    expect(
      () => AppSnapshot.fromJson({...snapshot.toJson(), 'schemaVersion': 3}),
      throwsA(isA<UnsupportedStateVersion>()),
    );
  });

  test(
    'permanent HTTP sources and incomplete or noncanonical identities are rejected',
    () {
      final canonical = Song.online(
        sourceId: 'source',
        trackId: 'track',
        title: 'Title',
      ).toJson();
      for (final data in <Map<String, dynamic>>[
        {...canonical, 'uri': 'https://host/audio?token=secret'},
        {...canonical}..remove('trackId'),
        {...canonical, 'sourceId': 'different'},
        {...canonical, 'uri': 'hanmusic://track/source/track?token=secret'},
        {...canonical, 'uri': 'hanmusic://track/source/track#fragment'},
        {...canonical, 'uri': 'HANMUSIC://TRACK/source/track'},
        {...canonical, 'uri': 'hanmusic://track/source/%74rack'},
        {...canonical, 'uri': 'hanmusic://track/source/track/'},
        {...canonical, 'isMissing': true},
        {...canonical, 'artworkPath': 'https://host/secret'},
      ]) {
        expect(() => Song.fromJson(data), throwsFormatException);
      }
      final permanentUrl = Song(
        uri: Uri.parse('https://host/audio'),
        fileName: 'remote.mp3',
      );
      expect(
        () => AppSnapshot(queue: [permanentUrl]).toJson(),
        throwsFormatException,
      );
      expect(
        () => Song.online(sourceId: '.', trackId: 'a', title: 'x'),
        throwsFormatException,
      );
      expect(
        () => Song.online(sourceId: 'a', trackId: '', title: 'x'),
        throwsFormatException,
      );
    },
  );
}
