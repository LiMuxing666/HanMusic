import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:han_music/app/core/theme/app_theme.dart';
import 'package:han_music/app/data/models/playlist.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/data/repositories/playlist_transfer.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/view.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import 'support/fake_audio_backend.dart';

final _local = Song(
  uri: Uri.file('D:/library/known.mp3', windows: true),
  fileName: 'known.mp3',
  trackTitle: '本地歌曲',
);
final _unknown = Song(
  uri: Uri.file('D:/another/unknown.mp3', windows: true),
  fileName: 'unknown.mp3',
  trackTitle: '未入库歌曲',
  isMissing: true,
);
final _online = Song.online(
  sourceId: 'missing-source',
  trackId: 'track-1',
  title: '在线歌曲',
  artist: '歌手',
);
List<int> _document({String name = '旅行', List<Song>? songs}) =>
    PlaylistTransferCodec.encode(
      name: name,
      songs: songs ?? [_unknown, _online],
    );

void main() {
  testWidgets(
    'imports a new numbered mixed playlist without changing favorites library or queue',
    (tester) async {
      await _withPlayer(tester, (fixture) async {
        final existing = fixture.controller.createPlaylist('旅行');
        fixture.controller.addSongsToPlaylist(existing.id, [_local]);
        fixture.controller.toggleFavorite(_local);
        await tester.pumpAndSettle();
        await _tap(tester, 'playlist-import');
        expect(
          find.byKey(const Key('playlist-import-preview')),
          findsOneWidget,
        );
        expect(fixture.controller.playlists.playlists.length, 2);
        await _tap(tester, 'playlist-import-confirm');
        final imported = fixture.controller.playlists.playlists.last;
        expect(imported.name, '旅行 (2)');
        expect(imported.id, isNot(existing.id));
        expect(imported.songs.map((song) => song.id), [
          _unknown.id,
          _online.id,
        ]);
        expect(
          fixture.controller.playlists.findById(existing.id)!.songs.single.id,
          _local.id,
        );
        expect(
          fixture.controller.playlists
              .findById(Playlist.favoritesId)!
              .songs
              .single
              .id,
          _local.id,
        );
        expect(fixture.library.songs.map((song) => song.id), [_local.id]);
        expect(fixture.player.queue, isEmpty);
        expect(find.textContaining('已导入“旅行 (2)”'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'exports selected favorites using injected location and stable song identities',
    (tester) async {
      await _withPlayer(tester, (fixture) async {
        fixture.controller.addSongsToPlaylist(Playlist.favoritesId, [
          _local,
          _online,
        ]);
        await tester.pumpAndSettle();
        await _tap(tester, 'playlist-export');
        expect(fixture.files.suggestedName, 'HanMusic-我喜欢.hanmusic.json');
        final document = PlaylistTransferCodec.decode(
          fixture.files.savedBytes!,
        );
        expect(document.name, Playlist.favoritesName);
        expect(document.songs.map((song) => song.id), [_local.id, _online.id]);
        expect(fixture.files.commits, 1);
        expect(
          find.textContaining('已导出到：D:/exports/test.hanmusic.json'),
          findsOneWidget,
        );
        expect(fixture.player.queue, isEmpty);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets('canceling either dialog has no playlist or file side effects', (
    tester,
  ) async {
    await _withPlayer(tester, (fixture) async {
      fixture.files.importPath = null;
      fixture.files.exportPath = null;
      final before = fixture.snapshot;
      await _tap(tester, 'playlist-import');
      await _tap(tester, 'playlist-export');
      expect(fixture.snapshot, before);
      expect(fixture.files.reads, 0);
      expect(fixture.files.writes, 0);
      expect(fixture.files.commits, 0);
    });
  });

  testWidgets(
    'future malformed duplicate and oversized imports never create a partial playlist',
    (tester) async {
      await _withPlayer(tester, (fixture) async {
        final future =
            jsonDecode(utf8.decode(_document())) as Map<String, dynamic>;
        future['version'] = 99;
        final duplicate =
            jsonDecode(utf8.decode(_document())) as Map<String, dynamic>;
        (duplicate['playlist']['songs'] as List).add(
          duplicate['playlist']['songs'][0],
        );
        final before = fixture.snapshot;
        for (final bytes in [
          utf8.encode('{bad'),
          utf8.encode(jsonEncode(future)),
          utf8.encode(jsonEncode(duplicate)),
          List<int>.filled(PlaylistTransferCodec.maxFileBytes + 1, 32),
        ]) {
          fixture.files.importBytes = bytes;
          await _tap(tester, 'playlist-import');
          expect(fixture.snapshot, before);
          expect(find.byKey(const Key('playlist-notice')), findsOneWidget);
        }
        expect(fixture.player.queue, isEmpty);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'pending picker disables controls and exit-cancel invalidates its late response',
    (tester) async {
      await _withPlayer(tester, (fixture) async {
        final gate = Completer<String?>();
        fixture.files.importGate = gate;
        await _start(tester, 'playlist-import');
        expect(find.byKey(const Key('playlist-transfer-busy')), findsOneWidget);
        for (final key in [
          'playlist-import',
          'playlist-export',
          'playlist-export-m3u8',
          'playlist-create',
        ]) {
          expect(
            tester.widget<TextButton>(find.byKey(Key(key))).onPressed,
            isNull,
          );
        }
        expect(
          tester
              .widget<PopupMenuButton<String>>(
                find.byKey(const Key('playlist-select')),
              )
              .enabled,
          isFalse,
        );
        fixture.controller.beginExit();
        fixture.controller.cancelExit();
        gate.complete('late.json');
        await tester.pumpAndSettle();
        expect(fixture.files.reads, 0);
        expect(fixture.controller.playlists.playlists.length, 1);
        expect(find.byKey(const Key('playlist-transfer-busy')), findsNothing);
        fixture.files.importGate = null;
        await _tap(tester, 'playlist-import');
        await _tap(tester, 'playlist-import-confirm');
        expect(fixture.controller.playlists.playlists.length, 2);
      });
    },
  );

  testWidgets('controller closure during read cannot append a late playlist', (
    tester,
  ) async {
    await _withPlayer(tester, (fixture) async {
      final gate = Completer<List<int>>();
      fixture.files.readGate = gate;
      await _start(tester, 'playlist-import');
      expect(fixture.files.reads, 1);
      fixture.controller.onDelete();
      gate.complete(_document());
      await tester.pumpAndSettle();
      expect(fixture.controller.playlists.playlists.length, 1);
      expect(find.textContaining('已导入'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'exit-cancel during local existence checks cannot commit a partial or late playlist',
    (tester) async {
      await _withPlayer(tester, (fixture) async {
        final gate = Completer<bool>();
        fixture.files.existsGate = gate;
        final before = fixture.snapshot;
        await _start(tester, 'playlist-import');
        expect(fixture.files.probed, [_unknown.uri]);
        expect(fixture.snapshot, before);
        fixture.controller.beginExit();
        fixture.controller.cancelExit();
        gate.complete(true);
        await tester.pumpAndSettle();
        expect(fixture.snapshot, before);
        expect(find.textContaining('已导入'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'unmount during read cancels its late commit without setState after dispose',
    (tester) async {
      await _withPlayer(tester, (fixture) async {
        final gate = Completer<List<int>>();
        fixture.files.readGate = gate;
        await _start(tester, 'playlist-import');
        await tester.pumpWidget(const SizedBox.shrink());
        gate.complete(_document());
        await tester.pumpAndSettle();
        expect(fixture.controller.playlists.playlists.length, 1);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'exit-cancel during export write prevents a late user file and success notice',
    (tester) async {
      await _withPlayer(tester, (fixture) async {
        final gate = Completer<void>();
        fixture.files.writeGate = gate;
        await _start(tester, 'playlist-export');
        expect(fixture.files.writes, 1);
        fixture.controller.beginExit();
        fixture.controller.cancelExit();
        gate.complete();
        await tester.pumpAndSettle();
        expect(fixture.files.commits, 0);
        expect(find.textContaining('已导出到'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'M3U preview reports skipped duplicate and missing entries before any mutation',
    (tester) async {
      await _withPlayer(tester, (fixture) async {
        fixture.files.importPath = 'D:/lists/旅行.m3u8';
        fixture.files.importBytes = utf8.encode(
          '#EXTM3U\n'
          r'..\library\known.mp3'
          '\n'
          'D:/another/missing.flac\nD:/LIBRARY/KNOWN.MP3\n'
          'https://example.invalid/remote.mp3\nnested.m3u8\n',
        );
        final before = fixture.snapshot;
        await _tap(tester, 'playlist-import');
        expect(
          find.byKey(const Key('playlist-import-preview')),
          findsOneWidget,
        );
        expect(find.text('格式：M3U8 · UTF-8'), findsOneWidget);
        expect(find.textContaining('已合并 1 条重复路径'), findsOneWidget);
        expect(find.textContaining('已跳过 2 条网络地址'), findsOneWidget);
        expect(find.textContaining('缺失 2 首'), findsOneWidget);
        expect(fixture.snapshot, before);
        expect(fixture.player.queue, isEmpty);
        await _tap(tester, 'playlist-import-cancel');
        expect(fixture.snapshot, before);
        await _tap(tester, 'playlist-import');
        await _tap(tester, 'playlist-import-confirm');
        final imported = fixture.controller.playlists.playlists.last;
        expect(imported.name, '旅行');
        expect(imported.songs.map((song) => song.id), [
          _local.id,
          Uri.file(
            'D:/another/missing.flac',
            windows: true,
          ).toString().toLowerCase(),
        ]);
        expect(imported.songs.last.isMissing, isTrue);
        expect(fixture.library.songs.map((song) => song.id), [_local.id]);
        expect(fixture.files.probed.length, 4);
        expect(
          fixture.files.probed.every((uri) => uri.scheme == 'file'),
          isTrue,
        );
        expect(fixture.player.queue, isEmpty);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'exit-cancel while preview is open invalidates its later confirmation',
    (tester) async {
      await _withPlayer(tester, (fixture) async {
        final before = fixture.snapshot;
        await _tap(tester, 'playlist-import');
        expect(
          find.byKey(const Key('playlist-import-preview')),
          findsOneWidget,
        );
        fixture.controller.beginExit();
        fixture.controller.cancelExit();
        await _tap(tester, 'playlist-import-confirm');
        expect(fixture.snapshot, before);
        expect(find.textContaining('已导入'), findsNothing);
        expect(find.byKey(const Key('playlist-transfer-busy')), findsNothing);
      });
    },
  );

  testWidgets(
    'mixed M3U8 export asks before filtering online songs and keeps local paths',
    (tester) async {
      await _withPlayer(tester, (fixture) async {
        fixture.controller.addSongsToPlaylist(Playlist.favoritesId, [
          _local,
          _online,
        ]);
        fixture.files.exportPath = 'D:/exports/list.m3u8';
        await tester.pumpAndSettle();
        await _tap(tester, 'playlist-export-m3u8');
        expect(find.textContaining('跳过 1 首在线歌曲'), findsOneWidget);
        expect(fixture.files.writes, 0);
        await _tap(tester, 'playlist-export-cancel');
        expect(fixture.files.writes, 0);
        await _tap(tester, 'playlist-export-m3u8');
        await _tap(tester, 'playlist-export-confirm');
        expect(fixture.files.suggestedName, 'HanMusic-我喜欢.m3u8');
        final document = PlaylistTransferCodec.decode(
          fixture.files.savedBytes!,
          sourcePath: 'D:/exports/list.m3u8',
        );
        expect(document.songs.map((song) => song.id), [_local.id]);
        expect(fixture.files.commits, 1);
        expect(find.textContaining('已跳过 1 条'), findsOneWidget);
        expect(fixture.controller.playlists.playlists.single.songs.length, 2);
        expect(fixture.player.queue, isEmpty);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'online-only M3U8 export does not open a picker or write a file',
    (tester) async {
      await _withPlayer(tester, (fixture) async {
        fixture.controller.addSongsToPlaylist(Playlist.favoritesId, [_online]);
        await tester.pumpAndSettle();
        await _tap(tester, 'playlist-export-m3u8');
        expect(find.textContaining('没有可导出的本地音频'), findsOneWidget);
        expect(fixture.files.suggestedName, isNull);
        expect(fixture.files.writes, 0);
      });
    },
  );

  testWidgets(
    'exit-cancel in the mixed export confirmation prevents its late write',
    (tester) async {
      await _withPlayer(tester, (fixture) async {
        fixture.controller.addSongsToPlaylist(Playlist.favoritesId, [
          _local,
          _online,
        ]);
        await tester.pumpAndSettle();
        await _tap(tester, 'playlist-export-m3u8');
        fixture.controller.beginExit();
        fixture.controller.cancelExit();
        await _tap(tester, 'playlist-export-confirm');
        expect(fixture.files.suggestedName, isNull);
        expect(fixture.files.writes, 0);
        expect(find.textContaining('已导出到'), findsNothing);
      });
    },
  );

  testWidgets('import preview stays usable at compact 200 percent scale', (
    tester,
  ) async {
    await _withPlayer(
      tester,
      (fixture) async {
        await _tap(tester, 'playlist-import');
        expect(
          find.byKey(const Key('playlist-import-preview')),
          findsOneWidget,
        );
        await _tap(tester, 'playlist-import-cancel');
        expect(fixture.controller.playlists.playlists.length, 1);
        expect(tester.takeException(), isNull);
      },
      size: const Size(800, 600),
      scale: 2,
    );
  });

  testWidgets(
    'transfer actions remain reachable in compact 200 percent layout',
    (tester) async {
      await _withPlayer(
        tester,
        (fixture) async {
          fixture.files.importPath = null;
          fixture.files.exportPath = null;
          await _tap(tester, 'playlist-import');
          await _tap(tester, 'playlist-export');
          expect(tester.takeException(), isNull);
        },
        size: const Size(800, 600),
        scale: 2,
      );
    },
  );
}

Future<void> _start(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await _start(tester, key);
  await tester.pumpAndSettle();
}

Future<void> _withPlayer(
  WidgetTester tester,
  Future<void> Function(_Fixture) run, {
  Size size = const Size(1280, 1000),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixture = _Fixture();
  Get.put<PlaylistTransferFiles>(fixture.files);
  fixture.controller.onStart();
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: HanMusicTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: PlayerPage(controller: fixture.controller),
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'nav-4');
    await run(fixture);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.controller.onDelete();
    fixture.timer.onClose();
    fixture.library.onClose();
    await Get.delete<PlaylistTransferFiles>(force: true);
    await tester.runAsync(fixture.player.shutdown);
  }
}

class _Fixture {
  _Fixture() {
    library.replaceAll([_local]);
    controller = PlayerController(
      player: player,
      timer: timer,
      picker: _Picker(),
      library: library,
    );
  }
  final files = _Files();
  final backend = FakeAudioBackend();
  late final player = PlayerService(backend);
  late final timer = TimerService(onExpired: player.pause);
  final library = LibraryService(
    repository: LocalLibraryRepository(
      artworkDirectory: Directory('build/test-transfer-artwork'),
    ),
  );
  late final PlayerController controller;
  List<Object?> get snapshot =>
      controller.playlists.playlists.map((value) => value.toJson()).toList();
}

class _Picker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}

class _Files implements PlaylistTransferFiles {
  String? importPath = 'test.json';
  String? exportPath = 'D:/exports/test.hanmusic.json';
  List<int> importBytes = _document();
  List<int>? savedBytes;
  String? suggestedName;
  Completer<String?>? importGate;
  Completer<List<int>>? readGate;
  Completer<void>? writeGate;
  Completer<bool>? existsGate;
  final probed = <Uri>[];
  int reads = 0, writes = 0, commits = 0;
  @override
  Future<String?> pickImport() async =>
      importGate == null ? importPath : await importGate!.future;
  @override
  Future<String?> pickExport(String suggestedFileName) async {
    suggestedName = suggestedFileName;
    return exportPath;
  }

  @override
  Future<List<int>> read(String filePath, int maxBytes) async {
    reads++;
    return readGate == null ? importBytes : await readGate!.future;
  }

  @override
  Future<bool> localFileExists(Uri uri) async {
    probed.add(uri);
    return existsGate == null ? false : await existsGate!.future;
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
    savedBytes = List.of(bytes);
    commits++;
    return filePath;
  }
}
