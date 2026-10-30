import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/play_history_entry.dart';
import 'package:han_music/app/data/models/playlist.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final local = Song(
    uri: Uri.file('D:/music/history.mp3', windows: true),
    fileName: 'history.mp3',
  );
  final online = Song.online(
    sourceId: 'demo',
    trackId: 'cloud-track',
    title: '云端歌曲',
  );
  final date = DateTime.utc(2026, 10, 29, 12);
  final entry = PlayHistoryEntry(song: local, lastPlayedAt: date, playCount: 3);
  final playlist = Playlist(
    id: 'saved',
    name: '保留歌单',
    songs: [local],
    createdAt: date,
    updatedAt: date,
  );

  for (final version in [1, 2, 3]) {
    test('schema $version migrates without losing earlier collections', () {
      final json = {
        ...AppSnapshot(
          songs: [local],
          queue: [local],
          playlists: [playlist],
        ).toJson(),
        'schemaVersion': version,
      }..remove('history');
      if (version < 3) json.remove('playlists');
      final restored = AppSnapshot.fromJson(json);
      expect(restored.history, isEmpty);
      expect(restored.songs.single.id, local.id);
      expect(restored.queue.single.id, local.id);
      expect(restored.playlists.length, version < 3 ? 0 : 1);
      expect(restored.toJson()['schemaVersion'], 5);
      expect(restored.toJson()['history'], isEmpty);
    });
  }

  test(
    'history round trip preserves immutable local and online identities',
    () {
      final snapshot = AppSnapshot(
        history: [
          entry,
          PlayHistoryEntry(
            song: online,
            lastPlayedAt: date.subtract(const Duration(days: 1)),
            playCount: 1,
          ),
        ],
      );
      final restored = AppSnapshot.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())),
      );
      expect(restored.history.map((value) => value.song.id), [
        local.id,
        online.id,
      ]);
      expect(restored.history.first.playCount, 3);
      expect(restored.history.first.lastPlayedAt, date);
      expect(() => restored.history.clear(), throwsUnsupportedError);
      expect(jsonEncode(restored.toJson()), isNot(contains('https://')));
    },
  );

  test('corrupt, duplicate and excessive history is rejected', () {
    final base = AppSnapshot(history: [entry]).toJson();
    for (final value in <Map<String, dynamic>>[
      {...base}..remove('history'),
      {...base, 'history': null},
      {...base, 'history': {}},
      {
        ...base,
        'history': [null],
      },
      {
        ...base,
        'history': [entry.toJson(), entry.toJson()],
      },
      {
        ...base,
        'history': [
          {...entry.toJson(), 'playCount': 0},
        ],
      },
      {
        ...base,
        'history': [
          {...entry.toJson(), 'lastPlayedAt': 'not-a-date'},
        ],
      },
      {...base, 'history': List.filled(201, entry.toJson())},
      {
        ...base,
        'history': [
          {
            ...entry.toJson(),
            'song': {
              'uri': 'https://example.invalid/audio?token=secret',
              'fileName': 'audio.mp3',
            },
          },
        ],
      },
    ]) {
      expect(() => AppSnapshot.fromJson(value), throwsFormatException);
    }
  });

  test(
    'file writes capture history before awaiting and recover corrupt history',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hanmusic-history-state-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileAppStateStore(directory);
      await store.load();
      final input = [entry];
      final saving = store.save(
        AppSnapshot(history: input, playlists: [playlist]),
      );
      input.clear();
      await saving;
      expect(
        (await FileAppStateStore(directory).load()).history.single.playCount,
        3,
      );
      await store.save(const AppSnapshot());
      await File('${directory.path}/state.json').writeAsString(
        jsonEncode({...const AppSnapshot().toJson(), 'history': 'damaged'}),
      );
      final recovered = FileAppStateStore(directory);
      final restored = await recovered.load();
      expect(recovered.warning, contains('备份恢复'));
      expect(restored.history.single.toJson(), entry.toJson());
      expect(restored.playlists.single.name, '保留歌单');
    },
  );
}
