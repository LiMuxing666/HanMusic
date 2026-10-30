import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/music_recognition.dart';

/// Uploads one recording to the configured first-party recognition service.
/// No provider credentials are present in the client or sent with the audio.
class MusicRecognitionRepository {
  MusicRecognitionRepository({
    HttpClient? client,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 30),
  }) : _injectedClient = client,
       _endpoint = _checkedEndpoint(endpoint) {
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 30)) {
      throw ArgumentError('识别超时必须大于零且不超过 30 秒。');
    }
  }

  static const maxAudioBytes = 8 * 1024 * 1024;
  static const maxResponseBytes = 1024 * 1024;
  static const _configuredUrl = String.fromEnvironment(
    'HANMUSIC_RECOGNITION_URL',
  );
  static const _unavailable = MusicRecognitionException('识曲服务暂未开通，请稍后重试。');
  static const _serviceFailure = MusicRecognitionException(
    '识曲服务暂时无法完成识别，请稍后重试。',
  );
  static const _cancelled = MusicRecognitionException(
    '识别已取消。',
    cancelled: true,
  );
  static const _invalidResponse = MusicRecognitionException(
    '识别服务返回的数据无效，请稍后重试。',
  );

  final Duration timeout;
  final HttpClient? _injectedClient;
  final Uri? _endpoint;
  final _active = <_RecognitionOperation>{};
  bool _closed = false;

  bool get isConfigured => _endpoint != null;

  Future<MusicRecognitionResult?> recognize({
    required Uint8List audio,
    required RecognitionCancellation cancellation,
  }) async {
    if (_closed || cancellation.isCancelled) throw _cancelled;
    if (!isConfigured) throw _unavailable;
    if (audio.isEmpty) {
      throw const MusicRecognitionException('没有可识别的录音，请重新录制。');
    }
    if (audio.length > maxAudioBytes) {
      throw const MusicRecognitionException('录音超过 8 MiB 上限，请缩短录音后重试。');
    }

    final client = _injectedClient ?? HttpClient();
    final operation = _RecognitionOperation(
      client,
      ownsClient: _injectedClient == null,
    );
    _active.add(operation);
    final cancellationListener = cancellation.whenCancelled.asStream().listen(
      (_) => operation.stop(_cancelled),
    );
    final timer = Timer(timeout, () {
      operation.stop(const MusicRecognitionException('识别请求超时，请检查网络后重试。'));
    });
    try {
      client.connectionTimeout = timeout;
      final result = await Future.any<MusicRecognitionResult?>([
        _perform(operation, Uint8List.fromList(audio)),
        operation.stopped.future,
      ]);
      // Cancellation can arrive after the body completed but before its result
      // reaches this caller. Never publish that stale successful response.
      if (_closed || cancellation.isCancelled) throw _cancelled;
      operation.ensureActive();
      return result;
    } on MusicRecognitionException {
      if (_closed || cancellation.isCancelled) throw _cancelled;
      if (operation.failure case final failure?) throw failure;
      rethrow;
    } catch (_) {
      if (_closed || cancellation.isCancelled) throw _cancelled;
      if (operation.failure case final failure?) throw failure;
      throw const MusicRecognitionException('无法完成识别请求，请检查网络后重试。');
    } finally {
      timer.cancel();
      unawaited(cancellationListener.cancel());
      _active.remove(operation);
      operation.dispose();
    }
  }

  Future<MusicRecognitionResult?> _perform(
    _RecognitionOperation operation,
    Uint8List audio,
  ) async {
    operation.ensureActive();
    final request = await operation.client.postUrl(_endpoint!);
    operation.request = request;
    // getUrl can complete after cancellation. Consume done before aborting so
    // a late transport failure cannot become an unhandled asynchronous error.
    unawaited(
      request.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    if (operation.isFinished) {
      request.abort(_cancelled);
      operation.ensureActive();
    }
    request.followRedirects = false;
    request.maxRedirects = 0;
    request.persistentConnection = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.contentTypeHeader, 'audio/wav');
    request.contentLength = audio.length;
    request.add(audio);
    final response = await request.close();
    operation.ensureActive();
    final reader = StreamIterator<List<int>>(response);
    operation.reader = reader;
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw _httpError(response.statusCode);
    }
    if (response.contentLength > maxResponseBytes) {
      throw const MusicRecognitionException('识别服务响应过大，已停止读取。');
    }
    final body = BytesBuilder(copy: false);
    while (await reader.moveNext()) {
      operation.ensureActive();
      final bytes = reader.current;
      if (body.length + bytes.length > maxResponseBytes) {
        throw const MusicRecognitionException('识别服务响应过大，已停止读取。');
      }
      body.add(bytes);
    }
    operation.ensureActive();
    return _parse(body.takeBytes(), response.statusCode);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final operation in _active.toList()) {
      operation.stop(_cancelled);
    }
    _injectedClient?.close(force: true);
  }

  static Uri? _checkedEndpoint(Uri? override) {
    try {
      final raw = override?.toString() ?? _configuredUrl;
      if (raw.isEmpty ||
          raw.length > 2048 ||
          RegExp(r'[\\\x00-\x20\x7f]').hasMatch(raw)) {
        return null;
      }
      final uri = override ?? Uri.tryParse(raw);
      if (uri == null ||
          uri.host.isEmpty ||
          uri.path != '/v1/recognize' ||
          uri.userInfo.isNotEmpty ||
          uri.authority.contains('@') ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.port < 1 ||
          uri.port > 65535) {
        return null;
      }
      final address = InternetAddress.tryParse(uri.host);
      // The constructor override alone may use literal loopback HTTP(S) for
      // local tests. A build-time URL must always be a public HTTPS endpoint.
      if (override != null &&
          address?.isLoopback == true &&
          {'http', 'https'}.contains(uri.scheme)) {
        return uri;
      }
      if (uri.scheme != 'https' || !_publicHost(uri.host, address)) return null;
      return uri;
    } catch (_) {
      // A missing or malformed build configuration must not prevent startup.
      return null;
    }
  }

  static bool _publicHost(String host, InternetAddress? address) {
    if (address != null) {
      final bytes = address.rawAddress;
      if (address.type == InternetAddressType.IPv4) {
        return !(bytes[0] == 0 ||
            bytes[0] == 10 ||
            bytes[0] == 127 ||
            bytes[0] >= 224 ||
            (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) ||
            (bytes[0] == 169 && bytes[1] == 254) ||
            (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
            (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 192 &&
                bytes[1] == 0 &&
                (bytes[2] == 0 || bytes[2] == 2)) ||
            (bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)) ||
            (bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100) ||
            (bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113));
      }
      return bytes.length == 16 &&
          (bytes[0] & 0xe0) == 0x20 &&
          !(bytes[0] == 0x20 &&
              bytes[1] == 0x01 &&
              bytes[2] == 0x0d &&
              bytes[3] == 0xb8);
    }
    final labels = host.toLowerCase().split('.');
    if (labels.length < 2 ||
        host.length > 253 ||
        {
          'localhost',
          'local',
          'internal',
          'lan',
          'home',
          'invalid',
          'test',
        }.contains(labels.last)) {
      return false;
    }
    return labels.every(
          (label) =>
              label.length <= 63 &&
              RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
        ) &&
        !RegExp(r'^\d+$').hasMatch(labels.last);
  }

  static MusicRecognitionException _httpError(int status) => switch (status) {
    503 => _unavailable,
    429 => _backendError('rate_limited'),
    400 || 413 || 415 => _backendError('invalid_audio'),
    504 => _backendError('upstream_timeout'),
    >= 300 && < 400 => const MusicRecognitionException('识曲服务连接异常，请稍后重试。'),
    _ => _serviceFailure,
  };

  static MusicRecognitionException _backendError(Object? code) =>
      switch (code) {
        'service_unavailable' => _unavailable,
        'rate_limited' => const MusicRecognitionException('识曲请求过于频繁，请稍后重试。'),
        'daily_limit' => const MusicRecognitionException('今日识曲次数已达上限，请明天再试。'),
        'invalid_audio' => const MusicRecognitionException(
          '无法识别这段录音，请重新录制清晰的音乐片段。',
        ),
        'upstream_timeout' => const MusicRecognitionException(
          '识曲服务响应超时，请稍后重试。',
        ),
        _ => _serviceFailure,
      };

  static MusicRecognitionResult? _parse(Uint8List bytes, int statusCode) {
    final Object? decoded;
    try {
      final text = utf8.decode(bytes, allowMalformed: false);
      _checkJsonComplexity(text);
      decoded = jsonDecode(text);
    } catch (_) {
      if (statusCode != HttpStatus.ok) throw _httpError(statusCode);
      throw _invalidResponse;
    }
    if (decoded is! Map<String, dynamic>) {
      if (statusCode != HttpStatus.ok) throw _httpError(statusCode);
      throw _invalidResponse;
    }
    if (decoded['status'] == 'error') {
      final error = decoded['error'];
      final code = error is Map<String, dynamic> ? error['code'] : null;
      // Only the documented code is consumed, never arbitrary backend text.
      throw _backendError(code);
    }
    if (statusCode != HttpStatus.ok) throw _httpError(statusCode);
    if (decoded['status'] != 'success' || !decoded.containsKey('result')) {
      throw _invalidResponse;
    }
    final result = decoded['result'];
    if (result == null) return null;
    if (result is! Map<String, dynamic>) throw _invalidResponse;
    final title = _text(result['title'], maximum: 512);
    final artist = _text(result['artist'], maximum: 512);
    if (title == null || artist == null) throw _invalidResponse;
    return MusicRecognitionResult(
      title: title,
      artist: artist,
      album: _text(result['album'], maximum: 1024),
      releaseDate: _text(result['release_date'], maximum: 32),
    );
  }

  static String? _text(Object? raw, {required int maximum}) {
    if (raw == null) return null;
    if (raw is! String ||
        raw.length > maximum ||
        RegExp(
          r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',
        ).hasMatch(raw)) {
      throw _invalidResponse;
    }
    final text = raw.trim();
    return text.isEmpty ? null : text;
  }

  static void _checkJsonComplexity(String text) {
    var depth = 0;
    var structuralTokens = 0;
    var inString = false;
    var escaped = false;
    for (final unit in text.codeUnits) {
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (unit == 0x5c) {
          escaped = true;
        } else if (unit == 0x22) {
          inString = false;
        }
        continue;
      }
      if (unit == 0x22) {
        inString = true;
      } else if (unit == 0x7b || unit == 0x5b) {
        depth++;
        structuralTokens++;
        if (depth > 16) throw _invalidResponse;
      } else if (unit == 0x7d || unit == 0x5d) {
        depth--;
        if (depth < 0) throw _invalidResponse;
      } else if (unit == 0x2c || unit == 0x3a) {
        structuralTokens++;
      }
      if (structuralTokens > 4096) throw _invalidResponse;
    }
  }
}

class _RecognitionOperation {
  _RecognitionOperation(this.client, {required this.ownsClient});

  final HttpClient client;
  final bool ownsClient;
  final stopped = Completer<MusicRecognitionResult?>();
  HttpClientRequest? request;
  StreamIterator<List<int>>? reader;
  MusicRecognitionException? failure;
  bool _disposed = false;
  bool get isFinished => _disposed || failure != null;

  void ensureActive() {
    if (isFinished) {
      throw failure ?? MusicRecognitionRepository._cancelled;
    }
  }

  void stop(MusicRecognitionException reason) {
    if (isFinished) return;
    failure = reason;
    stopped.completeError(reason);
    _abort();
  }

  void _abort() {
    request?.abort(failure ?? MusicRecognitionRepository._cancelled);
    if (reader case final activeReader?) {
      unawaited(activeReader.cancel().catchError((Object _) {}));
    }
    if (ownsClient) client.close(force: true);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _abort();
  }
}
