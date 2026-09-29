import 'dart:async';

import 'package:han_music/app/data/models/online_source_config.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/online_music_repository.dart';
import 'package:han_music/app/data/repositories/online_source_store.dart';

OnlineSourceConfig onlineTestSource({
  String id = 'demo',
  String name = '示例音乐源',
}) => OnlineSourceConfig.fromJson({
  'schemaVersion': 1,
  'id': id,
  'name': name,
  'baseUrl': 'https://music.example.test/',
  'search': {
    'path': 'search',
    'itemsPath': 'data.items',
    'fields': {'id': 'id', 'title': 'title'},
    'hasMorePath': 'data.hasMore',
  },
  'playback': {'path': 'play', 'urlPath': 'data.url'},
});

class MemoryOnlineSourceStore implements OnlineSourceStore {
  MemoryOnlineSourceStore({
    List<OnlineSourceConfig> sources = const [],
    String? selected,
  }) : snapshot = OnlineSourceSnapshot(
         sources: sources,
         selectedSourceId: selected,
       );
  OnlineSourceSnapshot snapshot;
  int saves = 0;
  int? failOnSave;
  @override
  String? warning;
  @override
  Future<OnlineSourceSnapshot> load() async => snapshot;
  @override
  Future<void> save(OnlineSourceSnapshot next) async {
    saves++;
    if (saves == failOnSave) throw StateError('测试写盘失败');
    snapshot = next;
  }
}

class FakeOnlineMusicRepository extends OnlineMusicRepository {
  final requests = <({String sourceId, String query, int page})>[];
  final gates = <String, Completer<OnlineSearchPage>>{};
  String? failure;
  List<Song> Function(String sourceId, String query, int page)? songsFor;
  bool hasMore = false;

  @override
  Future<OnlineSearchPage> search(
    OnlineSourceConfig source,
    String query,
    int page, {
    OnlineRequestCancellation? cancellation,
  }) async {
    requests.add((sourceId: source.id, query: query, page: page));
    final gate = gates[query];
    if (gate != null) return gate.future;
    if (failure != null) throw OnlineMusicException(failure!);
    return OnlineSearchPage(
      songs:
          songsFor?.call(source.id, query, page) ??
          [
            Song.online(
              sourceId: source.id,
              trackId: '$query-$page',
              title: '歌曲 $query $page',
              artist: '示例歌手',
              album: '示例专辑',
              duration: const Duration(minutes: 3),
            ),
          ],
      hasMore: hasMore && page == source.search.firstPage,
    );
  }

  @override
  Future<Uri> resolve(
    OnlineSourceConfig source,
    String trackId, {
    OnlineRequestCancellation? cancellation,
  }) async => Uri.parse('https://media.example.test/audio.mp3');
}
