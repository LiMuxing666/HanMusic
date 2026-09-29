import 'dart:convert';
import 'dart:io';

import '../models/online_source_config.dart';

class OnlineSourceSnapshot {
  const OnlineSourceSnapshot({this.sources = const [], this.selectedSourceId});
  final List<OnlineSourceConfig> sources;
  final String? selectedSourceId;

  factory OnlineSourceSnapshot.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is int && version > 1) {
      throw const UnsupportedOnlineSourceVersion();
    }
    if (version != 1 ||
        json.keys.any(
          (key) =>
              !{'schemaVersion', 'sources', 'selectedSourceId'}.contains(key),
        )) {
      throw const FormatException('网络源存储格式无效。');
    }
    final raw = json['sources'];
    final selected = json['selectedSourceId'];
    if (raw is! List ||
        raw.length > 100 ||
        (selected != null && selected is! String)) {
      throw const FormatException('网络源存储格式无效。');
    }
    final sources = <OnlineSourceConfig>[];
    final ids = <String>{};
    for (final value in raw) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('网络源配置无效。');
      }
      final source = OnlineSourceConfig.fromJson(value);
      if (!ids.add(source.id)) throw const FormatException('网络源 ID 重复。');
      sources.add(source);
    }
    if (selected != null && !ids.contains(selected)) {
      throw const FormatException('所选网络源不存在。');
    }
    return OnlineSourceSnapshot(
      sources: List.unmodifiable(sources),
      selectedSourceId: selected as String?,
    );
  }

  Map<String, Object?> toJson() {
    final value = <String, Object?>{
      'schemaVersion': 1,
      'sources': sources.map((source) => source.toJson()).toList(),
      'selectedSourceId': selectedSourceId,
    };
    OnlineSourceSnapshot.fromJson(value);
    return value;
  }
}

abstract interface class OnlineSourceStore {
  String? get warning;
  Future<OnlineSourceSnapshot> load();
  Future<void> save(OnlineSourceSnapshot snapshot);
}

/// Only anonymous source definitions are persisted; resolved stream URLs never
/// enter this store. Each successful save retains the previous valid snapshot.
class FileOnlineSourceStore implements OnlineSourceStore {
  FileOnlineSourceStore(this.directory);
  final Directory directory;
  static const _maxFileBytes = 1024 * 1024;
  Future<void> _writes = Future.value();
  String? _lastGood;
  bool _readOnly = false;
  @override
  String? warning;

  File get _primary => File('${directory.path}/sources.json');
  File get _backup => File('${directory.path}/sources.backup.json');
  File get _temporary => File('${directory.path}/sources.next.json');

  @override
  Future<OnlineSourceSnapshot> load() async {
    await _writes;
    try {
      await directory.create(recursive: true);
      if (!await _primary.exists() && !await _backup.exists()) {
        return const OnlineSourceSnapshot();
      }
      for (final file in [_primary, _backup]) {
        if (!await file.exists()) continue;
        try {
          if (await file.length() > _maxFileBytes) {
            throw const FormatException();
          }
          final text = await file.readAsString();
          final json = jsonDecode(text);
          if (json is! Map<String, dynamic>) throw const FormatException();
          final snapshot = OnlineSourceSnapshot.fromJson(json);
          _lastGood = text;
          if (file.path == _backup.path) warning = '网络源配置异常，已从上一次有效备份恢复。';
          return snapshot;
        } on UnsupportedOnlineSourceVersion {
          _readOnly = true;
          warning = '网络源配置来自较新版本，已保留文件；当前不能保存更改。';
          return const OnlineSourceSnapshot();
        } on FormatException {
          // Try the known-good backup; never replace two unreadable files.
        }
      }
      _readOnly = true;
      warning = '网络源配置和备份均无法读取，已保留文件；当前不能保存更改。';
    } on FileSystemException {
      _readOnly = true;
      warning = '无法访问网络源配置目录，请检查磁盘与权限；当前不能保存更改。';
    }
    return const OnlineSourceSnapshot();
  }

  @override
  Future<void> save(OnlineSourceSnapshot snapshot) {
    if (_readOnly) return Future.error(StateError(warning!));
    final captured = OnlineSourceSnapshot(
      sources: List.unmodifiable(snapshot.sources),
      selectedSourceId: snapshot.selectedSourceId,
    );
    final result = _writes.then((_) async {
      final encoded = jsonEncode(captured.toJson());
      if (utf8.encode(encoded).length > _maxFileBytes) {
        throw const FormatException('网络源配置总量过大。');
      }
      await directory.create(recursive: true);
      await _temporary.writeAsString(encoded, flush: true);
      final previous = _lastGood;
      if (previous != null) await _backup.writeAsString(previous, flush: true);
      await _temporary.rename(_primary.path);
      _lastGood = encoded;
    });
    _writes = result.catchError((Object _) {});
    return result;
  }
}
