import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/play_mode.dart';
import '../models/song.dart';

/// Versioned local state. Sleep timers deliberately do not survive a restart.
class AppSnapshot {
  const AppSnapshot({
    this.songs = const [],
    this.queue = const [],
    this.currentId,
    this.position = Duration.zero,
    this.mode = PlayMode.sequential,
    this.volume = .7,
    this.skipOnError = true,
  });

  final List<Song> songs;
  final List<Song> queue;
  final String? currentId;
  final Duration position;
  final PlayMode mode;
  final double volume;
  final bool skipOnError;

  Map<String, Object?> toJson() {
    final result = <String, Object?>{
      'schemaVersion': 2,
      'songs': songs.map((song) => song.toJson()).toList(),
      'queue': queue.map((song) => song.toJson()).toList(),
      'currentId': currentId,
      'positionMs': position.inMilliseconds,
      'mode': mode.name,
      'volume': volume,
      'skipOnError': skipOnError,
    };
    // Validate before writing so stream URLs or online library entries cannot
    // accidentally enter a state file through an in-memory constructor.
    AppSnapshot.fromJson(result);
    return result;
  }

  factory AppSnapshot.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is int && version > 2) {
      throw const UnsupportedStateVersion();
    }
    if (version is! int || (version != 1 && version != 2)) {
      throw const FormatException('Invalid schema version.');
    }
    List<Song> readSongs(String key) {
      final data = json[key];
      if (data is! List) throw FormatException('Invalid $key.');
      final unique = <String, Song>{};
      for (final item in data) {
        if (item is! Map<String, dynamic>) {
          throw FormatException('Invalid $key entry.');
        }
        final song = Song.fromJson(item);
        if (song.isOnline) {
          if (version != 2 || key != 'queue') {
            throw const FormatException(
              'Online songs belong only in a version-2 queue.',
            );
          }
          unique[song.id] = song;
          continue;
        }
        if (song.uri.scheme != 'file' || !song.uri.path.startsWith('/')) {
          throw const FormatException('Only local file URIs are supported.');
        }
        try {
          song.uri.toFilePath(windows: true);
        } on UnsupportedError {
          throw const FormatException('Invalid Windows file URI.');
        } on ArgumentError {
          throw const FormatException('Invalid Windows file URI.');
        }
        unique[song.id] = song;
      }
      return List.unmodifiable(unique.values);
    }

    final position = json['positionMs'];
    final volume = json['volume'];
    final mode = json['mode'];
    final currentId = json['currentId'];
    final skip = json['skipOnError'];
    if (position is! int ||
        position < 0 ||
        volume is! num ||
        !volume.isFinite ||
        volume < 0 ||
        volume > 1 ||
        mode is! String ||
        !PlayMode.values.any((item) => item.name == mode) ||
        (currentId != null && currentId is! String) ||
        skip is! bool) {
      throw const FormatException('Invalid playback state.');
    }
    return AppSnapshot(
      songs: readSongs('songs'),
      queue: readSongs('queue'),
      currentId: currentId as String?,
      position: Duration(milliseconds: position),
      mode: PlayMode.values.firstWhere((item) => item.name == mode),
      volume: volume.toDouble(),
      skipOnError: skip,
    );
  }
}

class UnsupportedStateVersion implements Exception {
  const UnsupportedStateVersion();
}

abstract interface class AppStateStore {
  String? get warning;
  Future<AppSnapshot> load();
  Future<void> save(AppSnapshot snapshot);
}

/// Awaitable writes, serialized across callers, with one known-good backup.
/// Only our own state files are written; source audio is never modified.
class FileAppStateStore implements AppStateStore {
  FileAppStateStore(this.directory);

  final Directory directory;
  Future<void> _writes = Future.value();
  String? _lastGood;
  bool _readOnly = false;
  @override
  String? warning;

  File get _primary => File('${directory.path}/state.json');
  File get _backup => File('${directory.path}/state.backup.json');
  File get _backupTemporary => File('${directory.path}/state.backup.next.json');
  File get _temporary => File('${directory.path}/state.next.json');

  @override
  Future<AppSnapshot> load() async {
    try {
      await directory.create(recursive: true);
      final hasPrimary = await _primary.exists();
      final hasBackup = await _backup.exists();
      if (!hasPrimary && !hasBackup) return const AppSnapshot();
      for (final file in [_primary, _backup]) {
        if (!await file.exists()) continue;
        try {
          final text = await file.readAsString();
          final snapshot = await compute(_decodeSnapshot, text);
          _lastGood = text;
          if (file.path == _backup.path) {
            warning = '本地状态文件异常，已从上一次有效备份恢复。';
          }
          return snapshot;
        } on UnsupportedStateVersion {
          _readOnly = true;
          warning = '本地数据来自不支持的版本，已保留原文件；本次更改不会保存。';
          return const AppSnapshot();
        } on FormatException {
          // A corrupt primary can be recovered from the known-good backup.
        }
      }
      _readOnly = true;
      warning = '本地数据和备份均无法读取，已保留原文件；本次更改不会保存。';
    } on FileSystemException {
      _readOnly = true;
      warning = '无法访问数据目录，请检查磁盘与权限；本次更改不会保存。';
    }
    return const AppSnapshot();
  }

  @override
  Future<void> save(AppSnapshot snapshot) {
    if (_readOnly) return Future.error(StateError(warning!));
    // Capture the snapshot before queueing, rather than serializing live Rx data.
    final data = AppSnapshot(
      songs: List.unmodifiable(snapshot.songs),
      queue: List.unmodifiable(snapshot.queue),
      currentId: snapshot.currentId,
      position: snapshot.position,
      mode: snapshot.mode,
      volume: snapshot.volume,
      skipOnError: snapshot.skipOnError,
    );
    final result = _writes.catchError((Object _) {}).then((_) async {
      final encoded = await compute(_encodeSnapshot, data);
      await directory.create(recursive: true);
      await _temporary.writeAsString(encoded, flush: true);
      final previous = _lastGood;
      if (previous != null) {
        // A recovered backup can be the only valid committed snapshot. Never
        // truncate it: a partial write must damage only this staging file.
        await _backupTemporary.writeAsString(previous, flush: true);
        await _backupTemporary.rename(_backup.path);
      }
      await _temporary.rename(_primary.path);
      _lastGood = encoded;
    });
    // Keep the ordering barrier usable after a disk failure, while the caller
    // receives and handles the original failure.
    _writes = result.catchError((Object _) {});
    return result;
  }
}

String _encodeSnapshot(AppSnapshot snapshot) => jsonEncode(snapshot.toJson());

AppSnapshot _decodeSnapshot(String text) {
  final data = jsonDecode(text);
  if (data is! Map<String, dynamic>) {
    throw const FormatException('Invalid state object.');
  }
  return AppSnapshot.fromJson(data);
}
