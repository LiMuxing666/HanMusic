// Anonymous loopback-only JSON API and generated audio for M4 diagnostics.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 8765 : int.tryParse(args.single);
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('Usage: dart run tool/online_fixture_server.dart [port]');
    exitCode = 2;
    return;
  }
  final fixture = await OnlineFixtureServer.start(port: port);
  stdout.writeln('HanMusic local fixture: ${fixture.baseUrl}');
  stdout.writeln(
    'Search: test, empty, error, unauthorized, malformed, timeout',
  );
  ProcessSignal.sigint.watch().listen((_) async {
    await fixture.close();
    exit(0);
  });
}

class OnlineFixtureServer {
  OnlineFixtureServer._(this._server) {
    _server.listen((request) => unawaited(_handle(request)));
  }
  final HttpServer _server;
  final resolveCounts = <String, int>{};
  final audioRequests = <String, int>{};
  final _tickets = <String, DateTime>{};
  final _delays = <Timer, Completer<void>>{};
  final audio = createFixtureWav();
  bool _closed = false;
  int searchCount = 0;
  int _serial = 0;

  static Future<OnlineFixtureServer> start({int port = 0}) async =>
      OnlineFixtureServer._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, port),
      );

  Uri get baseUrl => Uri.parse('http://127.0.0.1:${_server.port}/');

  Map<String, Object?> configJson({
    int pageSize = 2,
    int timeoutSeconds = 2,
  }) => {
    'schemaVersion': 1,
    'id': 'local-demo',
    'name': '本地测试源',
    'baseUrl': '$baseUrl',
    'timeoutSeconds': timeoutSeconds,
    'search': {
      'path': 'search',
      'queryParameter': 'q',
      'pageParameter': 'page',
      'limitParameter': 'limit',
      'firstPage': 1,
      'pageSize': pageSize,
      'itemsPath': 'data.items',
      'fields': {
        'id': 'id',
        'title': 'title',
        'artist': 'artist',
        'album': 'album',
        'durationSeconds': 'duration',
      },
      'hasMorePath': 'data.hasMore',
    },
    'playback': {'path': 'play', 'idParameter': 'id', 'urlPath': 'data.url'},
  };

  Future<void> _delay(Duration duration) async {
    final completer = Completer<void>();
    late final Timer timer;
    timer = Timer(duration, () {
      _delays.remove(timer);
      completer.complete();
    });
    _delays[timer] = completer;
    await completer.future;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
      } else if (request.uri.path == '/search') {
        searchCount++;
        final query = request.uri.queryParameters['q'] ?? '';
        if (query == 'timeout') await _delay(const Duration(seconds: 35));
        if (_closed) return;
        if (query == 'error' || query == 'unauthorized') {
          request.response.statusCode = query == 'error' ? 503 : 401;
          _json(request, {'error': 'controlled fixture failure'});
        } else if (query == 'malformed') {
          _json(request, {'wrong': []});
        } else {
          final all = query == 'empty'
              ? <Map<String, Object>>[]
              : [
                  {
                    'id': 'tone-a',
                    'title': '测试音 A',
                    'artist': 'HanMusic 测试',
                    'album': '本地生成',
                    'duration': 6,
                  },
                  {
                    'id': 'tone-b',
                    'title': '测试音 B',
                    'artist': 'HanMusic 测试',
                    'album': '本地生成',
                    'duration': 6,
                  },
                  {
                    'id': 'refresh',
                    'title': '过期地址重试测试',
                    'artist': 'HanMusic 测试',
                    'album': '本地生成',
                    'duration': 6,
                  },
                ];
          final page = math.max(
            1,
            int.tryParse(request.uri.queryParameters['page'] ?? '') ?? 1,
          );
          final limit =
              (int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 20)
                  .clamp(1, 100);
          final start = math.min(all.length, (page - 1) * limit);
          final end = math.min(all.length, start + limit);
          _json(request, {
            'data': {
              'items': all.sublist(start, end),
              'hasMore': end < all.length,
            },
          });
        }
      } else if (request.uri.path == '/play') {
        final id = request.uri.queryParameters['id'] ?? '';
        resolveCounts[id] = (resolveCounts[id] ?? 0) + 1;
        if (id == 'slow') await _delay(const Duration(milliseconds: 900));
        if (id == 'switch-slow') await _delay(const Duration(seconds: 3));
        if (_closed) return;
        final ticket = 'probe-only-${++_serial}';
        _tickets[ticket] = DateTime.now().add(const Duration(minutes: 1));
        final expired =
            id == 'broken' || (id == 'refresh' && resolveCounts[id] == 1);
        final url = baseUrl
            .resolve('audio/$id.wav')
            .replace(
              queryParameters: {
                'ticket': expired ? 'probe-only-expired' : ticket,
              },
            );
        _json(request, {
          'data': {'url': '$url'},
        });
      } else if (request.uri.path.startsWith('/audio/')) {
        final id = request.uri.pathSegments.last.replaceFirst('.wav', '');
        audioRequests[id] = (audioRequests[id] ?? 0) + 1;
        final expiry = _tickets[request.uri.queryParameters['ticket']];
        if (expiry == null || DateTime.now().isAfter(expiry)) {
          request.response.statusCode = HttpStatus.forbidden;
        } else {
          _serveAudio(request);
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    } catch (_) {
      // Timed-out clients may disconnect while the controlled delay finishes.
      try {
        await request.response.close();
      } catch (_) {
        /* Already closed. */
      }
    }
  }

  void _json(HttpRequest request, Object body) {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
  }

  void _serveAudio(HttpRequest request) {
    var start = 0;
    var end = audio.length - 1;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
      if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${audio.length}',
        );
        return;
      }
      if (match[1]!.isEmpty) {
        start = math.max(0, audio.length - (int.tryParse(match[2]!) ?? 0));
      } else {
        start = int.tryParse(match[1]!) ?? audio.length;
        if (match[2]!.isNotEmpty) {
          end = math.min(end, int.tryParse(match[2]!) ?? -1);
        }
      }
      if (start > end || start >= audio.length) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${audio.length}',
        );
        return;
      }
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${audio.length}',
      );
    }
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.contentType = ContentType('audio', 'wav');
    request.response.contentLength = end - start + 1;
    if (request.method != 'HEAD') {
      request.response.add(audio.sublist(start, end + 1));
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final entry in _delays.entries) {
      entry.key.cancel();
      entry.value.complete();
    }
    _delays.clear();
    await _server.close(force: true);
  }
}

Uint8List createFixtureWav({int seconds = 6}) {
  const rate = 22050;
  final length = seconds * rate;
  final bytes = Uint8List(44 + length * 2);
  final data = ByteData.sublistView(bytes);
  void label(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, ascii.encode(value));
  label(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  label(8, 'WAVE');
  label(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  label(36, 'data');
  data.setUint32(40, length * 2, Endian.little);
  for (var index = 0; index < length; index++) {
    data.setInt16(
      44 + index * 2,
      (math.sin(index * 2 * math.pi * 440 / rate) * 1000).round(),
      Endian.little,
    );
  }
  return bytes;
}
