import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/music_recognition.dart';
import 'package:han_music/app/data/repositories/music_recognition_repository.dart';

const _privateResponse = 'private-response provider-secret';
final _audio = Uint8List.fromList([
  82,
  73,
  70,
  70,
  0,
  255,
  13,
  10,
  87,
  65,
  86,
  69,
]);

void main() {
  test(
    'real HTTP uploads only raw WAV bytes without provider credentials',
    () async {
      late String method;
      late Uri uri;
      late HttpHeaders headers;
      late List<int> uploaded;
      final api = await _Loopback.start((request) async {
        method = request.method;
        uri = request.uri;
        headers = request.headers;
        uploaded = await request.fold<List<int>>(
          [],
          (all, part) => all..addAll(part),
        );
        await _respond(request, _match);
      });
      addTearDown(api.close);
      final repository = MusicRecognitionRepository(endpoint: api.endpoint);
      addTearDown(repository.close);
      expect(repository.isConfigured, isTrue);
      final result = await _recognize(repository);
      expect(method, 'POST');
      expect(uri.path, '/v1/recognize');
      expect(uri.hasQuery, isFalse);
      expect(headers.contentType!.mimeType, 'audio/wav');
      expect(headers.contentType!.parameters, isEmpty);
      expect(headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(headers.value('x-api-key'), isNull);
      expect(headers.value('api_token'), isNull);
      expect(headers.toString(), isNot(contains('multipart')));
      expect(uploaded, _audio);
      expect(
        ascii.decode(uploaded, allowInvalid: true),
        isNot(contains('api_token')),
      );
      expect(headers.contentLength, uploaded.length);
      expect(result!.title, '夜航');
      expect(result.artist, '测试歌手');
      expect(result.album, '夜间专辑');
      expect(result.releaseDate, '2026-10-29');
      expect(result.songLink, isNull);
    },
  );

  test(
    'a successful null result is no match; missing result is invalid',
    () async {
      var withResult = true;
      final api = await _Loopback.start((request) async {
        await request.drain<void>();
        await _respond(
          request,
          withResult
              ? {'status': 'success', 'result': null}
              : {'status': 'success'},
        );
      });
      addTearDown(api.close);
      final repository = MusicRecognitionRepository(endpoint: api.endpoint);
      addTearDown(repository.close);
      expect(await _recognize(repository), isNull);
      withResult = false;
      await expectLater(_recognize(repository), _safeFailure(contains('数据无效')));
    },
  );

  test('oversized or empty audio never opens HTTP', () async {
    final api = await _Loopback.start((request) async {
      await request.drain<void>();
      await _respond(request, _match);
    });
    addTearDown(api.close);
    final repository = MusicRecognitionRepository(endpoint: api.endpoint);
    addTearDown(repository.close);
    for (final audio in [
      Uint8List(0),
      Uint8List(MusicRecognitionRepository.maxAudioBytes + 1),
    ]) {
      await expectLater(
        repository.recognize(
          audio: audio,
          cancellation: RecognitionCancellation(),
        ),
        _safeFailure(contains('录音')),
      );
    }
    expect(api.requests, 0);
  });

  test(
    'an unconfigured build reports unavailable without touching HTTP',
    () async {
      final client = _FailingClient();
      final repository = MusicRecognitionRepository(client: client);
      addTearDown(repository.close);
      expect(repository.isConfigured, isFalse);
      await expectLater(
        _recognize(repository),
        _safeFailure(equals('识曲服务暂未开通，请稍后重试。')),
      );
      expect(client.requests, 0);
    },
  );

  test(
    'invalid endpoints disable the service without throwing at startup',
    () async {
      for (final url in [
        '',
        '/v1/recognize',
        'http://recognition.example.com/v1/recognize',
        'https://recognition.example.com/',
        'https://recognition.example.com/v1/recognize?api_token=secret',
        'https://recognition.example.com/v1/recognize?',
        'https://recognition.example.com/v1/recognize#fragment',
        'https://user:secret@recognition.example.com/v1/recognize',
        'http://localhost/v1/recognize',
        'https://localhost/v1/recognize',
        'https://music.local/v1/recognize',
        'https://10.0.0.1/v1/recognize',
        'http://192.168.0.1/v1/recognize',
        'https://169.254.169.254/v1/recognize',
        'https://[fc00::1]/v1/recognize',
        'https://[2001:db8::1]/v1/recognize',
        'http://user@127.0.0.1/v1/recognize',
        'http://127.0.0.1/v1/recognize?url=https://example.com/audio.wav',
        'http://127.0.0.1/v1/recognize#fragment',
        'https://recognition.example.com:0/v1/recognize',
        'https://recognition.example.com:65536/v1/recognize',
      ]) {
        final client = _FailingClient();
        final repository = MusicRecognitionRepository(
          client: client,
          endpoint: Uri.parse(url),
        );
        addTearDown(repository.close);
        expect(repository.isConfigured, isFalse, reason: url);
        await expectLater(
          _recognize(repository),
          _safeFailure(equals('识曲服务暂未开通，请稍后重试。')),
        );
        expect(client.requests, 0);
      }
    },
  );

  test(
    'configuration accepts public HTTPS and literal loopback test overrides',
    () {
      for (final url in [
        'https://recognition.example.com/v1/recognize',
        'https://8.8.8.8/v1/recognize',
        'https://[2606:4700:4700::1111]/v1/recognize',
        'http://127.0.0.1:1234/v1/recognize',
        'http://[::1]:1234/v1/recognize',
        'https://127.0.0.1:1234/v1/recognize',
      ]) {
        final repository = MusicRecognitionRepository(endpoint: Uri.parse(url));
        expect(repository.isConfigured, isTrue, reason: url);
        repository.close();
      }
      expect(
        () => MusicRecognitionRepository(timeout: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => MusicRecognitionRepository(timeout: const Duration(seconds: 31)),
        throwsArgumentError,
      );
    },
  );

  test(
    'HTTP and backend error codes expose friendly messages without raw details',
    () async {
      var status = 200;
      String? code;
      final api = await _Loopback.start((request) async {
        await request.drain<void>();
        await _respond(
          request,
          code == null
              ? _privateResponse
              : {
                  'status': 'error',
                  'error': {
                    'code': code,
                    'message': '$_privateResponse AudD Token',
                  },
                },
          status: status,
        );
      });
      addTearDown(api.close);
      final repository = MusicRecognitionRepository(endpoint: api.endpoint);
      addTearDown(repository.close);
      for (final entry in {
        503: '未开通',
        429: '频繁',
        400: '录音',
        504: '超时',
        502: '暂时',
        401: '暂时',
        500: '暂时',
      }.entries) {
        status = entry.key;
        await expectLater(
          _recognize(repository),
          _safeFailure(contains(entry.value)),
        );
      }
      status = 200;
      for (final entry in {
        'service_unavailable': '未开通',
        'rate_limited': '频繁',
        'daily_limit': '今日',
        'invalid_audio': '录音',
        'upstream_timeout': '超时',
        'upstream_failure': '暂时',
        'unknown-private-code': '暂时',
      }.entries) {
        code = entry.key;
        await expectLater(
          _recognize(repository),
          _safeFailure(contains(entry.value)),
        );
      }
      status = 429;
      code = 'daily_limit';
      await expectLater(_recognize(repository), _safeFailure(contains('明天')));
    },
  );

  test('redirects do not send audio to the redirect target', () async {
    final target = await _Loopback.start((request) async {
      await request.drain<void>();
      await _respond(request, _match);
    });
    final api = await _Loopback.start((request) async {
      await request.drain<void>();
      request.response.statusCode = 307;
      request.response.headers.set(HttpHeaders.locationHeader, target.endpoint);
      await request.response.close();
    });
    addTearDown(api.close);
    addTearDown(target.close);
    final repository = MusicRecognitionRepository(endpoint: api.endpoint);
    addTearDown(repository.close);
    await expectLater(_recognize(repository), _safeFailure(contains('连接异常')));
    expect(target.requests, 0);
  });

  for (final withLength in [false, true]) {
    test(
      'response limit rejects oversized ${withLength ? 'declared' : 'chunked'} bodies',
      () async {
        final api = await _Loopback.start((request) async {
          await request.drain<void>();
          final bytes = List<int>.filled(
            MusicRecognitionRepository.maxResponseBytes + 1,
            0x20,
          );
          if (withLength) request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        });
        addTearDown(api.close);
        final repository = MusicRecognitionRepository(endpoint: api.endpoint);
        addTearDown(repository.close);
        await expectLater(
          _recognize(repository),
          _safeFailure(contains('响应过大')),
        );
      },
    );
  }

  test(
    'bounded decoding rejects malformed, deeply nested or unsafe metadata',
    () async {
      var response = <int>[];
      final api = await _Loopback.start((request) async {
        await request.drain<void>();
        request.response.add(response);
        await request.response.close();
      });
      addTearDown(api.close);
      final repository = MusicRecognitionRepository(endpoint: api.endpoint);
      addTearDown(repository.close);
      final invalidBodies = [
        utf8.encode(_privateResponse),
        [0xff, 0xfe],
        utf8.encode('${'[' * 30}0${']' * 30}'),
        utf8.encode(jsonEncode(List<int>.filled(5000, 0))),
        utf8.encode(jsonEncode({'status': 'success', 'result': []})),
        for (final invalid in [
          {..._track, 'title': 'x' * 513},
          {..._track, 'title': 'hidden\u202econtrol'},
          {..._track, 'artist': 'line\ncontrol'},
          {..._track, 'title': ''},
          {..._track, 'artist': null},
          {..._track, 'album': 123},
          {..._track, 'release_date': 'x' * 33},
        ])
          utf8.encode(jsonEncode({'status': 'success', 'result': invalid})),
      ];
      for (final body in invalidBodies) {
        response = body;
        await expectLater(
          _recognize(repository),
          _safeFailure(contains('数据无效')),
        );
      }
    },
  );

  test(
    'uncontracted links are ignored while optional metadata may be absent',
    () async {
      var link = '';
      final api = await _Loopback.start((request) async {
        await request.drain<void>();
        await _respond(request, {
          'status': 'success',
          'result': {'title': '夜航', 'artist': '测试歌手', 'song_link': link},
        });
      });
      addTearDown(api.close);
      final repository = MusicRecognitionRepository(endpoint: api.endpoint);
      addTearDown(repository.close);
      for (final unsafe in [
        'javascript:alert(1)',
        'file:///D:/private',
        'http://lis.tn/example',
        'https://user:password@lis.tn/example',
        'https://example.com/private-response',
        'https://lis.tn/space here',
        'https://lis.tn/\\evil',
        'x' * 2049,
      ]) {
        link = unsafe;
        final result = await _recognize(repository);
        expect(result!.title, '夜航');
        expect(result.songLink, isNull);
        expect(result.album, isNull);
        expect(result.releaseDate, isNull);
      }
    },
  );

  test(
    'pre-cancelled attempts make no request and cancellation is idempotent',
    () async {
      final api = await _Loopback.start((request) async {
        await request.drain<void>();
        await _respond(request, _match);
      });
      addTearDown(api.close);
      final repository = MusicRecognitionRepository(endpoint: api.endpoint);
      addTearDown(repository.close);
      final signal = RecognitionCancellation()
        ..cancel()
        ..cancel();
      await signal.whenCancelled;
      expect(signal.isCancelled, isTrue);
      await expectLater(_recognize(repository, signal), _cancelledFailure);
      expect(api.requests, 0);
    },
  );

  test(
    'active cancellation discards a late response and permits a fresh attempt',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final oldHandlerDone = Completer<void>();
      var first = true;
      final api = await _Loopback.start((request) async {
        await request.drain<void>();
        if (first) {
          first = false;
          request.response.write('{"status":');
          await request.response.flush();
          started.complete();
          await release.future;
          try {
            request.response.write('"success","result":null}');
            await request.response.close();
          } finally {
            oldHandlerDone.complete();
          }
        } else {
          await _respond(request, _match);
        }
      });
      addTearDown(api.close);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final repository = MusicRecognitionRepository(endpoint: api.endpoint);
      addTearDown(repository.close);
      final signal = RecognitionCancellation();
      final pending = _recognize(repository, signal);
      final cancelled = expectLater(pending, _cancelledFailure);
      await started.future;
      signal.cancel();
      await cancelled;
      final fresh = await _recognize(repository);
      expect(fresh!.title, '夜航');
      release.complete();
      await oldHandlerDone.future;
      expect(api.requests, 2);
    },
  );

  for (final partialBody in [false, true]) {
    test(
      'one deadline covers ${partialBody ? 'a stalled response body' : 'waiting for headers'}',
      () async {
        final release = Completer<void>();
        final api = await _Loopback.start((request) async {
          await request.drain<void>();
          if (partialBody) {
            request.response.write('{"status":');
            await request.response.flush();
          }
          await release.future;
          await request.response.close();
        });
        addTearDown(api.close);
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final repository = MusicRecognitionRepository(
          endpoint: api.endpoint,
          timeout: const Duration(milliseconds: 150),
        );
        addTearDown(repository.close);
        await expectLater(_recognize(repository), _safeFailure(contains('超时')));
        release.complete();
      },
    );
  }

  test('close cancels in-flight work and rejects later calls', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final api = await _Loopback.start((request) async {
      await request.drain<void>();
      started.complete();
      await release.future;
      await _respond(request, _match);
    });
    addTearDown(api.close);
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final repository = MusicRecognitionRepository(endpoint: api.endpoint);
    addTearDown(repository.close);
    final pending = _recognize(repository);
    final cancelled = expectLater(pending, _cancelledFailure);
    await started.future;
    repository.close();
    repository.close();
    await cancelled;
    await expectLater(_recognize(repository), _cancelledFailure);
    release.complete();
    expect(api.requests, 1);
  });

  test('transport exceptions cannot expose internal messages', () async {
    final client = _FailingClient();
    final repository = MusicRecognitionRepository(
      client: client,
      endpoint: Uri.parse('https://recognition.example.com/v1/recognize'),
    );
    await expectLater(_recognize(repository), _safeFailure(contains('网络')));
    repository.close();
    expect(client.closed, isTrue);
  });
}

const _track = {
  'title': '夜航',
  'artist': '测试歌手',
  'album': '夜间专辑',
  'release_date': '2026-10-29',
};
const _match = {'status': 'success', 'result': _track};

Future<MusicRecognitionResult?> _recognize(
  MusicRecognitionRepository repository, [
  RecognitionCancellation? cancellation,
]) => repository.recognize(
  audio: _audio,
  cancellation: cancellation ?? RecognitionCancellation(),
);

Matcher _safeFailure(Matcher message) => throwsA(
  isA<MusicRecognitionException>()
      .having(
        (error) => error.message,
        'safe message',
        allOf(
          message,
          isNot(contains('AudD')),
          isNot(contains('Token')),
          isNot(contains('provider-secret')),
          isNot(contains('private-response')),
        ),
      )
      .having(
        (error) => error.toString(),
        'safe display',
        isNot(contains(_privateResponse)),
      ),
);
final _cancelledFailure = throwsA(
  isA<MusicRecognitionException>().having(
    (error) => error.cancelled,
    'cancelled',
    isTrue,
  ),
);

Future<void> _respond(
  HttpRequest request,
  Object? body, {
  int status = 200,
}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

class _Loopback {
  _Loopback(this.server);
  final HttpServer server;
  int requests = 0;
  Uri get endpoint => Uri.parse('http://127.0.0.1:${server.port}/v1/recognize');

  static Future<_Loopback> start(
    Future<void> Function(HttpRequest) handle,
  ) async {
    final api = _Loopback(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    api.server.listen((request) async {
      api.requests++;
      try {
        await handle(request);
      } on SocketException {
        // Expected when the client aborts a cancelled or bounded request.
      } on HttpException {
        // Expected when the client stops a streamed response.
      }
    });
    return api;
  }

  Future<void> close() async {
    await server.close(force: true);
  }
}

class _FailingClient implements HttpClient {
  bool closed = false;
  int requests = 0;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    requests++;
    throw const SocketException(_privateResponse);
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
