import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/online_source_config.dart';
import 'package:han_music/app/data/repositories/online_music_repository.dart';

import '../tool/online_fixture_server.dart';

void main() {
  late OnlineFixtureServer server;
  late HttpClient client;
  setUp(() async {
    server = await OnlineFixtureServer.start();
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
  });

  test(
    'documented example searches pages and resolves generated audio',
    () async {
      final json =
          jsonDecode(
                await File(
                  'doc/examples/online-source.local.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      json['baseUrl'] = server.baseUrl.toString();
      final source = OnlineSourceConfig.fromJson(json);
      final repository = OnlineMusicRepository();
      final first = await repository.search(source, 'test', 1);
      final last = await repository.search(source, 'test', 2);
      expect(first.songs.length, 2);
      expect(first.hasMore, true);
      expect(last.songs.length, 1);
      expect(last.hasMore, false);
      final uri = await repository.resolve(source, first.songs.first.trackId!);
      final response = await (await client.getUrl(uri)).close();
      final bytes = await response.fold<List<int>>(
        [],
        (result, next) => result..addAll(next),
      );
      expect(response.statusCode, 200);
      expect(bytes, server.audio);
      expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
    },
  );

  test('native range and HEAD clients get correct boundaries', () async {
    final source = OnlineSourceConfig.fromJson(server.configJson());
    final uri = await OnlineMusicRepository().resolve(source, 'tone-a');
    final head = await (await client.openUrl('HEAD', uri)).close();
    expect(head.contentLength, server.audio.length);
    expect(
      await head.fold<int>(0, (length, bytes) => length + bytes.length),
      0,
    );
    for (final range in ['bytes=4-7', 'bytes=-4', 'bytes=999999999-']) {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close();
      final bytes = await response.fold<List<int>>(
        [],
        (result, next) => result..addAll(next),
      );
      if (range == 'bytes=999999999-') {
        expect(response.statusCode, 416);
        expect(
          response.headers.value(HttpHeaders.contentRangeHeader),
          'bytes */${server.audio.length}',
        );
      } else {
        expect(response.statusCode, 206);
        expect(
          bytes,
          range == 'bytes=4-7'
              ? server.audio.sublist(4, 8)
              : server.audio.sublist(server.audio.length - 4),
        );
      }
    }
  });

  test('expired fixture address needs a new resolution', () async {
    final repository = OnlineMusicRepository();
    final source = OnlineSourceConfig.fromJson(server.configJson());
    final first = await repository.resolve(source, 'refresh');
    final rejected = await (await client.getUrl(first)).close();
    expect(rejected.statusCode, 403);
    await rejected.drain<void>();
    final second = await repository.resolve(source, 'refresh');
    final accepted = await (await client.getUrl(second)).close();
    expect(accepted.statusCode, 200);
    expect(second, isNot(first));
    await accepted.drain<void>();
  });
}
