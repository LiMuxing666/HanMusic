import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/playlist.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/playlist_transfer.dart';
import 'package:path/path.dart' as path;

final _local = Song(
  uri: Uri.file('D:/音乐/风.mp3', windows: true),
  fileName: '风.mp3',
  trackTitle: '风',
  artist: '歌手',
  album: '专辑',
  duration: const Duration(seconds: 123),
  artworkPath: 'D:/cache/cover.png',
  isMissing: true,
);
final _online = Song.online(
  sourceId: 'demo',
  trackId: 'CaseSensitive/曲目',
  title: '在线歌曲',
  artist: '远方',
  album: '云端',
  duration: const Duration(seconds: 234),
);

List<int> _encoded({String name = '晚风', List<Song>? songs}) =>
    PlaylistTransferCodec.encode(name: name, songs: songs ?? [_local, _online]);

Map<String, dynamic> _json() =>
    jsonDecode(utf8.decode(_encoded())) as Map<String, dynamic>;
List<int> _bytes(Object value) => utf8.encode(jsonEncode(value));

void main() {
  test(
    'M3U8 resolves local relative paths and preserves first order and metadata',
    () {
      final document = PlaylistTransferCodec.decode(
        utf8.encode(
          '\uFEFF#EXTM3U\r\n'
          '#EXTINF:12.5,中文标题\r\n'
          r'..\音乐\风.mp3'
          '\r\n'
          'D:/音乐/风.MP3\r\n'
          '#EXTINF:-1,另一个标题\r\n'
          'file:///D:/%E9%9F%B3%E4%B9%90/%E6%B5%B7%20%26%20(%E6%99%9A).flac\r\n',
        ),
        sourcePath: 'D:/lists/旅行.m3u8',
      );
      expect(document.name, '旅行');
      expect(document.formatLabel, 'M3U8 · UTF-8');
      expect(document.duplicateCount, 1);
      expect(document.skippedCount, 0);
      expect(document.songs.map((song) => song.path), [
        r'D:\音乐\风.mp3',
        r'D:\音乐\海 & (晚).flac',
      ]);
      expect(document.songs.first.trackTitle, '中文标题');
      expect(
        document.songs.first.duration,
        const Duration(milliseconds: 12500),
      );
      expect(document.songs.last.duration, isNull);
      expect(document.songs.every((song) => song.isMissing), isTrue);
      expect(() => document.songs.clear(), throwsUnsupportedError);
    },
  );

  test('M3U detects strict UTF8 or GBK while M3U8 never guesses GBK', () {
    final text = '#EXTM3U\n音乐/风.mp3\n';
    final encoded = gbk.encode(text);
    final gbkDocument = PlaylistTransferCodec.decode(
      encoded,
      sourcePath: 'D:/旅行.m3u',
    );
    expect(gbkDocument.formatLabel, 'M3U · GBK');
    expect(gbkDocument.songs.single.id, _local.id);
    expect(
      PlaylistTransferCodec.decode(
        utf8.encode(text),
        sourcePath: 'D:/旅行.M3U',
      ).formatLabel,
      'M3U · UTF-8',
    );
    expect(
      () => PlaylistTransferCodec.decode(encoded, sourcePath: 'D:/旅行.m3u8'),
      throwsFormatException,
    );
    for (final bytes in <List<int>>[
      [0xff, 0xfe, 35, 0],
      [0xfe, 0xff, 0, 35],
      [0x81],
      [0xef, 0xbb, 0xbf, ...encoded],
      utf8.encode('D:/bad\u0000.mp3'),
    ]) {
      expect(
        () => PlaylistTransferCodec.decode(bytes, sourcePath: 'D:/旅行.m3u'),
        throwsFormatException,
      );
    }
  });

  test(
    'M3U skips remote, device, ADS and nested playlists without leaking metadata',
    () {
      final rejected = [
        'https://example.invalid/song.mp3?token=secret',
        'ftp://example.invalid/song.flac',
        'file://server/share/song.mp3',
        r'\\server\share\song.mp3',
        r'\\?\D:\device.mp3',
        r'\\.\device.mp3',
        'D:/song:stream.mp3',
        'C:ambiguous.mp3',
        '/root-relative.mp3',
        r'\root-relative.mp3',
        'nested.m3u',
        'nested.m3u8',
        'nested.json',
        'folder',
        'picture.png',
        'D:/CON.mp3',
        'D:/folder./track.mp3',
      ];
      final text =
          '#EXTM3U\n#EXTVLCOPT:http-proxy=example.invalid\n'
          '#EXTINF:123,必须丢弃的标题\n${rejected.join('\n')}\n'
          'good.mp3\n';
      final document = PlaylistTransferCodec.decode(
        utf8.encode(text),
        sourcePath: 'D:/lists/test.m3u8',
      );
      expect(document.skippedCount, rejected.length);
      expect(document.songs.single.path, r'D:\lists\good.mp3');
      expect(document.songs.single.trackTitle, isNull);
      expect(document.songs.single.duration, isNull);
      for (final text in [
        '#EXTM3U\n#EXT-X-TARGETDURATION:10\nD:/part.aac',
        'https://example.invalid/song.mp3\n',
      ]) {
        expect(
          () => PlaylistTransferCodec.decode(
            utf8.encode(text),
            sourcePath: 'D:/lists/test.m3u8',
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'M3U limits count all entry lines before filtering or deduplication',
    () {
      for (final text in [
        'D:/same.mp3\n' * (PlaylistTransferCodec.maxSongs + 1),
        '# comment\n' * (PlaylistTransferCodec.maxTextLines + 1),
        '${'a' * 4097}.mp3\n',
      ]) {
        expect(
          () => PlaylistTransferCodec.decode(
            utf8.encode(text),
            sourcePath: 'D:/list.m3u8',
          ),
          throwsFormatException,
        );
      }
      expect(
        () => PlaylistTransferCodec.decode(
          List.filled(PlaylistTransferCodec.maxFileBytes + 1, 32),
          sourcePath: 'D:/list.m3u8',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'M3U8 output is UTF8 local-only and preserves missing paths and duration',
    () {
      final bytes = PlaylistTransferCodec.encode(
        name: '分享',
        songs: [_local, _online],
        outputFormat: PlaylistTransferFormat.m3u8,
      );
      final text = utf8.decode(bytes, allowMalformed: false);
      expect(text, startsWith('#EXTM3U\r\n'));
      expect(text, contains(r'D:\音乐\风.mp3'));
      expect(text, isNot(contains('hanmusic:')));
      expect(text, isNot(contains('在线歌曲')));
      final result = PlaylistTransferCodec.decode(
        bytes,
        sourcePath: 'D:/分享.m3u8',
      );
      expect(result.songs.single.id, _local.id);
      expect(result.songs.single.title, _local.title);
      expect(result.songs.single.duration, _local.duration);
      expect(result.songs.single.isMissing, isTrue);
      expect(
        PlaylistTransferCodec.suggestedFileName(
          '分享',
          outputFormat: PlaylistTransferFormat.m3u8,
        ),
        'HanMusic-分享.m3u8',
      );
      expect(
        () => PlaylistTransferCodec.encode(
          name: '在线',
          songs: [_online],
          outputFormat: PlaylistTransferFormat.m3u8,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'M3U import probes only accepted local entries and preserves its report',
    () async {
      final files = _Files()
        ..importPath = 'D:/lists/test.m3u8'
        ..importBytes = utf8.encode(
          'D:/music/present.mp3\nD:/music/missing.flac\n'
          'D:/music/PRESENT.MP3\nhttps://example.invalid/remote.mp3\nnested.m3u8\n',
        )
        ..exists = (uri) async => uri.path.endsWith('present.mp3');
      final document = await PlaylistTransfer(
        files: files,
      ).importPlaylist(canCommit: () => true);
      expect(files.probed.map((uri) => uri.toFilePath(windows: true)), [
        r'D:\music\present.mp3',
        r'D:\music\missing.flac',
      ]);
      expect(document!.songs.map((song) => song.isMissing), [false, true]);
      expect(document.skippedCount, 2);
      expect(document.duplicateCount, 1);
      expect(document.formatLabel, 'M3U8 · UTF-8');
      expect(files.writes, 0);
    },
  );

  test(
    'M3U8 native writer numbers conflicts using the selected extension',
    () async {
      final directory = await Directory.systemTemp.createTemp('hanmusic-m3u8-');
      addTearDown(() => directory.delete(recursive: true));
      final original = File(path.join(directory.path, '分享.m3u8'));
      await original.writeAsString('existing');
      final files = LocalPlaylistTransferFiles();
      final saved = await files.write(
        original.path,
        PlaylistTransferCodec.encode(
          name: '分享',
          songs: [_local],
          outputFormat: PlaylistTransferFormat.m3u8,
        ),
        canCommit: () => true,
      );
      expect(saved, endsWith('分享 (2).m3u8'));
      expect(await original.readAsString(), 'existing');
      expect(
        PlaylistTransferCodec.decode(
          await File(saved).readAsBytes(),
          sourcePath: saved,
        ).songs.single.id,
        _local.id,
      );
      expect(directory.listSync().whereType<Directory>(), isEmpty);
    },
  );

  test(
    'M3U8 export with no local songs performs no file-picker or write work',
    () async {
      final files = _Files();
      await expectLater(
        PlaylistTransfer(files: files).exportPlaylist(
          name: '在线',
          songs: [_online],
          canCommit: () => true,
          outputFormat: PlaylistTransferFormat.m3u8,
        ),
        throwsFormatException,
      );
      expect(files.exportPicks, 0);
      expect(files.writes, 0);
    },
  );

  test('mixed local and online metadata round trips in exact song order', () {
    final bytes = _encoded();
    final decoded = PlaylistTransferCodec.decode(bytes);
    expect(decoded.name, '晚风');
    expect(decoded.songs.map((song) => song.id), [_local.id, _online.id]);
    final portableLocal = _local.toJson()..remove('artworkPath');
    expect(decoded.songs[0].toJson(), portableLocal);
    expect(decoded.songs[1].toJson(), _online.toJson());
    final text = utf8.decode(bytes);
    expect(text, contains('hanmusic-playlist'));
    expect(text, isNot(contains('artworkPath')));
    expect(text, isNot(contains('https://')));
    expect(() => decoded.songs.add(_local), throwsUnsupportedError);
    expect(
      PlaylistTransferCodec.decode([0xef, 0xbb, 0xbf, ...bytes]).songs.length,
      2,
    );
  });

  test(
    'empty and favorites exports import as documents without destination ids',
    () {
      final document = PlaylistTransferCodec.decode(
        _encoded(name: Playlist.favoritesName, songs: []),
      );
      expect(document.name, Playlist.favoritesName);
      expect(document.songs, isEmpty);
      expect(_json()['playlist'], isNot(contains('id')));
    },
  );

  test(
    'duplicates are rejected including case-insensitive local identities',
    () {
      final duplicate = _local.copyWith(
        uri: Uri.file('d:/音乐/风.MP3', windows: true),
      );
      expect(() => _encoded(songs: [_local, duplicate]), throwsFormatException);
      final data = _json();
      (data['playlist']['songs'] as List).add(data['playlist']['songs'][0]);
      expect(
        () => PlaylistTransferCodec.decode(_bytes(data)),
        throwsFormatException,
      );
    },
  );

  test('bad input future versions URLs and unknown fields fail completely', () {
    final invalid = <Object>[
      [],
      {'format': 'other', 'version': 1, 'playlist': {}},
      _json()..['version'] = 2,
      _json()..['version'] = 1.0,
      _json()..['streamUrl'] = 'https://example.invalid/secret',
    ];
    for (final value in invalid) {
      expect(
        () => PlaylistTransferCodec.decode(_bytes(value)),
        throwsFormatException,
      );
    }
    for (final change in <void Function(Map<String, dynamic>)>[
      (song) => song['uri'] = 'https://example.invalid/audio?token=secret',
      (song) => song['uri'] = 'file:///D:/track.mp3?token=secret',
      (song) => song['durationMs'] = -1,
      (song) => song['artist'] = 42,
      (song) => song['trackTitle'] = 'bad\u0000title',
      (song) => song['resolvedUrl'] = 'https://example.invalid/stream',
    ]) {
      final data = _json();
      change(data['playlist']['songs'][0] as Map<String, dynamic>);
      expect(
        () => PlaylistTransferCodec.decode(_bytes(data)),
        throwsFormatException,
      );
    }
    final online = _json();
    online['playlist']['songs'][1]['trackId'] = 'different';
    expect(
      () => PlaylistTransferCodec.decode(_bytes(online)),
      throwsFormatException,
    );
    for (final bytes in <List<int>>[
      [],
      [0xff, 0xfe],
      utf8.encode('{bad'),
      List.filled(PlaylistTransferCodec.maxFileBytes + 1, 32),
    ]) {
      expect(() => PlaylistTransferCodec.decode(bytes), throwsFormatException);
    }
  });

  test('song and metadata limits are enforced before output or import', () {
    final data = _json();
    data['playlist']['songs'] = List.filled(
      PlaylistTransferCodec.maxSongs + 1,
      _local.toJson(),
    );
    expect(
      () => PlaylistTransferCodec.decode(_bytes(data)),
      throwsFormatException,
    );
    expect(
      () => _encoded(songs: [_local.copyWith(artist: 'x' * 4097)]),
      throwsFormatException,
    );
    expect(
      () => _encoded(
        songs: [_local.copyWith(duration: const Duration(days: 366))],
      ),
      throwsFormatException,
    );
  });

  test('duplicate names and favorites are numbered without overwriting', () {
    expect(PlaylistTransferCodec.uniqueName('夜晚', ['夜晚', '夜晚 (2)']), '夜晚 (3)');
    expect(PlaylistTransferCodec.uniqueName('NIGHT', ['night']), 'NIGHT (2)');
    expect(
      PlaylistTransferCodec.uniqueName(Playlist.favoritesName, []),
      '我喜欢 (2)',
    );
    final longName = '🌙' * 100;
    final name = PlaylistTransferCodec.uniqueName(longName, [longName]);
    expect(name.runes.length, 100);
    expect(name.endsWith(' (2)'), isTrue);
    expect(
      PlaylistTransferCodec.suggestedFileName('CON / ?'),
      'HanMusic-CON _ _${PlaylistTransferCodec.extension}',
    );
  });

  test(
    'native reader is bounded and native writer never replaces existing files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hanmusic-transfer-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final files = LocalPlaylistTransferFiles();
      final destination = File(
        path.join(directory.path, 'list${PlaylistTransferCodec.extension}'),
      );
      await destination.writeAsString('existing user file');
      final saved = await files.write(
        destination.path,
        _encoded(),
        canCommit: () => true,
      );
      expect(saved, endsWith('list (2)${PlaylistTransferCodec.extension}'));
      expect(await destination.readAsString(), 'existing user file');
      expect(
        PlaylistTransferCodec.decode(
          await files.read(saved, PlaylistTransferCodec.maxFileBytes),
        ).songs.length,
        2,
      );
      final oversized = File(path.join(directory.path, 'large.json'));
      await oversized.writeAsBytes(List.filled(33, 32));
      await expectLater(files.read(oversized.path, 32), throwsFormatException);
      expect(directory.listSync().whereType<Directory>(), isEmpty);
    },
  );

  test(
    'native canceled writer removes only its private temporary directory',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hanmusic-transfer-cancel-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final destination = path.join(
        directory.path,
        'cancel${PlaylistTransferCodec.extension}',
      );
      var checks = 0;
      await expectLater(
        LocalPlaylistTransferFiles().write(
          destination,
          _encoded(),
          canCommit: () => ++checks < 3,
        ),
        throwsA(isA<PlaylistTransferCanceled>()),
      );
      expect(directory.listSync(), isEmpty);
    },
  );

  test(
    'canceling picker or exiting before its response performs no IO',
    () async {
      final files = _Files()
        ..importPath = null
        ..exportPath = null;
      final transfer = PlaylistTransfer(files: files);
      expect(await transfer.importPlaylist(canCommit: () => true), isNull);
      expect(
        await transfer.exportPlaylist(
          name: 'test',
          songs: [_local],
          canCommit: () => true,
        ),
        isNull,
      );
      expect(files.reads, 0);
      expect(files.writes, 0);
      final gate = Completer<String?>();
      files.importGate = gate;
      var active = true;
      final pending = transfer.importPlaylist(canCommit: () => active);
      active = false;
      gate.complete('late.json');
      expect(await pending, isNull);
      expect(files.reads, 0);
    },
  );

  test('read timeout and exit during read never return a document', () async {
    final gate = Completer<List<int>>();
    final files = _Files()..readGate = gate;
    final transfer = PlaylistTransfer(
      files: files,
      ioTimeout: const Duration(milliseconds: 5),
    );
    await expectLater(
      transfer.importPlaylist(canCommit: () => true),
      throwsA(isA<TimeoutException>()),
    );
    gate.complete(_encoded());
    var active = true;
    files.readGate = Completer<List<int>>();
    final pending = transfer.importPlaylist(canCommit: () => active);
    await Future<void>.delayed(Duration.zero);
    active = false;
    files.readGate!.complete(_encoded());
    expect(await pending, isNull);
  });

  test(
    'import refreshes both stale missing flags using actual local files and never probes online identities',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hanmusic-import-stat-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final present = await File(
        path.join(directory.path, 'present.mp3'),
      ).writeAsBytes([1, 2]);
      final absent = File(path.join(directory.path, 'absent.mp3'));
      final songs = [
        Song(uri: present.uri, fileName: 'present.mp3', isMissing: true),
        Song(uri: absent.uri, fileName: 'absent.mp3', isMissing: false),
        _online,
      ];
      final files = _Files()
        ..importBytes = _encoded(songs: songs)
        ..exists = LocalPlaylistTransferFiles().localFileExists;
      final document = await PlaylistTransfer(
        files: files,
      ).importPlaylist(canCommit: () => true);
      expect(
        document!.songs.map((song) => song.id),
        songs.map((song) => song.id),
      );
      expect(document.songs.map((song) => song.isMissing), [
        false,
        true,
        false,
      ]);
      expect(files.probed, [present.uri, absent.uri]);
      expect(await present.readAsBytes(), [1, 2]);
      expect(await absent.exists(), isFalse);
    },
  );

  test(
    'inaccessible local files remain in imported order as missing',
    () async {
      final files = _Files()
        ..importBytes = _encoded(
          songs: [_local.copyWith(isMissing: false), _online],
        )
        ..exists = (_) async => throw const FileSystemException('denied');
      final document = await PlaylistTransfer(
        files: files,
      ).importPlaylist(canCommit: () => true);
      expect(document!.songs.map((song) => song.id), [_local.id, _online.id]);
      expect(document.songs.map((song) => song.isMissing), [true, false]);
      expect(files.probed, [_local.uri]);
    },
  );

  test(
    '5000 local probes have bounded concurrency and one overall deadline with late results ignored',
    () async {
      final gate = Completer<bool>();
      final songs = List.generate(
        PlaylistTransferCodec.maxSongs,
        (i) => Song(
          uri: Uri.file('D:/probe/$i.mp3', windows: true),
          fileName: '$i.mp3',
        ),
      );
      var running = 0, peak = 0;
      final files = _Files()
        ..importBytes = _encoded(songs: songs)
        ..exists = (_) async {
          running++;
          if (running > peak) peak = running;
          try {
            return await gate.future;
          } finally {
            running--;
          }
        };
      final document = await PlaylistTransfer(
        files: files,
        localProbeTimeout: const Duration(milliseconds: 5),
      ).importPlaylist(canCommit: () => true);
      expect(peak, PlaylistTransfer.localProbeConcurrency);
      expect(files.probed.length, PlaylistTransfer.localProbeConcurrency);
      expect(document!.songs.length, PlaylistTransferCodec.maxSongs);
      expect(document.songs.every((song) => song.isMissing), isTrue);
      gate.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(files.probed.length, PlaylistTransfer.localProbeConcurrency);
      expect(document.songs.every((song) => song.isMissing), isTrue);
    },
  );

  test(
    'write timeout invalidates late commit and never reports success',
    () async {
      final files = _Files()..writeGate = Completer<void>();
      final transfer = PlaylistTransfer(
        files: files,
        ioTimeout: const Duration(milliseconds: 5),
      );
      await expectLater(
        transfer.exportPlaylist(
          name: 'test',
          songs: [_local],
          canCommit: () => true,
        ),
        throwsA(isA<TimeoutException>()),
      );
      files.writeGate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(files.commits, 0);
    },
  );

  test(
    'exit during export write invalidates final user-visible commit',
    () async {
      final files = _Files()..writeGate = Completer<void>();
      var active = true;
      final pending = PlaylistTransfer(
        files: files,
      ).exportPlaylist(name: 'test', songs: [_online], canCommit: () => active);
      await Future<void>.delayed(Duration.zero);
      active = false;
      files.writeGate!.complete();
      expect(await pending, isNull);
      expect(files.commits, 0);
    },
  );
}

class _Files implements PlaylistTransferFiles {
  String? importPath = 'input.json';
  String? exportPath = 'output.hanmusic.json';
  Completer<String?>? importGate;
  Completer<List<int>>? readGate;
  Completer<void>? writeGate;
  List<int>? importBytes;
  Future<bool> Function(Uri)? exists;
  final probed = <Uri>[];
  int reads = 0, writes = 0, commits = 0, exportPicks = 0;
  @override
  Future<String?> pickImport() async =>
      importGate == null ? importPath : await importGate!.future;
  @override
  Future<String?> pickExport(String suggestedFileName) async {
    exportPicks++;
    return exportPath;
  }

  @override
  Future<List<int>> read(String filePath, int maxBytes) async {
    reads++;
    return readGate == null
        ? importBytes ?? _encoded()
        : await readGate!.future;
  }

  @override
  Future<bool> localFileExists(Uri uri) async {
    probed.add(uri);
    return exists == null ? false : await exists!(uri);
  }

  @override
  Future<String> write(
    String filePath,
    List<int> bytes, {
    required bool Function() canCommit,
  }) async {
    writes++;
    await writeGate?.future;
    if (!canCommit()) throw const PlaylistTransferCanceled();
    commits++;
    return filePath;
  }
}
