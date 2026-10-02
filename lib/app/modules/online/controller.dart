import 'dart:convert';

import 'package:get/get.dart';

import '../../data/models/online_source_config.dart';
import '../../data/models/song.dart';
import '../../services/online_music_service.dart';

class OnlineMusicController extends GetxController {
  OnlineMusicController({
    required this.service,
    required Future<void> Function(Song song) playSong,
    required void Function(Song song) enqueueSong,
  }) : _playSong = playSong,
       _enqueueSong = enqueueSong;

  final OnlineMusicService service;
  final Future<void> Function(Song song) _playSong;
  final void Function(Song song) _enqueueSong;
  final actionError = RxnString();
  final isOpening = false.obs;
  final openingSongId = RxnString();
  final isSaving = false.obs;
  bool _closed = false;
  int _openingSerial = 0;

  void setQuery(String query) => service.setQuery(query);
  Future<void> searchNow() => service.searchNow();
  Future<void> loadMore() => service.loadMore();
  Future<void> retrySearchError() => service.retrySearchError();
  Future<void> selectSource(String? id) => service.selectSource(id);

  Future<void> play(Song song) async {
    if (_closed || (isOpening.value && openingSongId.value == song.id)) return;
    final serial = ++_openingSerial;
    openingSongId.value = song.id;
    isOpening.value = true;
    try {
      await _playSong(song);
    } finally {
      // Superseded work must not unlock a newer song that is still loading.
      if (!_closed && serial == _openingSerial) {
        isOpening.value = false;
        openingSongId.value = null;
      }
    }
  }

  void enqueue(Song song) {
    if (!_closed) _enqueueSong(song);
  }

  void clearActionError() => actionError.value = null;

  Future<bool> saveSource(
    String json,
    String testQuery, {
    String? originalId,
  }) async {
    if (_closed || service.isTesting.value || isSaving.value) return false;
    actionError.value = null;
    isSaving.value = true;
    try {
      final config = OnlineSourceConfig.fromJsonText(json);
      if (originalId != null && config.id != originalId) {
        actionError.value = '编辑时请保留原音乐源标识；新建音乐源请使用“添加音乐源”。';
        return false;
      }
      if (originalId == null &&
          service.sources.any((item) => item.id == config.id)) {
        actionError.value = '音乐源标识已存在，请更换 id 或编辑已有音乐源。';
        return false;
      }
      final saved = await service.upsertSource(
        config,
        testQuery: testQuery.trim(),
      );
      if (_closed) return false;
      if (!saved) {
        actionError.value = service.errorMessage.value ?? '连接测试或保存失败，请检查配置。';
        return false;
      }
      final savedNotice = service.statusMessage.value;
      if (service.selectedSourceId.value != config.id) {
        await service.selectSource(config.id);
        if (_closed) return false;
        if (service.selectedSourceId.value != config.id) {
          actionError.value = '音乐源已保存，但未能切换到该源。请关闭窗口后重新选择。';
          return false;
        }
        service.statusMessage.value = savedNotice;
      }
      return true;
    } on FormatException catch (error) {
      if (!_closed) actionError.value = '配置格式不正确：${error.message}';
    } catch (_) {
      if (!_closed) actionError.value = '无法保存音乐源，请检查配置和本地数据目录。';
    } finally {
      if (!_closed) isSaving.value = false;
    }
    return false;
  }

  Future<bool> testConnection(String sourceId, String query) async {
    actionError.value = null;
    final ok = await service.testConnection(sourceId, query: query.trim());
    if (!ok && !_closed) {
      actionError.value = service.errorMessage.value ?? '连接测试失败，请检查音乐源配置。';
    }
    return ok;
  }

  Future<void> removeSource(String id) => service.removeSource(id);

  String sourceJson(OnlineSourceConfig? source) =>
      const JsonEncoder.withIndent('  ').convert(
        source?.toJson() ??
            {
              'schemaVersion': 1,
              'id': 'source-${DateTime.now().millisecondsSinceEpoch}',
              'name': '我的音乐源',
              'baseUrl': 'http://127.0.0.1:8765/',
              'timeoutSeconds': 10,
              'search': {
                'path': 'search',
                'queryParameter': 'q',
                'pageParameter': 'page',
                'limitParameter': 'limit',
                'firstPage': 1,
                'pageSize': 20,
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
              'playback': {
                'path': 'play',
                'idParameter': 'id',
                'urlPath': 'data.url',
              },
            },
      );

  @override
  void onClose() {
    _closed = true;
    super.onClose();
  }
}
