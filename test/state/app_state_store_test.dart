import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/play_mode.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late FileAppStateStore store;
  final song = Song(
    uri: Uri.file(r'D:\音乐 测试\曲目.flac', windows: true),
    fileName: '曲目.flac',
    trackTitle: '夜航',
    artist: '测试歌手',
    album: '测试专辑',
    duration: const Duration(minutes: 3),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hanmusic-state-test-');
    store = FileAppStateStore(directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('new store starts empty without restoring a timer', () async {
    final state = await store.load();
    expect(state.songs, isEmpty);
    expect(state.queue, isEmpty);
    expect(state.mode, PlayMode.sequential);
    expect(state.toJson(), isNot(contains('timer')));
  });

  test(
    'await save persists a complete snapshot and a new store restores it',
    () async {
      await store.load();
      await store.save(
        AppSnapshot(
          songs: [song],
          queue: [song],
          currentId: song.id,
          position: const Duration(seconds: 42),
          mode: PlayMode.shuffle,
          volume: .3,
          skipOnError: false,
        ),
      );
      final json = jsonDecode(
        await File('${directory.path}/state.json').readAsString(),
      );
      expect(json['positionMs'], 42000);
      final restored = await FileAppStateStore(directory).load();
      expect(restored.songs.single.title, '夜航');
      expect(restored.songs.single.artist, '测试歌手');
      expect(restored.queue.single.id, song.id);
      expect(restored.currentId, song.id);
      expect(restored.mode, PlayMode.shuffle);
      expect(restored.volume, .3);
      expect(restored.skipOnError, isFalse);
      expect(restored.position, const Duration(seconds: 42));
    },
  );

  test(
    'concurrent saves retain call order and only write owned state files',
    () async {
      await store.load();
      final source = File('${directory.path}/source.mp3');
      await source.writeAsString('Source audio must not change.');
      await Future.wait(
        List.generate(
          10,
          (i) => store.save(
            AppSnapshot(
              songs: [song],
              position: Duration(seconds: i),
            ),
          ),
        ),
      );
      expect(
        (await FileAppStateStore(directory).load()).position,
        const Duration(seconds: 9),
      );
      expect(await source.readAsString(), 'Source audio must not change.');
      expect(await File('${directory.path}/state.next.json').exists(), isFalse);
    },
  );

  test(
    'corrupt primary recovers the last valid backup and can save again',
    () async {
      await store.load();
      await store.save(
        AppSnapshot(songs: [song], position: const Duration(seconds: 10)),
      );
      await store.save(
        AppSnapshot(songs: [song], position: const Duration(seconds: 20)),
      );
      await File('${directory.path}/state.json').writeAsString('{partial');
      final recovered = FileAppStateStore(directory);
      expect((await recovered.load()).position, const Duration(seconds: 10));
      expect(recovered.warning, contains('备份恢复'));
      await recovered.save(
        AppSnapshot(songs: [song], position: const Duration(seconds: 30)),
      );
      expect(
        (await FileAppStateStore(directory).load()).position,
        const Duration(seconds: 30),
      );
    },
  );

  test(
    'invalid schema and damaged backup are preserved without overwriting',
    () async {
      final primary = File('${directory.path}/state.json');
      await primary.writeAsString('{}');
      await File(
        '${directory.path}/state.backup.json',
      ).writeAsString('corrupt');
      expect((await store.load()).songs, isEmpty);
      expect(store.warning, contains('保留原文件'));
      await expectLater(store.save(const AppSnapshot()), throwsStateError);
      expect(await primary.readAsString(), '{}');
    },
  );

  test('newer schema is not downgraded through an older backup', () async {
    await store.load();
    await store.save(AppSnapshot(songs: [song]));
    await store.save(AppSnapshot(songs: [song]));
    final primary = File('${directory.path}/state.json');
    const futureData = '{"schemaVersion":99,"unrecognizedUserData":"keep"}';
    await primary.writeAsString(futureData);
    final newer = FileAppStateStore(directory);
    expect((await newer.load()).songs, isEmpty);
    expect(newer.warning, contains('不支持的版本'));
    await expectLater(newer.save(const AppSnapshot()), throwsStateError);
    expect(await primary.readAsString(), futureData);
  });

  test(
    'a disk path failure produces a visible warning and rejects saving',
    () async {
      final blocked = File('${directory.path}/blocked');
      await blocked.writeAsString('not a directory');
      final unavailable = FileAppStateStore(Directory(blocked.path));
      await unavailable.load();
      expect(unavailable.warning, contains('无法访问'));
      await expectLater(
        unavailable.save(const AppSnapshot()),
        throwsStateError,
      );
      expect(await blocked.readAsString(), 'not a directory');
    },
  );

  test('state decoding rejects invalid schemes and playback settings', () {
    final data = AppSnapshot(songs: [song]).toJson();
    expect(
      () => AppSnapshot.fromJson({...data, 'volume': 5}),
      throwsFormatException,
    );
    expect(
      () => AppSnapshot.fromJson({...data, 'mode': 'invalid'}),
      throwsFormatException,
    );
    expect(
      () => AppSnapshot.fromJson({
        ...data,
        'songs': [
          {'uri': 'https://example.com/song', 'fileName': 'remote.mp3'},
        ],
      }),
      throwsFormatException,
    );
  });

  test(
    'malformed file URI falls back to backup before startup path access',
    () async {
      await store.load();
      await store.save(AppSnapshot(songs: [song]));
      await store.save(AppSnapshot(songs: [song]));
      final invalid = AppSnapshot(
        songs: [
          Song(
            uri: Uri.parse('file:///D:/audio.mp3?query=1'),
            fileName: 'audio.mp3',
          ),
        ],
      ).toJson();
      await File(
        '${directory.path}/state.json',
      ).writeAsString(jsonEncode(invalid));
      final recovered = FileAppStateStore(directory);
      expect((await recovered.load()).songs.single.id, song.id);
      expect(recovered.warning, contains('备份恢复'));
    },
  );

  test(
    'ten thousand entries persist and restore with metadata intact',
    () async {
      final songs = List.generate(
        10000,
        (i) => Song(
          uri: Uri.file('D:/test-library/曲目 $i.flac', windows: true),
          fileName: '曲目 $i.flac',
          trackTitle: '曲目 $i',
          artist: '歌手 ${i % 50}',
          album: '专辑 ${i % 100}',
        ),
      );
      await store.load();
      await store.save(
        AppSnapshot(songs: songs, queue: songs.take(100).toList()),
      );
      final recovered = await FileAppStateStore(directory).load();
      expect(recovered.songs, hasLength(10000));
      expect(recovered.queue, hasLength(100));
      expect(recovered.songs.last.title, '曲目 9999');
    },
  );
}
