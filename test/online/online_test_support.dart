import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:han_music/app/data/models/online_source_config.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/online_music_repository.dart';
import 'package:han_music/app/data/repositories/online_source_store.dart';

Map<String, dynamic> sourceJson({
  String id = 'demo',
  String? baseUrl,
  int timeout = 1,
}) => {
  'schemaVersion': 1,
  'id': id,
  'name': '测试源 $id',
  'baseUrl': baseUrl ?? 'http://127.0.0.1:1234/',
  'timeoutSeconds': timeout,
  'search': <String, dynamic>{
    'path': 'search',
    'queryParameter': 'keyword',
    'pageParameter': 'p',
    'limitParameter': 'size',
    'firstPage': 0,
    'pageSize': 2,
    'itemsPath': 'data.items',
    'hasMorePath': 'data.more',
    'fields': <String, dynamic>{
      'id': 'id',
      'title': 'info.0.title',
      'artist': 'artist',
      'album': 'album',
      'durationSeconds': 'seconds',
    },
  },
  'playback': <String, dynamic>{
    'path': 'play',
    'idParameter': 'track',
    'urlPath': 'data.url',
  },
};

OnlineSourceConfig source({String id = 'demo', String? baseUrl}) =>
    OnlineSourceConfig.fromJson(sourceJson(id: id, baseUrl: baseUrl));

Song onlineSong(String id, {String sourceId = 'demo'}) =>
    Song.online(sourceId: sourceId, trackId: id, title: '歌曲 $id');

Map<String, Object?> apiTrack(Object id, {String title = '测试歌曲'}) => {
  'id': id,
  'info': [
    {'title': title},
  ],
  'artist': '歌手',
  'album': '专辑',
  'seconds': 2.5,
};

Map<String, Object?> apiPage(List<Object?> items, {bool more = false}) => {
  'data': {'items': items, 'more': more},
};

Future<void> respond(
  HttpRequest request,
  Object? body, {
  int status = 200,
}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

class LoopbackApi {
  LoopbackApi._(this.server);
  final HttpServer server;
  final requests = <Uri>[];
  Uri get base => Uri.parse('http://127.0.0.1:${server.port}/');
  static Future<LoopbackApi> start(
    Future<void> Function(HttpRequest request) handle,
  ) async {
    final api = LoopbackApi._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    api.server.listen((request) async {
      api.requests.add(request.uri);
      try {
        await handle(request);
      } on SocketException {
        /* The client deliberately aborts timed-out requests. */
      } on HttpException {
        /* Likewise when the response cap closes the client. */
      }
    });
    return api;
  }

  Future<void> close() async {
    await server.close(force: true);
  }
}

class MemorySourceStore implements OnlineSourceStore {
  MemorySourceStore([this.snapshot = const OnlineSourceSnapshot()]);
  OnlineSourceSnapshot snapshot;
  bool failWrites = false;
  int writes = 0;
  Completer<void>? writeGate;
  Completer<void>? writeStarted;
  @override
  String? warning;
  @override
  Future<OnlineSourceSnapshot> load() async => snapshot;
  @override
  Future<void> save(OnlineSourceSnapshot value) async {
    writes++;
    if (writeStarted?.isCompleted == false) writeStarted!.complete();
    await writeGate?.future;
    if (failWrites) throw const FileSystemException('private disk detail');
    snapshot = value;
  }
}

class ControlledRepository extends OnlineMusicRepository {
  Future<OnlineSearchPage> Function(OnlineSourceConfig, String, int)? onSearch;
  Future<Uri> Function(OnlineSourceConfig, String)? onResolve;
  final queries = <String>[];
  final cancellations = <OnlineRequestCancellation?>[];
  @override
  Future<OnlineSearchPage> search(
    OnlineSourceConfig source,
    String query,
    int page, {
    OnlineRequestCancellation? cancellation,
  }) async {
    queries.add(query);
    cancellations.add(cancellation);
    return onSearch?.call(source, query, page) ??
        const OnlineSearchPage(songs: [], hasMore: false);
  }

  @override
  Future<Uri> resolve(
    OnlineSourceConfig source,
    String trackId, {
    OnlineRequestCancellation? cancellation,
  }) async {
    cancellations.add(cancellation);
    return onResolve?.call(source, trackId) ??
        Uri.parse('https://example.invalid/audio.mp3?temporary=token');
  }
}
