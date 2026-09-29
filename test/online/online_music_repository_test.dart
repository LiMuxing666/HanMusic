import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/online_source_config.dart';
import 'package:han_music/app/data/repositories/online_music_repository.dart';

import 'online_test_support.dart';

void main() {
  final repository = OnlineMusicRepository();

  test(
    'real HTTP maps nested fields encodes query and resolves memory-only URLs',
    () async {
      final api = await LoopbackApi.start((request) async {
        if (request.uri.path == '/play') {
          await respond(request, {
            'data': {'url': 'https://cdn.invalid/stream?token=private'},
          });
        } else {
          await respond(
            request,
            apiPage([
              apiTrack('id /? 中文'),
              apiTrack(42),
              apiTrack(42),
              {'id': '..'},
              apiTrack('\u0000'),
            ], more: true),
          );
        }
      });
      addTearDown(api.close);
      final config = source(baseUrl: api.base.toString());
      final page = await repository.search(config, '中文 & + / ?', 0);
      expect(page.songs.length, 2);
      expect(page.skippedItems, 2);
      expect(page.songs.first.artist, '歌手');
      expect(page.songs.first.album, '专辑');
      expect(page.songs.first.duration, const Duration(milliseconds: 2500));
      expect(page.hasMore, isTrue);
      expect(api.requests.first.queryParameters, {
        'keyword': '中文 & + / ?',
        'p': '0',
        'size': '2',
      });
      final url = await repository.resolve(config, page.songs.first.trackId!);
      expect(url.queryParameters['token'], 'private');
      expect(api.requests.last.queryParameters['track'], 'id /? 中文');
      expect(
        page.songs.first.toJson().toString(),
        isNot(contains('cdn.invalid')),
      );
    },
  );

  test(
    'empty page stops pagination and inferred paging follows page size',
    () async {
      final api = await LoopbackApi.start(
        (request) => respond(
          request,
          apiPage(
            request.uri.queryParameters['p'] == '0'
                ? [apiTrack(1), apiTrack(2)]
                : [],
            more: true,
          ),
        ),
      );
      addTearDown(api.close);
      final json = sourceJson(baseUrl: api.base.toString());
      (json['search'] as Map).remove('hasMorePath');
      final config = OnlineSourceConfig.fromJson(json);
      expect((await repository.search(config, 'x', 0)).hasMore, isTrue);
      expect((await repository.search(config, 'x', 1)).hasMore, isFalse);
    },
  );

  test('malformed mapping and bad JSON report safe categories', () async {
    final api = await LoopbackApi.start((request) async {
      switch (request.uri.queryParameters['keyword']) {
        case 'missing':
          await respond(request, {'private-secret': 'body'});
        case 'invalid':
          await respond(
            request,
            apiPage([
              {'id': 1},
            ]),
          );
        case 'more':
          await respond(request, {
            'data': {
              'items': [apiTrack(1)],
              'more': 'true',
            },
          });
        default:
          request.response.write('private-secret not JSON');
          await request.response.close();
      }
    });
    addTearDown(api.close);
    final config = source(baseUrl: api.base.toString());
    for (final keyword in ['missing', 'invalid', 'more', 'json']) {
      await expectLater(
        repository.search(config, keyword, 0),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.message,
            'safe',
            allOf(
              isNot(contains('private-secret')),
              isNot(contains(api.base.toString())),
            ),
          ),
        ),
      );
    }
  });

  test('API redirects are refused without contacting the target', () async {
    var redirected = false;
    final target = await LoopbackApi.start((request) async {
      redirected = true;
      await respond(request, apiPage([]));
    });
    final api = await LoopbackApi.start((request) async {
      request.response.statusCode = 302;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        target.base.resolve('leak').toString(),
      );
      await request.response.close();
    });
    addTearDown(api.close);
    addTearDown(target.close);
    await expectLater(
      repository.search(source(baseUrl: api.base.toString()), 'private', 0),
      throwsA(
        isA<OnlineMusicException>().having(
          (error) => error.message,
          'redirect',
          contains('重定向'),
        ),
      ),
    );
    expect(redirected, isFalse);
  });

  test(
    'authentication and service status do not expose response bodies or retry',
    () async {
      final api = await LoopbackApi.start(
        (request) => respond(
          request,
          'secret',
          status: int.parse(request.uri.queryParameters['keyword']!),
        ),
      );
      addTearDown(api.close);
      for (final status in [401, 403, 429, 500]) {
        await expectLater(
          repository.search(source(baseUrl: api.base.toString()), '$status', 0),
          throwsA(isA<OnlineMusicException>()),
        );
      }
      expect(api.requests.length, 4);
    },
  );

  test(
    'total timeout includes a stalled response body and terminates request',
    () async {
      final release = Completer<void>();
      final api = await LoopbackApi.start((request) async {
        request.response.write('[');
        await request.response.flush();
        await release.future;
        await request.response.close();
      });
      addTearDown(() async {
        release.complete();
        await api.close();
      });
      final watch = Stopwatch()..start();
      await expectLater(
        repository.search(source(baseUrl: api.base.toString()), 'x', 0),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.message,
            'timeout',
            contains('超时'),
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(api.requests.length, 1);
    },
  );

  test(
    'cancellation terminates before a timeout rather than merely discarding UI',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final api = await LoopbackApi.start((request) async {
        started.complete();
        await release.future;
        await request.response.close();
      });
      addTearDown(() async {
        release.complete();
        await api.close();
      });
      final cancellation = OnlineRequestCancellation();
      final work = repository.search(
        source(baseUrl: api.base.toString()),
        'x',
        0,
        cancellation: cancellation,
      );
      final expectation = expectLater(
        work,
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.cancelled,
            'cancelled',
            isTrue,
          ),
        ),
      );
      await started.future;
      cancellation.cancel();
      await expectation.timeout(const Duration(milliseconds: 500));
    },
  );

  test('actual streamed response bytes are capped at 2 MiB', () async {
    final api = await LoopbackApi.start((request) async {
      request.response.write(
        '"${'x' * OnlineMusicRepository.maxResponseBytes}"',
      );
      await request.response.close();
    });
    addTearDown(api.close);
    await expectLater(
      repository.search(source(baseUrl: api.base.toString()), 'x', 0),
      throwsA(
        isA<OnlineMusicException>().having(
          (error) => error.message,
          'cap',
          contains('过大'),
        ),
      ),
    );
  });

  test(
    'playback URL rejects credentials protocols invalid ports and fragments',
    () async {
      var value = '';
      final api = await LoopbackApi.start(
        (request) => respond(request, {
          'data': {'url': value},
        }),
      );
      addTearDown(api.close);
      for (final bad in [
        'file:///D:/secret',
        'https://user:secret@cdn.test/x',
        'http://@cdn.test/x',
        'https://cdn.test:99999/x',
        'https://cdn.test/x#private',
        'https://cdn.test\\x',
        '/relative.mp3',
      ]) {
        value = bad;
        await expectLater(
          repository.resolve(source(baseUrl: api.base.toString()), '1'),
          throwsA(isA<OnlineMusicException>()),
          reason: bad,
        );
      }
    },
  );
}
