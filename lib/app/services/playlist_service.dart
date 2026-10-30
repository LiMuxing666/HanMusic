import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../data/models/playlist.dart';
import '../data/models/song.dart';

/// Owns playlist metadata only; no operation writes or removes source audio.
class PlaylistService extends GetxService {
  PlaylistService({
    DateTime Function()? now,
    Future<bool> Function(Uri uri)? fileExists,
  }) : _now = now ?? DateTime.now,
       _fileExists = fileExists ?? _localFileExists {
    restore(const []);
  }

  final DateTime Function() _now;
  final Future<bool> Function(Uri uri) _fileExists;
  final playlists = <Playlist>[].obs;
  bool _closed = false;
  int _nextId = 0;
  int _refreshGeneration = 0;
  Set<String>? _indexedDuringRefresh;

  static Future<bool> _localFileExists(Uri uri) => File.fromUri(uri).exists();

  Playlist? findById(String id) =>
      playlists.firstWhereOrNull((playlist) => playlist.id == id);

  bool isFavorite(String songId) =>
      findById(Playlist.favoritesId)?.songs.any((song) => song.id == songId) ??
      false;

  void restore(List<Playlist> values) {
    _checkOpen();
    final ids = <String>{};
    final names = <String>{};
    final restored = <Playlist>[];
    for (final value in values) {
      final checked = Playlist.fromJson(value.toJson());
      if (!ids.add(checked.id) || !names.add(checked.name.toLowerCase())) {
        throw const FormatException('歌单标识或名称重复。');
      }
      restored.add(checked);
    }
    if (!ids.contains(Playlist.favoritesId)) {
      if (names.contains(Playlist.favoritesName)) {
        throw const FormatException('“我喜欢”是保留的歌单名称。');
      }
      final now = _now().toUtc();
      restored.insert(
        0,
        Playlist(
          id: Playlist.favoritesId,
          name: Playlist.favoritesName,
          songs: const [],
          createdAt: now,
          updatedAt: now,
        ),
      );
    } else {
      final index = restored.indexWhere((playlist) => playlist.isFavorites);
      restored.insert(0, restored.removeAt(index));
    }
    _refreshGeneration++;
    _indexedDuringRefresh = null;
    playlists.assignAll(restored);
  }

  /// Metadata refreshes preserve playlist order and user-edit timestamps.
  void updateSongs(List<Song> indexed) {
    _checkOpen();
    final updates = {
      for (final song in indexed) song.id: Playlist.validateSong(song),
    };
    // A persistence flush may update the library during a slow file check.
    // Protect these identities without canceling checks for unrelated songs.
    _indexedDuringRefresh?.addAll(updates.keys);
    _applySongUpdates(updates);
  }

  Future<void> refreshMissing(List<Song> indexed) async {
    if (_closed) return;
    final updates = {
      for (final song in indexed)
        if (!song.isOnline) song.id: Playlist.validateSong(song),
    };
    final remaining = <String, Song>{
      for (final playlist in playlists)
        for (final song in playlist.songs)
          if (!song.isOnline && !updates.containsKey(song.id)) song.id: song,
    };
    final generation = ++_refreshGeneration;
    final indexedDuringRefresh = _indexedDuringRefresh = <String>{};
    final missingFlags = <String, bool>{};
    try {
      for (final song in remaining.values) {
        bool missing;
        try {
          missing = !await _fileExists(song.uri);
        } catch (_) {
          missing = true;
        }
        if (_closed || generation != _refreshGeneration) return;
        missingFlags[song.id] = missing;
      }
      if (!_closed && generation == _refreshGeneration) {
        _applySongChanges((song) {
          if (indexedDuringRefresh.contains(song.id)) return song;
          if (updates[song.id] case final indexed?) return indexed;
          final missing = missingFlags[song.id];
          // Merge only file status into the latest playlist snapshot.
          return missing == null ? song : song.copyWith(isMissing: missing);
        });
      }
    } finally {
      if (identical(_indexedDuringRefresh, indexedDuringRefresh)) {
        _indexedDuringRefresh = null;
      }
    }
  }

  void _applySongUpdates(Map<String, Song> updates) =>
      _applySongChanges((song) => updates[song.id] ?? song);

  void _applySongChanges(Song Function(Song song) resolve) {
    for (var index = 0; index < playlists.length; index++) {
      final playlist = playlists[index];
      var changed = false;
      final songs = playlist.songs.map((song) {
        final update = resolve(song);
        if (identical(song, update) ||
            mapEquals(song.toJson(), update.toJson())) {
          return song;
        }
        changed = true;
        return update;
      }).toList();
      if (changed) playlists[index] = playlist.copyWith(songs: songs);
    }
  }

  Playlist create(String name) {
    _checkOpen();
    final checkedName = _checkName(name);
    final now = _now().toUtc();
    String id;
    do {
      id = 'playlist-${now.microsecondsSinceEpoch}-${_nextId++}';
    } while (findById(id) != null);
    final playlist = Playlist(
      id: id,
      name: checkedName,
      songs: const [],
      createdAt: now,
      updatedAt: now,
    );
    playlists.add(playlist);
    return playlist;
  }

  void rename(String id, String name) {
    final playlist = _require(id);
    _checkEditable(playlist);
    final checkedName = _checkName(name, excludingId: id);
    if (playlist.name == checkedName) return;
    _replace(
      playlist.copyWith(name: checkedName, updatedAt: _updated(playlist)),
    );
  }

  void delete(String id) {
    final playlist = _require(id);
    _checkEditable(playlist);
    playlists.removeWhere((item) => item.id == id);
  }

  bool toggleFavorite(Song song) {
    _checkOpen();
    final checked = Playlist.validateSong(song);
    if (isFavorite(checked.id)) {
      removeSong(Playlist.favoritesId, checked.id);
      return false;
    }
    addSongs(Playlist.favoritesId, [checked]);
    return true;
  }

  ({int added, int existing}) addSongs(String id, List<Song> songs) {
    final playlist = _require(id);
    // Validate the whole input before committing any change, including duplicates.
    final checked = songs.map(Playlist.validateSong).toList();
    final ids = playlist.songs.map((song) => song.id).toSet();
    final additions = checked.where((song) => ids.add(song.id)).toList();
    if (additions.isNotEmpty) {
      _replace(
        playlist.copyWith(
          songs: [...playlist.songs, ...additions],
          updatedAt: _updated(playlist),
        ),
      );
    }
    return (added: additions.length, existing: songs.length - additions.length);
  }

  void removeSong(String id, String songId) {
    final playlist = _require(id);
    final songs = playlist.songs.where((song) => song.id != songId).toList();
    if (songs.length == playlist.songs.length) return;
    _replace(playlist.copyWith(songs: songs, updatedAt: _updated(playlist)));
  }

  /// Uses Flutter ReorderableListView's insertion-index convention.
  void reorderSongs(String id, int oldIndex, int newIndex) {
    final playlist = _require(id);
    if (oldIndex < 0 ||
        oldIndex >= playlist.songs.length ||
        newIndex < 0 ||
        newIndex > playlist.songs.length) {
      throw const FormatException('歌曲排序位置无效，请刷新后重试。');
    }
    if (newIndex > oldIndex) newIndex--;
    if (newIndex == oldIndex) return;
    final songs = playlist.songs.toList();
    songs.insert(newIndex, songs.removeAt(oldIndex));
    _replace(playlist.copyWith(songs: songs, updatedAt: _updated(playlist)));
  }

  void _checkOpen() {
    if (_closed) throw StateError('歌单服务已关闭。');
  }

  Playlist _require(String id) {
    _checkOpen();
    return findById(id) ?? (throw const FormatException('歌单不存在，请刷新后重试。'));
  }

  void _checkEditable(Playlist playlist) {
    if (playlist.isFavorites) {
      throw const FormatException('“我喜欢”歌单不能重命名或删除。');
    }
  }

  String _checkName(String name, {String? excludingId}) {
    final checked = Playlist.validateName(name);
    if (playlists.any(
      (playlist) =>
          playlist.id != excludingId &&
          playlist.name.toLowerCase() == checked.toLowerCase(),
    )) {
      throw const FormatException('已存在同名歌单，请换一个名称。');
    }
    return checked;
  }

  DateTime _updated(Playlist playlist) {
    final now = _now().toUtc();
    return now.isBefore(playlist.updatedAt) ? playlist.updatedAt : now;
  }

  void _replace(Playlist playlist) {
    final index = playlists.indexWhere((item) => item.id == playlist.id);
    playlists[index] = playlist;
  }

  @override
  void onClose() {
    _closed = true;
    _indexedDuringRefresh = null;
    super.onClose();
  }
}
