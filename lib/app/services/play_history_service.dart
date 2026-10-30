import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../data/models/play_history_entry.dart';
import '../data/models/playlist.dart';
import '../data/models/song.dart';
import 'player_service.dart';

/// Counts observed playback only. It never reads audio content or resolves URLs.
class PlayHistoryService extends GetxService {
  PlayHistoryService(
    this._player, {
    Duration Function()? monotonicNow,
    DateTime Function()? now,
    Future<bool> Function(Uri uri)? fileExists,
  }) : _monotonicNow = monotonicNow ?? _startClock(),
       _now = now ?? DateTime.now,
       _fileExists = fileExists ?? _localFileExists;

  static const recordingThreshold = Duration(seconds: 10);
  static const maxEntries = 200;
  final PlayerService _player;
  final Duration Function() _monotonicNow;
  final DateTime Function() _now;
  final Future<bool> Function(Uri uri) _fileExists;
  final entries = <PlayHistoryEntry>[].obs;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  bool _started = false;
  bool _closed = false;
  String? _songId;
  int? _selection;
  int? _seek;
  Duration _lastPosition = Duration.zero;
  Duration _lastTick = Duration.zero;
  Duration _played = Duration.zero;
  bool _wasEligible = false;
  bool _recorded = false;
  int _refreshGeneration = 0;
  Set<String>? _indexedDuringRefresh;

  static Duration Function() _startClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  static Future<bool> _localFileExists(Uri uri) => File.fromUri(uri).exists();

  void start() {
    if (_closed || _started) return;
    _started = true;
    _observe();
    _subscriptions.addAll([
      _player.position.listen((position) => _observe(position: position)),
      _player.currentSong.listen((_) => _observe()),
      _player.isPlaying.listen((_) => _observe()),
      _player.isLoading.listen((_) => _observe()),
      _player.playbackObservationChanges.listen((_) => _observe()),
    ]);
  }

  void _observe({Duration? position}) {
    if (_closed || !_started) return;
    final tick = _monotonicNow();
    final current = position ?? _player.position.value;
    final song = _player.currentSong.value;
    final selection = _player.selectionRevision;
    final seek = _player.seekRevision;
    final eligible =
        song != null && !song.isMissing && _player.canObservePlaybackPosition;
    final selectionChanged = _songId != song?.id || _selection != selection;
    if (selectionChanged) {
      _songId = song?.id;
      _selection = selection;
      _played = Duration.zero;
      _recorded = false;
      _wasEligible = false;
    }
    // Metadata refreshes and repeated native states carry no new progress.
    // Preserve the interval unless a playback eligibility boundary changed.
    if (position == null &&
        !selectionChanged &&
        seek == _seek &&
        eligible == _wasEligible) {
      return;
    }
    final elapsed = tick - _lastTick;
    final progress = current - _lastPosition;
    if (position != null &&
        !_recorded &&
        eligible &&
        _wasEligible &&
        seek == _seek &&
        elapsed > Duration.zero &&
        progress > Duration.zero &&
        // Unannounced discontinuities must not turn a jump into listening time.
        progress <= elapsed + const Duration(seconds: 1)) {
      _played += progress < elapsed ? progress : elapsed;
      if (_played >= recordingThreshold) _record(song);
    }
    _lastTick = tick;
    _lastPosition = current;
    _seek = seek;
    _wasEligible = eligible;
  }

  void _record(Song song) {
    _recorded = true;
    final previous = entries.firstWhereOrNull(
      (entry) => entry.song.id == song.id,
    );
    final count = previous?.playCount ?? 0;
    PlayHistoryEntry entry;
    try {
      entry = PlayHistoryEntry(
        song: song,
        lastPlayedAt: _now(),
        playCount: count == 0x7FFFFFFFFFFFFFFF ? count : count + 1,
      );
    } on FormatException {
      return;
    }
    _assignOrdered([
      entry,
      ...entries.where((previous) => previous.song.id != song.id),
    ]);
  }

  void restore(List<PlayHistoryEntry> values) {
    if (_closed) return;
    final checked = values
        .map((entry) => PlayHistoryEntry.fromJson(entry.toJson()))
        .toList();
    ++_refreshGeneration;
    _indexedDuringRefresh = null;
    _assignOrdered(checked);
    if (_started) _suppressCurrentSelection();
  }

  void _assignOrdered(List<PlayHistoryEntry> values) {
    final sorted = values.indexed.toList()
      ..sort((a, b) {
        final order = b.$2.lastPlayedAt.compareTo(a.$2.lastPlayedAt);
        return order != 0 ? order : a.$1.compareTo(b.$1);
      });
    final ids = <String>{};
    entries.assignAll(
      sorted
          .map((item) => item.$2)
          .where((entry) => ids.add(entry.song.id))
          .take(maxEntries),
    );
  }

  void clear() {
    if (_closed) return;
    entries.clear();
    _suppressCurrentSelection();
  }

  void remove(String songId) {
    if (_closed) return;
    entries.removeWhere((entry) => entry.song.id == songId);
    if (_player.currentSong.value?.id == songId) _suppressCurrentSelection();
  }

  void _suppressCurrentSelection() {
    _observe();
    _songId = _player.currentSong.value?.id;
    _selection = _player.selectionRevision;
    _recorded = true;
    _played = Duration.zero;
  }

  void updateSongs(List<Song> indexed) {
    if (_closed) return;
    final updates = {
      for (final song in indexed) song.id: Playlist.validateSong(song),
    };
    _indexedDuringRefresh?.addAll(updates.keys);
    _applySongChanges((song) => updates[song.id] ?? song);
  }

  Future<void> refreshMissing(List<Song> indexed) async {
    if (_closed) return;
    final updates = {
      for (final song in indexed)
        if (!song.isOnline) song.id: Playlist.validateSong(song),
    };
    final remaining = [
      for (final entry in entries)
        if (!entry.song.isOnline && !updates.containsKey(entry.song.id))
          entry.song,
    ];
    final generation = ++_refreshGeneration;
    final indexedDuringRefresh = _indexedDuringRefresh = <String>{};
    final missingFlags = <String, bool>{};
    try {
      for (final song in remaining) {
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
          return missing == null ? song : song.copyWith(isMissing: missing);
        });
      }
    } finally {
      if (identical(_indexedDuringRefresh, indexedDuringRefresh)) {
        _indexedDuringRefresh = null;
      }
    }
  }

  void _applySongChanges(Song Function(Song song) resolve) {
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final updated = resolve(entry.song);
      if (!identical(updated, entry.song) &&
          !mapEquals(updated.toJson(), entry.song.toJson())) {
        entries[index] = entry.copyWith(song: updated);
      }
    }
  }

  @override
  void onClose() {
    if (_closed) return;
    _closed = true;
    ++_refreshGeneration;
    _indexedDuringRefresh = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    super.onClose();
  }
}
