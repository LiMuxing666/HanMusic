import 'dart:convert';

class UnsupportedOnlineSourceVersion extends FormatException {
  const UnsupportedOnlineSourceVersion() : super('网络源配置版本较新，当前版本无法读取。');
}

/// Schema 1 supports anonymous GET JSON APIs, never scripts or credentials.
class OnlineSourceConfig {
  const OnlineSourceConfig._({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.timeoutSeconds,
    required this.search,
    required this.playback,
  });
  final String id;
  final String name;
  final Uri baseUrl;
  final int timeoutSeconds;
  final OnlineSearchConfig search;
  final OnlinePlaybackConfig playback;

  factory OnlineSourceConfig.fromJsonText(String text) {
    if (utf8.encode(text).length > 64 * 1024) {
      throw const FormatException('网络源配置过大。');
    }
    final Object? value;
    try {
      value = jsonDecode(text);
    } catch (_) {
      throw const FormatException('网络源配置不是有效 JSON。');
    }
    return OnlineSourceConfig.fromJson(_object(value));
  }

  factory OnlineSourceConfig.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is int && version > 1) {
      throw const UnsupportedOnlineSourceVersion();
    }
    if (version != 1) throw const FormatException('网络源 schemaVersion 必须为 1。');
    _keys(json, {
      'schemaVersion',
      'id',
      'name',
      'baseUrl',
      'timeoutSeconds',
      'search',
      'playback',
    });
    final id = _text(json, 'id', max: 64);
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('源 ID 仅支持英文字母、数字、下划线和短横线。');
    }
    final rawBase = _text(json, 'baseUrl', max: 2048);
    final Uri base;
    try {
      final parsed = Uri.parse(rawBase);
      if (!{'http', 'https'}.contains(parsed.scheme) ||
          parsed.host.isEmpty ||
          parsed.userInfo.isNotEmpty ||
          parsed.authority.contains('@') ||
          RegExp(
            r'^https?://[^/?#]*@',
            caseSensitive: false,
          ).hasMatch(rawBase) ||
          parsed.hasQuery ||
          parsed.hasFragment ||
          parsed.port < 1 ||
          parsed.port > 65535 ||
          rawBase.contains('\\')) {
        throw const FormatException();
      }
      base = parsed.path.endsWith('/')
          ? parsed
          : parsed.replace(path: '${parsed.path}/');
    } catch (_) {
      throw const FormatException('Base URL 必须是无账号、查询参数和片段的 HTTP(S) 地址。');
    }
    return OnlineSourceConfig._(
      id: id,
      name: _text(json, 'name', max: 80),
      baseUrl: base,
      timeoutSeconds: _integer(
        json,
        'timeoutSeconds',
        fallback: 10,
        min: 1,
        max: 30,
      ),
      search: OnlineSearchConfig.fromJson(_object(json['search'])),
      playback: OnlinePlaybackConfig.fromJson(_object(json['playback'])),
    );
  }

  Uri endpoint(String path, Map<String, String> parameters) {
    final target = baseUrl.resolve(path);
    if (target.scheme != baseUrl.scheme ||
        target.host != baseUrl.host ||
        target.port != baseUrl.port) {
      throw const FormatException('API 端点必须与 Base URL 同源。');
    }
    return target.replace(queryParameters: parameters);
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'name': name,
    'baseUrl': baseUrl.toString(),
    'timeoutSeconds': timeoutSeconds,
    'search': search.toJson(),
    'playback': playback.toJson(),
  };
}

class OnlineSearchConfig {
  const OnlineSearchConfig._({
    required this.path,
    required this.queryParameter,
    required this.pageParameter,
    required this.limitParameter,
    required this.firstPage,
    required this.pageSize,
    required this.itemsPath,
    required this.fields,
    this.hasMorePath,
  });
  final String path;
  final String queryParameter;
  final String pageParameter;
  final String limitParameter;
  final int firstPage;
  final int pageSize;
  final String itemsPath;
  final OnlineTrackFields fields;
  final String? hasMorePath;

  factory OnlineSearchConfig.fromJson(Map<String, dynamic> json) {
    _keys(json, {
      'path',
      'queryParameter',
      'pageParameter',
      'limitParameter',
      'firstPage',
      'pageSize',
      'itemsPath',
      'fields',
      'hasMorePath',
    });
    final query = _parameter(json, 'queryParameter', 'q');
    final page = _parameter(json, 'pageParameter', 'page');
    final limit = _parameter(json, 'limitParameter', 'limit');
    if ({query, page, limit}.length != 3) {
      throw const FormatException('搜索、页码和分页大小的参数名不能重复。');
    }
    return OnlineSearchConfig._(
      path: _endpointPath(json),
      queryParameter: query,
      pageParameter: page,
      limitParameter: limit,
      firstPage: _integer(json, 'firstPage', fallback: 1, min: 0, max: 10000),
      pageSize: _integer(json, 'pageSize', fallback: 20, min: 1, max: 100),
      itemsPath: _fieldPath(json, 'itemsPath')!,
      fields: OnlineTrackFields.fromJson(_object(json['fields'])),
      hasMorePath: _fieldPath(json, 'hasMorePath', optional: true),
    );
  }
  Map<String, Object?> toJson() => {
    'path': path,
    'queryParameter': queryParameter,
    'pageParameter': pageParameter,
    'limitParameter': limitParameter,
    'firstPage': firstPage,
    'pageSize': pageSize,
    'itemsPath': itemsPath,
    'fields': fields.toJson(),
    if (hasMorePath != null) 'hasMorePath': hasMorePath,
  };
}

class OnlineTrackFields {
  const OnlineTrackFields._({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    this.durationSeconds,
  });
  final String id;
  final String title;
  final String? artist;
  final String? album;
  final String? durationSeconds;
  factory OnlineTrackFields.fromJson(Map<String, dynamic> json) {
    _keys(json, {'id', 'title', 'artist', 'album', 'durationSeconds'});
    return OnlineTrackFields._(
      id: _fieldPath(json, 'id')!,
      title: _fieldPath(json, 'title')!,
      artist: _fieldPath(json, 'artist', optional: true),
      album: _fieldPath(json, 'album', optional: true),
      durationSeconds: _fieldPath(json, 'durationSeconds', optional: true),
    );
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    if (artist != null) 'artist': artist,
    if (album != null) 'album': album,
    if (durationSeconds != null) 'durationSeconds': durationSeconds,
  };
}

class OnlinePlaybackConfig {
  const OnlinePlaybackConfig._({
    required this.path,
    required this.idParameter,
    required this.urlPath,
  });
  final String path;
  final String idParameter;
  final String urlPath;
  factory OnlinePlaybackConfig.fromJson(Map<String, dynamic> json) {
    _keys(json, {'path', 'idParameter', 'urlPath'});
    return OnlinePlaybackConfig._(
      path: _endpointPath(json),
      idParameter: _parameter(json, 'idParameter', 'id'),
      urlPath: _fieldPath(json, 'urlPath')!,
    );
  }
  Map<String, Object?> toJson() => {
    'path': path,
    'idParameter': idParameter,
    'urlPath': urlPath,
  };
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('网络源配置缺少有效对象。');
  }
  return value;
}

void _keys(Map<String, dynamic> json, Set<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('配置含不支持的字段；当前仅支持匿名 GET，不支持鉴权、Header 或脚本。');
  }
}

String _text(Map<String, dynamic> json, String key, {int max = 256}) {
  final value = json[key];
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > max ||
      value.contains(RegExp(r'[\x00-\x1F]'))) {
    throw const FormatException('网络源配置包含缺失或无效的文本字段。');
  }
  return value.trim();
}

int _integer(
  Map<String, dynamic> json,
  String key, {
  required int fallback,
  required int min,
  required int max,
}) {
  final value = json[key] ?? fallback;
  if (value is! int || value < min || value > max) {
    throw const FormatException('网络源数值配置超出允许范围。');
  }
  return value;
}

String _parameter(Map<String, dynamic> json, String key, String fallback) {
  final value = json[key] == null ? fallback : _text(json, key, max: 64);
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_-]*$').hasMatch(value)) {
    throw const FormatException('查询参数名格式无效。');
  }
  return value;
}

String _endpointPath(Map<String, dynamic> json) {
  final value = _text(json, 'path', max: 1024);
  try {
    var decoded = value;
    for (var index = 0; index < 3 && decoded.contains('%'); index++) {
      decoded = Uri.decodeComponent(decoded);
    }
    final uri = Uri.parse(value);
    if (uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment ||
        decoded.contains('%') ||
        decoded.startsWith('//') ||
        decoded.contains(RegExp(r'[\\?#]')) ||
        decoded
            .split('/')
            .any((segment) => segment == '.' || segment == '..')) {
      throw const FormatException();
    }
    return value;
  } catch (_) {
    throw const FormatException('API 端点必须是同源相对路径，不能包含跳转、查询或片段。');
  }
}

String? _fieldPath(
  Map<String, dynamic> json,
  String key, {
  bool optional = false,
}) {
  if (optional && json[key] == null) return null;
  final value = _text(json, key, max: 128);
  final segments = value.split('.');
  if (segments.length > 12 ||
      segments.any(
        (segment) => !RegExp(
          r'^(?:[A-Za-z_][A-Za-z0-9_-]*|0|[1-9][0-9]{0,5})$',
        ).hasMatch(segment),
      )) {
    throw const FormatException('字段路径仅支持点分对象键和数字数组索引，例如 data.items.0.id。');
  }
  return value;
}
