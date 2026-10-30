import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/services/lyrics_service.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('hanmusic-lyrics-');
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  Song local(String name) =>
      Song(uri: File('${temporary.path}/$name.mp3').uri, fileName: '$name.mp3');

  LyricsService service({LyricsFileReader? readFile}) {
    final result = LyricsService(readFile: readFile);
    addTearDown(result.onClose);
    return result;
  }

  test(
    'reads UTF-8 BOM sidecar by audio file name without altering it',
    () async {
      final lyricFile = File('${temporary.path}/中文歌曲.lrc');
      final bytes = utf8.encode('\uFEFF[ar:歌手]\n[00:01.00]第一句\n[00:02.00]第二句');
      await lyricFile.writeAsBytes(bytes);
      final lyrics = service();

      await lyrics.selectSong(local('中文歌曲'));

      expect(lyrics.state.value, LyricsLoadState.ready);
      expect(lyrics.document.value!.timedLines.map((line) => line.text), [
        '第一句',
        '第二句',
      ]);
      expect(File(lyrics.filePath.value!).uri, lyricFile.uri);
      expect(await lyricFile.readAsBytes(), bytes);
      expect(await temporary.list().length, 1);
    },
  );

  test('decodes a real GBK Chinese sidecar strictly', () async {
    final lyricFile = File('${temporary.path}/gbk.lrc');
    final encoded = gbk.encode('[00:00.00]月光照在窗前\n[00:03.20]听一首歌');
    await lyricFile.writeAsBytes(encoded);
    final lyrics = service();

    await lyrics.selectSong(local('gbk'));

    expect(lyrics.state.value, LyricsLoadState.ready);
    expect(lyrics.document.value!.timedLines.first.text, '月光照在窗前');
    expect(lyrics.document.value!.timedLines.last.text, '听一首歌');
    expect(await lyricFile.readAsBytes(), encoded);
  });

  for (final entry in <String, List<int>>{
    'malformed GBK': [0x81],
    'binary control bytes': [0x00, 0x01, 0x02, 0x03],
    'UTF-16 BOM': [0xff, 0xfe, 0x41, 0x00],
  }.entries) {
    test('rejects ${entry.key} without displaying corrupted text', () async {
      final lyrics = service(readFile: (_, _) async => entry.value);

      await lyrics.selectSong(local('invalid'));

      expect(lyrics.state.value, LyricsLoadState.error);
      expect(lyrics.document.value, isNull);
      expect(lyrics.message.value, contains('UTF-8 或 GBK'));
    });
  }

  test('plain text and metadata-only files get distinct states', () async {
    final lyricFile = File('${temporary.path}/plain.lrc');
    await lyricFile.writeAsString('没有时间标签\n仍然可以阅读');
    final lyrics = service();
    await lyrics.selectSong(local('plain'));
    expect(lyrics.state.value, LyricsLoadState.ready);
    expect(lyrics.document.value!.isTimed, isFalse);
    expect(lyrics.document.value!.plainLines, ['没有时间标签', '仍然可以阅读']);
    expect(lyrics.message.value, contains('纯文本'));

    await lyricFile.writeAsString('[ar:歌手]\n[ti:标题]\n[offset:50]');
    await lyrics.selectSong(local('plain'));
    expect(lyrics.state.value, LyricsLoadState.notFound);
    expect(lyrics.document.value, isNull);
    expect(lyrics.message.value, contains('没有可显示'));
  });

  test('missing, online and unselected songs clear previous lyrics', () async {
    final lyrics = service(
      readFile: (path, _) async {
        return path.endsWith('present.lrc') ? utf8.encode('[00:00]旧歌词') : null;
      },
    );
    await lyrics.selectSong(local('present'));
    expect(lyrics.document.value, isNotNull);
    await lyrics.selectSong(local('missing'));
    expect(lyrics.state.value, LyricsLoadState.notFound);
    expect(lyrics.document.value, isNull);
    expect(lyrics.message.value, contains('同名'));

    await lyrics.selectSong(
      Song.online(sourceId: 'source', trackId: '1', title: '在线歌'),
    );
    expect(lyrics.state.value, LyricsLoadState.unsupported);
    expect(lyrics.filePath.value, isNull);
    expect(lyrics.message.value, contains('尚未关联'));
    await lyrics.selectSong(null);
    expect(lyrics.state.value, LyricsLoadState.idle);
    expect(lyrics.document.value, isNull);
  });

  test('late old selection cannot overwrite the new song', () async {
    final old = Completer<List<int>?>();
    final lyrics = service(
      readFile: (path, _) {
        return path.endsWith('old.lrc')
            ? old.future
            : Future.value(utf8.encode('[00:00]新歌词'));
      },
    );
    final first = lyrics.selectSong(local('old'));
    await lyrics.selectSong(local('new'));
    expect(lyrics.document.value!.timedLines.single.text, '新歌词');
    old.complete(utf8.encode('[00:00]旧歌词'));
    await first;
    expect(lyrics.document.value!.timedLines.single.text, '新歌词');
    expect(lyrics.filePath.value, endsWith('new.lrc'));
  });

  test('late read failure cannot replace online song state', () async {
    final pending = Completer<List<int>?>();
    final lyrics = service(readFile: (_, _) => pending.future);
    final load = lyrics.selectSong(local('pending'));
    await lyrics.selectSong(
      Song.online(sourceId: 'source', trackId: '1', title: '在线歌'),
    );
    pending.completeError(const FileSystemException('Access denied'));
    await load;
    expect(lyrics.state.value, LyricsLoadState.unsupported);
    expect(lyrics.message.value, contains('尚未关联'));
  });

  test('closing invalidates pending reads', () async {
    final pending = Completer<List<int>?>();
    final lyrics = service(readFile: (_, _) => pending.future);
    final load = lyrics.selectSong(local('pending'));
    lyrics.onClose();
    final previous = lyrics.state.value;
    pending.complete(utf8.encode('[00:00]迟到歌词'));
    await load;
    await lyrics.selectSong(local('another'));
    expect(lyrics.document.value, isNull);
    expect(lyrics.state.value, previous);
  });

  test('rejects an oversized file before reading its contents', () async {
    final file = File('${temporary.path}/large.lrc');
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(LyricsService.maxFileBytes + 1);
    await handle.close();
    final lyrics = service();
    await lyrics.selectSong(local('large'));
    expect(lyrics.state.value, LyricsLoadState.error);
    expect(lyrics.message.value, contains('超过 1 MB'));
    expect(lyrics.document.value, isNull);
    expect(await file.length(), LyricsService.maxFileBytes + 1);
  });

  test(
    'checks the reader output limit and reports filesystem errors',
    () async {
      var oversized = true;
      final lyrics = service(
        readFile: (_, limit) async {
          expect(limit, LyricsService.maxFileBytes);
          if (oversized) return List.filled(limit + 1, 65);
          throw const FileSystemException('Access denied');
        },
      );
      await lyrics.selectSong(local('guarded'));
      expect(lyrics.message.value, contains('超过 1 MB'));
      oversized = false;
      await lyrics.selectSong(local('guarded'));
      expect(lyrics.state.value, LyricsLoadState.error);
      expect(lyrics.message.value, contains('访问权限'));
    },
  );
}
