import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/online_source_config.dart';
import '../models/song.dart';

class OnlineMusicException implements Exception {
  const OnlineMusicException(this.message, {this.cancelled = false});
  final String message;
  final bool cancelled;
  @override
  String toString() => message;
}

class OnlineRequestCancellation {
  final _completion = Completer<void>();
  bool get isCancelled => _completion.isCompleted;
  Future<void> get whenCancelled => _completion.future;
  void cancel() {
    if (!isCancelled) _completion.complete();
  }
}

class OnlineSearchPage {
  const OnlineSearchPage({
    required this.songs,
    required this.hasMore,
    this.skippedItems = 0,
  });
  final List<Song> songs;
  final bool hasMore;
  final int skippedItems;
}

/// One bounded request per action. Retries are explicit in the UI; playback
/// retries, if any, are owned by PlayerService rather than multiplied here.
class OnlineMusicRepository {
  static const maxResponseBytes = 2 * 1024 * 1024;

  Future<OnlineSearchPage> search(
    OnlineSourceConfig source,
    String query,
    int page, {
    OnlineRequestCancellation? cancellation,
  }) async {
    final search = source.search;
    final uri = source.endpoint(search.path, {
      search.queryParameter: query,
      search.pageParameter: '$page',
      search.limitParameter: '${search.pageSize}',
    });
    final body = await _getJson(source, uri, cancellation);
    final items = _at(body, search.itemsPath);
    if (items is! List) {
      throw const OnlineMusicException('搜索响应中找不到歌曲列表，请检查字段映射。');
    }
    final songs = <Song>[];
    final ids = <String>{};
    var skipped = 0;
    for (final item in items) {
      final rawId = _at(item, search.fields.id);
      final id = rawId is int
          ? '$rawId'
          : rawId is String
          ? rawId.trim()
          : null;
      final title = _optionalText(_at(item, search.fields.title));
      if (id == null ||
          id.isEmpty ||
          id.length > 512 ||
          id == '.' ||
          id == '..' ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(id) ||
          title == null) {
        skipped++;
        continue;
      }
      if (!ids.add(id)) continue;
      final seconds = _at(item, search.fields.durationSeconds);
      songs.add(
        Song.online(
          sourceId: source.id,
          trackId: id,
          title: title,
          artist: _optionalText(_at(item, search.fields.artist)),
          album: _optionalText(_at(item, search.fields.album)),
          duration:
              seconds is num &&
                  seconds.isFinite &&
                  seconds >= 0 &&
                  seconds <= 2592000
              ? Duration(milliseconds: (seconds * 1000).round())
              : null,
        ),
      );
    }
    if (items.isNotEmpty && songs.isEmpty) {
      throw const OnlineMusicException('搜索结果缺少有效歌曲 ID 或标题，请检查字段映射。');
    }
    final bool hasMore;
    if (search.hasMorePath != null) {
      final value = _at(body, search.hasMorePath);
      if (value is! bool) {
        throw const OnlineMusicException('分页标记不是布尔值，请检查字段映射。');
      }
      hasMore = value && items.isNotEmpty;
    } else {
      hasMore = items.length >= search.pageSize && items.isNotEmpty;
    }
    return OnlineSearchPage(
      songs: songs,
      hasMore: hasMore,
      skippedItems: skipped,
    );
  }

  Future<Uri> resolve(
    OnlineSourceConfig source,
    String trackId, {
    OnlineRequestCancellation? cancellation,
  }) async {
    final config = source.playback;
    final body = await _getJson(
      source,
      source.endpoint(config.path, {config.idParameter: trackId}),
      cancellation,
    );
    final raw = _at(body, config.urlPath);
    final uri = raw is String && raw.length <= 8192
        ? Uri.tryParse(raw.trim())
        : null;
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        (raw is String &&
            RegExp(
              r'^https?://[^/?#]*@',
              caseSensitive: false,
            ).hasMatch(raw.trim())) ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (raw is String && raw.contains(RegExp(r'[\\\x00-\x20\x7f]'))) ||
        uri.hasFragment) {
      throw const OnlineMusicException('播放地址无效；仅支持无账号信息的 HTTP(S) 地址。');
    }
    return uri;
  }

  Future<Object?> _getJson(
    OnlineSourceConfig source,
    Uri uri,
    OnlineRequestCancellation? cancellation,
  ) async {
    if (cancellation?.isCancelled == true) {
      throw const OnlineMusicException('请求已取消。', cancelled: true);
    }
    final client = HttpClient()
      ..connectionTimeout = Duration(seconds: source.timeoutSeconds);
    HttpClientRequest? request;
    Future<Object?> perform() async {
      request = await client.getUrl(uri);
      request!.followRedirects = false;
      request!.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request!.close();
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const OnlineMusicException('网络源返回重定向，请配置最终 API 地址。');
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const OnlineMusicException('该网络源需要鉴权；当前仅支持匿名公开服务。');
      }
      if (response.statusCode == 429) {
        throw const OnlineMusicException('网络源请求过于频繁，请稍后重试。');
      }
      if (response.statusCode != 200) {
        throw const OnlineMusicException('网络源返回服务错误，请稍后重试或检查配置。');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > maxResponseBytes) {
          throw const OnlineMusicException('网络源响应过大，已停止读取。');
        }
        bytes.addAll(chunk);
      }
      try {
        return jsonDecode(utf8.decode(bytes));
      } catch (_) {
        throw const OnlineMusicException('网络源响应不是有效 JSON。');
      }
    }

    try {
      final work = perform();
      final pending = cancellation == null
          ? work
          : Future.any<Object?>([
              work,
              cancellation.whenCancelled.then(
                (_) =>
                    throw const OnlineMusicException('请求已取消。', cancelled: true),
              ),
            ]);
      return await pending.timeout(Duration(seconds: source.timeoutSeconds));
    } on OnlineMusicException {
      rethrow;
    } on TimeoutException {
      throw const OnlineMusicException('网络源请求超时，请检查连接后重试。');
    } on HandshakeException {
      throw const OnlineMusicException('网络源安全连接失败，请检查服务证书。');
    } on SocketException {
      throw const OnlineMusicException('无法连接网络源，请检查网络和服务地址。');
    } catch (_) {
      throw const OnlineMusicException('网络请求失败，请稍后重试。');
    } finally {
      request?.abort();
      client.close(force: true);
    }
  }
}

Object? _at(Object? value, String? path) {
  if (path == null) return null;
  for (final segment in path.split('.')) {
    if (value is Map) {
      value = value[segment];
    } else if (value is List) {
      final index = int.tryParse(segment);
      if (index == null || index < 0 || index >= value.length) return null;
      value = value[index];
    } else {
      return null;
    }
  }
  return value;
}

String? _optionalText(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  final text = value.trim();
  return text.length > 512 ? text.substring(0, 512) : text;
}
