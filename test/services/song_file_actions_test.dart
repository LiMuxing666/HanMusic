import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/services/song_file_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('hanmusic/desktop_media');
  final calls = <MethodCall>[];
  late Directory directory;
  late Song local;
  final online = Song.online(
    sourceId: 'source',
    trackId: 'track',
    title: '在线歌曲',
  );
  setUp(() async {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    directory = await Directory.systemTemp.createTemp('hanmusic-file-actions-');
    final file = File('${directory.path}/音乐 & (demo).mp3');
    await file.writeAsBytes([1, 2, 3, 4]);
    local = Song(uri: file.uri, fileName: '音乐 & (demo).mp3');
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test('details stat local files without modifying or opening audio', () async {
    final actions = SongFileActions();
    final info = (await actions.inspect(local))!;
    expect(info.exists, isTrue);
    expect(info.bytes, 4);
    expect(await actions.inspect(online), isNull);
    await File.fromUri(local.uri).delete();
    expect((await actions.inspect(local))!.exists, isFalse);
  });

  test(
    'reveal sends the complete literal path to native file selection',
    () async {
      final actions = SongFileActions(isWindows: true, channel: channel);
      await actions.reveal(local);
      expect(calls.single.method, 'revealFile');
      expect(calls.single.arguments, local.path);
      expect(await File.fromUri(local.uri).readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test(
    'missing, online and unsupported platform never send file selection',
    () async {
      final actions = SongFileActions(isWindows: true, channel: channel);
      await expectLater(
        actions.reveal(online),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        SongFileActions(isWindows: false, channel: channel).reveal(local),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        actions.reveal(local.copyWith(isMissing: true)),
        throwsA(isA<FileSystemException>()),
      );
      await File.fromUri(local.uri).delete();
      await expectLater(
        actions.reveal(local),
        throwsA(isA<FileSystemException>()),
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'native rejection and unavailable channel surface a file action error',
    () async {
      final actions = SongFileActions(isWindows: true, channel: channel);
      for (final response in [
        false,
        null,
        PlatformException(code: 'reveal_failed'),
        MissingPluginException(),
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async {
          if (response is Exception) throw response;
          return response;
        });
        await expectLater(
          actions.reveal(local),
          throwsA(isA<FileSystemException>()),
        );
      }
      expect(await File.fromUri(local.uri).readAsBytes(), [1, 2, 3, 4]);
    },
  );
}
