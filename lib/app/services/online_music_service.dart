import 'dart:async';

import 'package:get/get.dart';

import '../data/models/online_source_config.dart';
import '../data/models/playback_source_exception.dart';
import '../data/models/song.dart';
import '../data/repositories/online_music_repository.dart';
import '../data/repositories/online_source_store.dart';

class OnlineMusicService extends GetxService {
  OnlineMusicService({
    required OnlineMusicRepository repository,
    required OnlineSourceStore store,
  }) : _repository = repository,
       _store = store;
  final OnlineMusicRepository _repository;
  final OnlineSourceStore _store;
  final sources = <OnlineSourceConfig>[].obs;
  final selectedSourceId = RxnString();
  final results = <Song>[].obs;
  final query = ''.obs;
  final isSearching = false.obs;
  final isLoadingMore = false.obs;
  final isTesting = false.obs;
  final hasMore = false.obs;
  final errorMessage = RxnString();
  final statusMessage = RxnString();
  Timer? _debounce;
  OnlineRequestCancellation? _searchCancellation;
  OnlineRequestCancellation? _testCancellation;
  final _resolveCancellations = <String, Set<OnlineRequestCancellation>>{};
  final _revisions = <String, int>{};
  int _searchSerial = 0;
  int _testSerial = 0;
  int _contextSerial = 0;
  int? _nextPage;
  String _searchedQuery = '';
  bool _closed = false;
  Future<void> _mutations = Future.value();
  Future<void>? _closeFuture;

  OnlineSourceConfig? get selectedSource => _source(selectedSourceId.value);
  OnlineSourceConfig? _source(String? id) {
    for (final source in sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  Future<void> initialize() async {
    if (_closed) return;
    try {
      final snapshot = await _store.load();
      if (_closed) return;
      sources.assignAll(snapshot.sources);
      selectedSourceId.value = snapshot.selectedSourceId;
      statusMessage.value = _store.warning;
    } catch (_) {
      if (!_closed) errorMessage.value = '读取网络源配置失败，请检查磁盘与权限。';
    }
  }

  Future<void> selectSource(String? id) {
    if (_closed) return Future.value();
    _invalidateContext();
    return _serialize(() async {
      if (_closed) return;
      if (id != null && _source(id) == null) {
        errorMessage.value = '所选网络源不存在，请重新选择。';
        return;
      }
      try {
        await _store.save(
          OnlineSourceSnapshot(sources: List.of(sources), selectedSourceId: id),
        );
        _invalidateCommittedContext();
        selectedSourceId.value = id;
        errorMessage.value = null;
        statusMessage.value = id == null ? '已取消选择网络源。' : '已选择网络源。';
      } catch (_) {
        errorMessage.value = '保存网络源选择失败，已保留原选择。';
      }
    });
  }

  Future<void> removeSource(String id) {
    if (_closed) return Future.value();
    _invalidateContext(sourceId: id);
    return _serialize(() async {
      if (_closed || _source(id) == null) return;
      final remaining = sources.where((source) => source.id != id).toList();
      final selected = selectedSourceId.value == id
          ? null
          : selectedSourceId.value;
      try {
        await _store.save(
          OnlineSourceSnapshot(sources: remaining, selectedSourceId: selected),
        );
        _invalidateCommittedContext(sourceId: id);
        sources.assignAll(remaining);
        selectedSourceId.value = selected;
        errorMessage.value = null;
        statusMessage.value = '已删除网络源；播放队列中的歌曲会保留并提示源不可用。';
      } catch (_) {
        errorMessage.value = '删除网络源失败，已保留原配置。';
      }
    });
  }

  /// A draft is probed before disk or reactive state changes. A later source
  /// selection/edit cancels this probe, so it cannot resurrect an old draft.
  Future<bool> upsertSource(
    OnlineSourceConfig config, {
    String testQuery = 'test',
  }) {
    if (_closed) return Future.value(false);
    _invalidateContext(sourceId: config.id);
    final context = _contextSerial;
    return _serialize(() async {
      if (_closed || context != _contextSerial) return false;
      if (sources.length >= 100 && _source(config.id) == null) {
        errorMessage.value = '最多可保存 100 个网络源。';
        return false;
      }
      if (!await testConfig(config, query: testQuery) ||
          _closed ||
          context != _contextSerial) {
        return false;
      }
      final updated = List<OnlineSourceConfig>.of(sources);
      final index = updated.indexWhere((source) => source.id == config.id);
      if (index < 0) {
        updated.add(config);
      } else {
        updated[index] = config;
      }
      final selected = selectedSourceId.value ?? config.id;
      final connectionStatus = statusMessage.value;
      try {
        await _store.save(
          OnlineSourceSnapshot(sources: updated, selectedSourceId: selected),
        );
        _invalidateCommittedContext(sourceId: config.id);
        sources.assignAll(updated);
        selectedSourceId.value = selected;
        errorMessage.value = null;
        statusMessage.value = '网络源已保存。${connectionStatus ?? ''}';
        return true;
      } catch (_) {
        errorMessage.value = '保存网络源失败，已保留原配置，请检查磁盘与权限。';
        return false;
      }
    });
  }

  Future<bool> testConnection(String id, {String query = 'test'}) async {
    final source = _source(id);
    if (source == null) {
      errorMessage.value = '网络源不存在，请重新选择。';
      return false;
    }
    return testConfig(source, query: query);
  }

  Future<bool> testConfig(
    OnlineSourceConfig config, {
    String query = 'test',
  }) async {
    if (_closed) return false;
    _testCancellation?.cancel();
    final serial = ++_testSerial;
    final context = _contextSerial;
    final cancellation = _testCancellation = OnlineRequestCancellation();
    isTesting.value = true;
    errorMessage.value = null;
    statusMessage.value = '正在测试网络源…';
    bool current() =>
        !_closed && serial == _testSerial && context == _contextSerial;
    try {
      final keyword = _validateQuery(query);
      if (keyword.isEmpty) throw const OnlineMusicException('请输入连接测试关键词。');
      final page = await _repository.search(
        config,
        keyword,
        config.search.firstPage,
        cancellation: cancellation,
      );
      if (!current()) return false;
      if (page.songs.isNotEmpty) {
        await _repository.resolve(
          config,
          page.songs.first.trackId!,
          cancellation: cancellation,
        );
      }
      if (!current()) return false;
      statusMessage.value = page.songs.isEmpty
          ? '连接成功，测试关键词无结果；播放映射尚未验证。'
          : '连接成功，搜索和播放地址映射均有效。';
      return true;
    } catch (error) {
      if (current()) errorMessage.value = _safeError(error);
      return false;
    } finally {
      if (current()) {
        isTesting.value = false;
        _testCancellation = null;
      }
    }
  }

  void setQuery(String text) {
    if (_closed) return;
    query.value = text;
    _invalidateSearch();
    errorMessage.value = null;
    if (text.trim().isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(searchNow());
    });
  }

  Future<void> searchNow([String? text]) async {
    if (_closed) return;
    if (text != null) query.value = text;
    _invalidateSearch();
    errorMessage.value = null;
    final serial = _searchSerial;
    final source = selectedSource;
    final keyword = query.value.trim();
    if (keyword.isEmpty) return;
    if (source == null) {
      errorMessage.value = '请先配置并选择网络源。';
      return;
    }
    final cancellation = _searchCancellation = OnlineRequestCancellation();
    isSearching.value = true;
    try {
      _validateQuery(keyword);
      final page = await _repository.search(
        source,
        keyword,
        source.search.firstPage,
        cancellation: cancellation,
      );
      if (_closed || serial != _searchSerial) return;
      results.assignAll(page.songs);
      hasMore.value = page.hasMore;
      _nextPage = source.search.firstPage + 1;
      _searchedQuery = keyword;
      statusMessage.value = page.songs.isEmpty
          ? '没有找到歌曲。'
          : '已找到 ${results.length} 首歌曲'
                '${page.skippedItems > 0 ? '，跳过 ${page.skippedItems} 条无效记录' : ''}。';
    } catch (error) {
      if (!_closed && serial == _searchSerial) {
        errorMessage.value = _safeError(error);
      }
    } finally {
      if (!_closed && serial == _searchSerial) {
        isSearching.value = false;
        _searchCancellation = null;
      }
    }
  }

  Future<void> loadMore() async {
    final source = selectedSource;
    if (_closed ||
        source == null ||
        !hasMore.value ||
        isSearching.value ||
        isLoadingMore.value ||
        _nextPage == null) {
      return;
    }
    final serial = _searchSerial;
    final cancellation = _searchCancellation = OnlineRequestCancellation();
    isLoadingMore.value = true;
    errorMessage.value = null;
    try {
      final page = await _repository.search(
        source,
        _searchedQuery,
        _nextPage!,
        cancellation: cancellation,
      );
      if (_closed || serial != _searchSerial) return;
      final ids = results.map((song) => song.id).toSet();
      final added = page.songs.where((song) => ids.add(song.id)).toList();
      results.addAll(added);
      _nextPage = _nextPage! + 1;
      // A service returning the same page forever cannot create an endless loop.
      hasMore.value = page.hasMore && added.isNotEmpty;
      statusMessage.value = '已加载 ${results.length} 首歌曲。';
    } catch (error) {
      if (!_closed && serial == _searchSerial) {
        errorMessage.value = _safeError(error);
      }
    } finally {
      if (!_closed && serial == _searchSerial) {
        isLoadingMore.value = false;
        _searchCancellation = null;
      }
    }
  }

  Future<Uri> resolveForPlayback(Song song) async {
    if (_closed) throw const PlaybackSourceException('网络源服务已关闭。');
    if (!song.isOnline) throw const PlaybackSourceException('该歌曲不是网络歌曲。');
    final source = _source(song.sourceId);
    if (source == null) {
      throw const PlaybackSourceException('该歌曲的网络源已删除，请重新配置或换一首。');
    }
    final revision = _revisions[source.id] ?? 0;
    final cancellation = OnlineRequestCancellation();
    (_resolveCancellations[source.id] ??= {}).add(cancellation);
    try {
      final uri = await _repository.resolve(
        source,
        song.trackId!,
        cancellation: cancellation,
      );
      if (_closed ||
          revision != (_revisions[source.id] ?? 0) ||
          !identical(_source(source.id), source)) {
        throw const PlaybackSourceException('网络源已更改，请重新播放。');
      }
      return uri;
    } on PlaybackSourceException {
      rethrow;
    } catch (error) {
      if (cancellation.isCancelled) {
        throw const PlaybackSourceException('网络源已更改或关闭，请重新播放。');
      }
      throw PlaybackSourceException(_safeError(error));
    } finally {
      _resolveCancellations[source.id]?.remove(cancellation);
      if (_resolveCancellations[source.id]?.isEmpty == true) {
        _resolveCancellations.remove(source.id);
      }
    }
  }

  void _invalidateSearch() {
    _debounce?.cancel();
    _debounce = null;
    _searchSerial++;
    _searchCancellation?.cancel();
    _searchCancellation = null;
    results.clear();
    hasMore.value = false;
    isSearching.value = false;
    isLoadingMore.value = false;
    _nextPage = null;
    _searchedQuery = '';
  }

  void _invalidateContext({String? sourceId}) {
    _contextSerial++;
    _invalidateCommittedContext(sourceId: sourceId);
  }

  // Work may start against the old source while its disk save is pending.
  // Invalidate again at commit, without cancelling later queued mutations.
  void _invalidateCommittedContext({String? sourceId}) {
    _invalidateSearch();
    _testSerial++;
    _testCancellation?.cancel();
    _testCancellation = null;
    isTesting.value = false;
    if (sourceId != null) {
      _revisions[sourceId] = (_revisions[sourceId] ?? 0) + 1;
      for (final request
          in _resolveCancellations[sourceId] ?? <OnlineRequestCancellation>{}) {
        request.cancel();
      }
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _mutations.then((_) => action());
    _mutations = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closed = true;
    _invalidateContext();
    for (final requests in _resolveCancellations.values) {
      for (final request in requests) {
        request.cancel();
      }
    }
    await _mutations;
  }

  @override
  void onClose() {
    unawaited(close());
    super.onClose();
  }
}

String _validateQuery(String query) {
  if (query.length > 512 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(query)) {
    throw const OnlineMusicException('关键词过长或含无效字符。');
  }
  return query.trim();
}

String _safeError(Object error) =>
    error is OnlineMusicException ? error.message : '网络源操作失败，请检查配置后重试。';
