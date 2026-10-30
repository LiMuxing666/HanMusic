import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/playlist.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final local = Song(
    uri: Uri.file('D:/music/local.mp3', windows: true),
    fileName: 'local.mp3',
  );
  final online = Song.online(
    sourceId: 'source',
    trackId: 'track',
    title: '在线曲目',
  );
  final playlist = Playlist(
    id: 'custom',
    name: '旅途',
    songs: [local, online],
    createdAt: DateTime.utc(2026, 10, 28),
    updatedAt: DateTime.utc(2026, 10, 29),
  );

  for (final version in [1, 2]) {
    test('schema $version migrates to schema 5 with empty playlists', () {
      final json = {
        ...AppSnapshot(
          songs: [local],
          queue: version == 1 ? [local] : [local, online],
        ).toJson(),
        'schemaVersion': version,
      }..remove('playlists');
      final migrated = AppSnapshot.fromJson(json);
      expect(migrated.playlists, isEmpty);
      expect(migrated.toJson()['schemaVersion'], 5);
      expect(migrated.toJson()['playlists'], isEmpty);
      expect(migrated.queue.length, version);
    });
  }

  test(
    'current schema round trip preserves complete immutable playlist snapshots',
    () {
      final snapshot = AppSnapshot(playlists: [playlist]);
      final restored = AppSnapshot.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())),
      );
      expect(restored.playlists.single.toJson(), playlist.toJson());
      expect(restored.playlists.single.songs.map((s) => s.id), [
        local.id,
        online.id,
      ]);
      expect(() => restored.playlists.clear(), throwsUnsupportedError);
      expect(
        () => restored.playlists.single.songs.clear(),
        throwsUnsupportedError,
      );
      expect(jsonEncode(restored.toJson()), isNot(contains('https://')));
    },
  );

  test('missing, malformed or duplicate current playlists are rejected', () {
    final baseline = AppSnapshot(playlists: [playlist]).toJson();
    for (final data in <Map<String, dynamic>>[
      {...baseline}..remove('playlists'),
      {...baseline, 'playlists': null},
      {...baseline, 'playlists': {}},
      {
        ...baseline,
        'playlists': [null],
      },
      {
        ...baseline,
        'playlists': [playlist.toJson(), playlist.toJson()],
      },
      {
        ...baseline,
        'playlists': [
          {...playlist.toJson(), 'songs': 'bad'},
        ],
      },
      {
        ...baseline,
        'playlists': [
          {...playlist.toJson(), 'createdAt': 'invalid'},
        ],
      },
      {
        ...baseline,
        'playlists': [
          {...playlist.toJson(), 'name': ''},
        ],
      },
    ]) {
      expect(() => AppSnapshot.fromJson(data), throwsFormatException);
    }
    expect(
      () => AppSnapshot.fromJson({...baseline, 'schemaVersion': 6}),
      throwsA(isA<UnsupportedStateVersion>()),
    );
  });

  test(
    'playlist HTTP URLs and credential-bearing identities cannot be saved',
    () {
      for (final rawSong in <Map<String, Object?>>[
        {'uri': 'https://host/music?token=secret', 'fileName': 'remote.mp3'},
        {...online.toJson(), 'uri': '${online.uri}?token=secret'},
        {...local.toJson(), 'uri': 'file:///D:/music/local.mp3?token=secret'},
      ]) {
        final data = {
          ...const AppSnapshot().toJson(),
          'playlists': [
            {
              ...playlist.toJson(),
              'songs': [rawSong],
            },
          ],
        };
        expect(() => AppSnapshot.fromJson(data), throwsFormatException);
      }
    },
  );

  test(
    'file save captures playlist list before awaiting and restores online identity',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hanmusic-playlist-state-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileAppStateStore(directory);
      await store.load();
      final input = [playlist];
      final saving = store.save(AppSnapshot(playlists: input));
      input.clear();
      await saving;
      final restored = await FileAppStateStore(directory).load();
      expect(restored.playlists.single.toJson(), playlist.toJson());
      expect(restored.playlists.single.songs.last.isOnline, isTrue);
    },
  );

  test('corrupt schema 3 playlist recovers previous playlist backup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hanmusic-playlist-backup-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = FileAppStateStore(directory);
    await store.load();
    await store.save(AppSnapshot(playlists: [playlist]));
    await store.save(AppSnapshot(playlists: [playlist.copyWith(name: 'New')]));
    final corrupt = {...const AppSnapshot().toJson(), 'playlists': 'corrupt'};
    await File(
      '${directory.path}/state.json',
    ).writeAsString(jsonEncode(corrupt));
    final recovery = FileAppStateStore(directory);
    final restored = await recovery.load();
    expect(recovery.warning, contains('备份恢复'));
    expect(restored.playlists.single.toJson(), playlist.toJson());
    await recovery.save(restored);
    expect(
      (await FileAppStateStore(directory).load()).playlists.single.name,
      '旅途',
    );
  });
}
