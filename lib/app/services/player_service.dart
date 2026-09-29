import 'dart:async';
import 'dart:math';

import 'package:get/get.dart';

import '../data/models/play_mode.dart';
import '../data/models/playback_guard.dart';
import '../data/models/playback_source_exception.dart';
import '../data/models/song.dart';
import '../data/sources/audio_backend.dart';

class PlayerService extends GetxService {
  PlayerService(this._backend, {Future<Uri> Function(Song)? resolver})
    : _resolver = resolver {
    _subscriptions.addAll([
      _backend.states.listen((state) {
        if (_disposed) return;
        final newlyCompleted = state.completed && !_completed;
        _completed =
            state.completed || (_completed && !state.playing && !state.loading);
        if (state.completed && duration.value > Duration.zero) {
          position.value = duration.value;
        }
        isPlaying.value =
            state.playing &&
            !state.completed &&
            _loaded.value &&
            _wantsPlayback;
        if (newlyCompleted &&
            _loaded.value &&
            _wantsPlayback &&
            !_pauseForGuard(PlaybackBoundary.completion)) {
          _scheduleAdvance();
        }
      }),
      _backend.positions.listen((value) {
        if (!_disposed && !isLoading.value && _loaded.value && !_completed) {
          position.value = value;
        }
      }),
      _backend.durations.listen((value) {
        if (!_disposed && !isLoading.value && _loaded.value && value != null) {
          duration.value = value;
        }
      }),
      _backend.errors.listen(_handleBackendError),
    ]);
  }

  final AudioBackend _backend;
  final Future<Uri> Function(Song)? _resolver;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final queue = <Song>[].obs;
  final playMode = PlayMode.sequential.obs;
  final skipOnError = true.obs;
  final currentSong = Rxn<Song>();
  final isPlaying = false.obs;
  final isLoading = false.obs;
  final position = Duration.zero.obs;
  final duration = Duration.zero.obs;
  final volume = 0.7.obs;
  final errorMessage = RxnString();
  final _loaded = false.obs;
  final _random = Random();
  final _failedIds = <String>{};
  final _shuffleBag = <String>[];
  final _history = <String>[];
  int _historyIndex = -1;
  PlayMode _lastMode = PlayMode.sequential;
  bool _completed = false;
  bool _disposed = false;
  bool _toggleBusy = false;
  bool _wantsPlayback = false;
  bool _restored = false;
  bool _advancePending = false;
  int _playIntent = 0;
  int _selectionGeneration = 0;
  int _loadGeneration = 0;
  Future<void> _selectionTail = Future<void>.value();
  Completer<Uri?>? _resolutionCancellation;
  Future<void>? _errorPause;
  Future<void>? _pauseInFlight;
  PlaybackGuard? _playbackGuard;
  int _errorPauseGeneration = 0;

  void attachPlaybackGuard(PlaybackGuard guard) => _playbackGuard = guard;

  void detachPlaybackGuard(PlaybackGuard guard) {
    if (identical(_playbackGuard, guard)) _playbackGuard = null;
  }

  bool _pauseForGuard(PlaybackBoundary boundary) {
    if (_playbackGuard?.shouldPause(boundary, currentSong.value?.id) != true) {
      return false;
    }
    ++_playIntent;
    _wantsPlayback = false;
    isPlaying.value = false;
    return true;
  }

  void _manualSelection(String? id) {
    _playbackGuard?.onManualSelection(id);
    _playbackGuard?.onManualPlayback();
  }

  int get currentIndex =>
      queue.indexWhere((song) => song.id == currentSong.value?.id);

  /// A restored selection is playable without eagerly opening its native file.
  bool get canPlay =>
      !_disposed &&
      !isLoading.value &&
      (_loaded.value ||
          (_restored &&
              currentSong.value != null &&
              (!currentSong.value!.isMissing ||
                  (skipOnError.value &&
                      queue.any((song) => !song.isMissing)))));

  Future<void> open(Song song) async {
    if (_disposed || isLoading.value) return;
    await playQueue([song]);
  }

  Future<void> playQueue(List<Song> songs, {int startIndex = 0}) async {
    if (_disposed) return;
    final selectedId = songs.isEmpty
        ? null
        : songs[startIndex.clamp(0, songs.length - 1)].id;
    _manualSelection(selectedId);
    queue.assignAll(_unique(songs));
    _resetNavigation();
    _failedIds.clear();
    if (selectedId == null) {
      await _clearSelection();
      return;
    }
    final intent = ++_playIntent;
    _wantsPlayback = true;
    await _requestSelection(selectedId, intent: intent);
  }

  void addToQueue(List<Song> songs) {
    if (_disposed) return;
    final ids = queue.map((song) => song.id).toSet();
    queue.addAll(songs.where((song) => ids.add(song.id)));
    if (currentSong.value == null && queue.isNotEmpty) {
      _selectRestored(queue.first, Duration.zero);
    }
    _shuffleBag.clear();
  }

  Future<void> playAt(int index) async {
    if (_disposed || index < 0 || index >= queue.length) return;
    _manualSelection(queue[index].id);
    _failedIds.clear();
    final intent = ++_playIntent;
    _wantsPlayback = true;
    await _requestSelection(queue[index].id, intent: intent);
  }

  /// Explicit navigation wraps; repeat-one only affects natural completion.
  Future<void> next() async {
    if (_disposed || queue.isEmpty) return;
    final id = _nextId(completion: false);
    if (id == null) return;
    _manualSelection(id);
    _failedIds.clear();
    final intent = ++_playIntent;
    _wantsPlayback = true;
    await _requestSelection(id, intent: intent);
  }

  Future<void> previous() async {
    if (_disposed || queue.isEmpty) return;
    _ensureMode();
    String id;
    if (playMode.value == PlayMode.shuffle && _history.length > 1) {
      _historyIndex = (_historyIndex - 1 + _history.length) % _history.length;
      id = _history[_historyIndex];
    } else {
      final index = currentIndex < 0 ? 0 : currentIndex;
      id = queue[(index - 1 + queue.length) % queue.length].id;
    }
    _manualSelection(id);
    _failedIds.clear();
    final intent = ++_playIntent;
    _wantsPlayback = true;
    await _requestSelection(id, intent: intent);
  }

  /// Uses Flutter ReorderableListView's insertion-index convention.
  void reorderQueue(int oldIndex, int newIndex) {
    if (_disposed ||
        oldIndex < 0 ||
        oldIndex >= queue.length ||
        newIndex < 0 ||
        newIndex > queue.length) {
      return;
    }
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex == newIndex) return;
    final reordered = queue.toList();
    final song = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, song);
    queue.assignAll(reordered);
  }

  Future<void> removeFromQueue(String id) async {
    if (_disposed) return;
    final removedIndex = queue.indexWhere((song) => song.id == id);
    if (removedIndex < 0) return;
    final wasCurrent = currentSong.value?.id == id;
    if (wasCurrent) {
      _playbackGuard?.onManualSelection(null);
      _pauseForGuard(PlaybackBoundary.beforePlay);
    }
    final shouldPlay = _wantsPlayback;
    queue.removeAt(removedIndex);
    _pruneNavigation();
    _failedIds.remove(id);
    if (!wasCurrent) return;
    if (queue.isEmpty) {
      await _clearSelection();
      return;
    }
    final replacement = queue[removedIndex.clamp(0, queue.length - 1)];
    final intent = ++_playIntent;
    _wantsPlayback = shouldPlay;
    await _requestSelection(
      replacement.id,
      intent: intent,
      autoplay: shouldPlay,
    );
  }

  void updateSongs(List<Song> songs) {
    if (_disposed) return;
    final updates = {for (final song in songs) song.id: song};
    final updatedQueue = queue.map((song) => updates[song.id] ?? song).toList();
    if (queue.any((song) => updates.containsKey(song.id))) {
      queue.assignAll(updatedQueue);
    }
    final updatedCurrent = updates[currentSong.value?.id];
    if (updatedCurrent != null) {
      currentSong.value = updatedCurrent;
      if (!_loaded.value) {
        duration.value = updatedCurrent.duration ?? Duration.zero;
      }
    }
  }

  /// Restores paused. The first toggle loads the file and seeks to the saved
  /// position; seek can edit that position before the native file is loaded.
  Future<void> restoreQueue(
    List<Song> songs, {
    String? currentId,
    Duration position = Duration.zero,
    PlayMode mode = PlayMode.sequential,
    double volume = 0.7,
    bool skipOnError = true,
  }) async {
    if (_disposed) return;
    _playbackGuard?.onManualSelection(null);
    ++_playIntent;
    final request = _beginSelection();
    ++_loadGeneration;
    _wantsPlayback = false;
    _loaded.value = false;
    _completed = false;
    isPlaying.value = false;
    isLoading.value = false;
    errorMessage.value = null;
    this.volume.value = volume.isFinite ? volume.clamp(0.0, 1.0) : 0.7;
    this.skipOnError.value = skipOnError;
    playMode.value = mode;
    queue.assignAll(_unique(songs));
    final index = queue.indexWhere((song) => song.id == currentId);
    final selected = queue.isEmpty ? null : queue[index < 0 ? 0 : index];
    _selectRestored(
      selected,
      currentId != null && index < 0 ? Duration.zero : position,
    );
    _resetNavigation();
    _failedIds.clear();
    final work = _selectionTail.then((_) async {
      if (!_active(request)) return;
      if (_errorPause case final pending?) await pending;
      if (!_active(request)) return;
      try {
        await _backend.pause();
      } catch (_) {
        if (_active(request)) errorMessage.value = '未能暂停播放，请关闭应用以停止音频。';
      }
    });
    _selectionTail = work;
    await work;
  }

  Future<void> _requestSelection(
    String id, {
    required int intent,
    bool autoplay = true,
    Duration resumePosition = Duration.zero,
    bool automatic = false,
  }) {
    final request = _beginSelection();
    ++_loadGeneration;
    _restored = false;
    isLoading.value = true;
    isPlaying.value = false;
    final work = _selectionTail.then((_) async {
      if (!_active(request)) return;
      try {
        final candidates = _candidateIds(
          id,
          wrap: !automatic || playMode.value != PlayMode.sequential,
        );
        for (final candidateId in candidates) {
          if (!_active(request)) return;
          if ((automatic || candidateId != id) &&
              _pauseForGuard(PlaybackBoundary.beforePlay)) {
            return;
          }
          final index = queue.indexWhere((song) => song.id == candidateId);
          if (index < 0 || _failedIds.contains(candidateId)) continue;
          final song = queue[index];
          final result = await _loadSong(
            song,
            request: request,
            intent: intent,
            autoplay: autoplay,
            resumePosition: candidateId == id ? resumePosition : Duration.zero,
          );
          if (result == _LoadResult.loaded) {
            _recordHistory(song.id);
            return;
          }
          if (result == _LoadResult.cancelled) return;
          _failedIds.add(song.id);
          if (!skipOnError.value || intent != _playIntent) return;
        }
        if (_active(request)) {
          _loaded.value = false;
          _wantsPlayback = false;
          isPlaying.value = false;
          if (queue.length > 1) errorMessage.value = '队列中没有可播放的文件，请检查缺失或损坏的音频。';
        }
      } finally {
        if (_active(request)) isLoading.value = false;
      }
    });
    _selectionTail = work;
    return work;
  }

  Future<_LoadResult> _loadSong(
    Song song, {
    required int request,
    required int intent,
    required bool autoplay,
    required Duration resumePosition,
  }) async {
    var generation = ++_loadGeneration;
    _loaded.value = false;
    _completed = false;
    errorMessage.value = null;
    currentSong.value = song;
    position.value = Duration.zero;
    duration.value = song.duration ?? Duration.zero;
    if (resumePosition > Duration.zero) {
      position.value = _clampPosition(resumePosition);
    }
    bool valid() => _active(request) && generation == _loadGeneration;
    _LoadResult invalidResult() =>
        _active(request) ? _LoadResult.failed : _LoadResult.cancelled;
    try {
      if (_errorPause case final pending?) await pending;
      if (_pauseInFlight case final pending?) await pending;
      if (!valid()) return invalidResult();
      await _backend.pause();
      if (!valid()) return invalidResult();
      if (song.isMissing) {
        _pauseForGuard(PlaybackBoundary.error);
        errorMessage.value = '文件已丢失：${song.fileName}';
        return _LoadResult.failed;
      }
      Duration? length;
      for (var attempt = 0; ; attempt++) {
        Uri playbackUri;
        if (song.isOnline) {
          final resolver = _resolver;
          if (resolver == null) {
            throw const PlaybackSourceException('未配置在线音乐源，请先添加可用的音乐源。');
          }
          final resolved = await _resolveSource(song, resolver);
          if (resolved == null) return _LoadResult.cancelled;
          playbackUri = resolved;
          if (!valid()) return invalidResult();
          if (playbackUri.scheme != 'http' && playbackUri.scheme != 'https' ||
              playbackUri.host.isEmpty ||
              playbackUri.userInfo.isNotEmpty) {
            throw const PlaybackSourceException('音乐源返回了不支持的播放地址。');
          }
          if (intent != _playIntent ||
              _pauseForGuard(PlaybackBoundary.beforePlay)) {
            _restored = true;
            return _LoadResult.cancelled;
          }
        } else {
          if (song.uri.scheme != 'file') {
            throw const PlaybackSourceException('歌曲地址无效，请重新添加歌曲。');
          }
          playbackUri = song.uri;
        }
        try {
          length = await _backend
              .load(playbackUri)
              .timeout(const Duration(seconds: 20));
          if (!valid()) {
            if (!_active(request)) return _LoadResult.cancelled;
            throw const PlaybackSourceException('音频加载失败，请检查音乐源或网络。');
          }
          break;
        } catch (_) {
          if (!_active(request)) return _LoadResult.cancelled;
          if (!song.isOnline || attempt >= 1) rethrow;
          if (_pauseForGuard(PlaybackBoundary.error) || intent != _playIntent) {
            _restored = true;
            return _LoadResult.cancelled;
          }
          if (_errorPause case final pending?) {
            await pending;
          } else {
            await _backend.pause();
          }
          if (!_active(request)) return _LoadResult.cancelled;
          if (intent != _playIntent ||
              _pauseForGuard(PlaybackBoundary.beforePlay)) {
            _restored = true;
            return _LoadResult.cancelled;
          }
          generation = ++_loadGeneration;
          _failedIds.remove(song.id);
          errorMessage.value = null;
        }
      }
      if (!valid()) return invalidResult();
      duration.value = length ?? song.duration ?? Duration.zero;
      _loaded.value = true;
      await _backend.setVolume(volume.value);
      if (!valid()) return invalidResult();
      if (resumePosition > Duration.zero) {
        final target = _clampPosition(resumePosition);
        await _backend.seek(target);
        if (!valid()) return invalidResult();
        position.value = target;
      }
      if (_pauseInFlight case final pending?) await pending;
      if (!valid()) return invalidResult();
      if (autoplay &&
          _wantsPlayback &&
          intent == _playIntent &&
          !_pauseForGuard(PlaybackBoundary.beforePlay)) {
        await _backend.play();
        if (!valid()) return invalidResult();
      }
      return _LoadResult.loaded;
    } catch (error) {
      if (!_active(request)) return _LoadResult.cancelled;
      _pauseForGuard(PlaybackBoundary.error);
      _loaded.value = false;
      isPlaying.value = false;
      errorMessage.value = error is PlaybackSourceException
          ? error.message
          : song.isOnline
          ? '无法播放在线歌曲，请检查音乐源或网络后重试。'
          : '无法播放此文件，请检查文件是否损坏或已被移动。';
      try {
        if (_errorPause case final pending?) {
          await pending;
        } else {
          await _backend.pause();
        }
      } catch (_) {
        if (_active(request)) errorMessage.value = '音频播放出错且未能停止，请关闭应用以停止音频。';
      }
      return _active(request) ? _LoadResult.failed : _LoadResult.cancelled;
    }
  }

  Future<Uri?> _resolveSource(
    Song song,
    Future<Uri> Function(Song) resolver,
  ) async {
    final cancellation = Completer<Uri?>();
    _resolutionCancellation = cancellation;
    try {
      // A superseded HTTP lookup must not keep newer selections behind the
      // native-load barrier. Future.any also consumes a late lookup failure.
      return await Future.any<Uri?>([
        resolver(song).timeout(const Duration(seconds: 20)),
        cancellation.future,
      ]);
    } finally {
      if (identical(_resolutionCancellation, cancellation)) {
        _resolutionCancellation = null;
      }
    }
  }

  int _beginSelection() {
    final generation = ++_selectionGeneration;
    final cancellation = _resolutionCancellation;
    _resolutionCancellation = null;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete(null);
    }
    return generation;
  }

  void _handleBackendError(Object error) {
    if (_disposed) return;
    _pauseForGuard(PlaybackBoundary.error);
    _errorPauseGeneration = ++_loadGeneration;
    final id = currentSong.value?.id;
    if (id != null) _failedIds.add(id);
    _loaded.value = false;
    _restored = false;
    isPlaying.value = false;
    errorMessage.value = '音频播放中断，请重新选择有效的音频文件。';
    if (_errorPause == null) {
      final completion = Completer<void>();
      _errorPause = completion.future;
      unawaited(_pauseAfterBackendError(completion));
    }
    if (!isLoading.value &&
        skipOnError.value &&
        _wantsPlayback &&
        queue.length > 1) {
      _scheduleAdvance(fromError: true);
    }
  }

  Future<void> _pauseAfterBackendError(Completer<void> completion) async {
    try {
      await _backend.pause();
    } catch (_) {
      if (!_disposed && _errorPauseGeneration == _loadGeneration) {
        errorMessage.value = '音频播放出错且未能停止，请关闭应用以停止音频，再重新打开文件。';
      }
    } finally {
      _errorPause = null;
      completion.complete();
    }
  }

  void _scheduleAdvance({bool fromError = false}) {
    if (_advancePending) return;
    _advancePending = true;
    final intent = _playIntent;
    final sourceId = currentSong.value?.id;
    unawaited(() async {
      await Future<void>.value();
      _advancePending = false;
      if (_disposed ||
          intent != _playIntent ||
          !_wantsPlayback ||
          currentSong.value?.id != sourceId) {
        return;
      }
      if (_pauseForGuard(
        fromError ? PlaybackBoundary.error : PlaybackBoundary.completion,
      )) {
        return;
      }
      final id = _nextId(completion: true, skipRepeatOne: fromError);
      if (id == null ||
          (fromError && queue.every((song) => _failedIds.contains(song.id)))) {
        _wantsPlayback = false;
        return;
      }
      await _requestSelection(id, intent: intent, automatic: true);
    }());
  }

  String? _nextId({required bool completion, bool skipRepeatOne = false}) {
    if (queue.isEmpty) return null;
    _ensureMode();
    final index = currentIndex;
    if (index < 0) return queue.first.id;
    if (completion && !skipRepeatOne && playMode.value == PlayMode.repeatOne) {
      return queue[index].id;
    }
    if (playMode.value == PlayMode.shuffle) {
      if (_historyIndex + 1 < _history.length) return _history[++_historyIndex];
      _shuffleBag.removeWhere(
        (id) =>
            id == currentSong.value?.id ||
            _failedIds.contains(id) ||
            !queue.any((song) => song.id == id),
      );
      if (_shuffleBag.isEmpty) {
        _shuffleBag.addAll(
          queue
              .where(
                (song) =>
                    song.id != currentSong.value?.id &&
                    !_failedIds.contains(song.id),
              )
              .map((song) => song.id),
        );
        _shuffleBag.shuffle(_random);
      }
      return _shuffleBag.isEmpty ? queue[index].id : _shuffleBag.removeAt(0);
    }
    if (completion &&
        playMode.value == PlayMode.sequential &&
        index == queue.length - 1) {
      return null;
    }
    return queue[(index + 1) % queue.length].id;
  }

  List<String> _candidateIds(String id, {required bool wrap}) {
    final index = queue.indexWhere((song) => song.id == id);
    if (index < 0) return const [];
    if (!skipOnError.value) return [id];
    final others = List.generate(
      wrap ? queue.length - 1 : queue.length - index - 1,
      (offset) => queue[(index + offset + 1) % queue.length].id,
    );
    if (playMode.value == PlayMode.shuffle) others.shuffle(_random);
    return [id, ...others];
  }

  void _recordHistory(String id) {
    _shuffleBag.remove(id);
    if (_historyIndex >= 0 &&
        _historyIndex < _history.length &&
        _history[_historyIndex] == id) {
      return;
    }
    if (_historyIndex + 1 < _history.length) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    _history.add(id);
    _historyIndex = _history.length - 1;
  }

  void _resetNavigation() {
    _shuffleBag.clear();
    _history.clear();
    _historyIndex = -1;
    _lastMode = playMode.value;
    final id = currentSong.value?.id;
    if (id != null && queue.any((song) => song.id == id)) _recordHistory(id);
  }

  void _ensureMode() {
    if (_lastMode != playMode.value) _resetNavigation();
  }

  void _pruneNavigation() {
    final ids = queue.map((song) => song.id).toSet();
    final historyId = _historyIndex >= 0 && _historyIndex < _history.length
        ? _history[_historyIndex]
        : null;
    _history.removeWhere((id) => !ids.contains(id));
    _historyIndex = historyId == null ? -1 : _history.lastIndexOf(historyId);
    if (_historyIndex < 0 && _history.isNotEmpty) {
      _historyIndex = _history.length - 1;
    }
    _shuffleBag.removeWhere((id) => !ids.contains(id));
  }

  Future<void> togglePlayback() async {
    if (!canPlay || _toggleBusy) return;
    _toggleBusy = true;
    try {
      if (isPlaying.value) {
        await pause();
        return;
      }
      _playbackGuard?.onManualPlayback();
      final intent = ++_playIntent;
      _wantsPlayback = true;
      if (_restored) {
        _failedIds.clear();
        await _requestSelection(
          currentSong.value!.id,
          intent: intent,
          resumePosition: position.value,
        );
        return;
      }
      final generation = _loadGeneration;
      if (_errorPause case final pending?) await pending;
      if (_pauseInFlight case final pending?) await pending;
      if (_disposed || intent != _playIntent || generation != _loadGeneration) {
        return;
      }
      if (_pauseForGuard(PlaybackBoundary.beforePlay)) return;
      if (_completed) {
        _completed = false;
        await _backend.seek(Duration.zero);
        if (!_disposed && generation == _loadGeneration) {
          position.value = Duration.zero;
        }
      }
      if (!_disposed &&
          intent == _playIntent &&
          generation == _loadGeneration &&
          !_pauseForGuard(PlaybackBoundary.beforePlay)) {
        await _backend.play();
      }
    } catch (error) {
      if (!_disposed) _handleBackendError(error);
    } finally {
      _toggleBusy = false;
    }
  }

  Future<void> pause() => _pause();

  Future<void> pauseForSleepTimer() => _pause(throwOnError: true);

  Future<void> _pause({bool throwOnError = false}) async {
    if (_disposed) return;
    _playIntent++;
    _wantsPlayback = false;
    final previousPause = _pauseInFlight;
    final completion = Completer<void>();
    _pauseInFlight = completion.future;
    try {
      if (previousPause != null) await previousPause;
      if (_disposed) return;
      await _backend.pause();
      if (!_disposed) isPlaying.value = false;
    } catch (_) {
      if (!_disposed) errorMessage.value = '未能暂停播放，请关闭应用以停止音频。';
      if (throwOnError) throw StateError('未能暂停音频，请关闭应用以停止播放。');
    } finally {
      if (identical(_pauseInFlight, completion.future)) _pauseInFlight = null;
      completion.complete();
    }
  }

  Future<void> seek(Duration value) async {
    if (!canPlay) return;
    if (_restored) {
      position.value = _clampPosition(value);
      return;
    }
    if (duration.value <= Duration.zero) return;
    final target = _clampPosition(value);
    final generation = _loadGeneration;
    try {
      _completed = false;
      await _backend.seek(target);
      if (!_disposed && generation == _loadGeneration) position.value = target;
    } catch (_) {
      if (!_disposed) errorMessage.value = '暂时无法跳转到该位置，请重试。';
    }
  }

  Duration _clampPosition(Duration value) => Duration(
    milliseconds: value.inMilliseconds.clamp(
      0,
      duration.value > Duration.zero
          ? duration.value.inMilliseconds
          : 0x7FFFFFFFFFFFFFFF,
    ),
  );

  Future<void> setVolume(double value) async {
    if (_disposed || !value.isFinite) return;
    final previous = volume.value;
    volume.value = value.clamp(0.0, 1.0);
    try {
      await _backend.setVolume(volume.value);
    } catch (_) {
      if (!_disposed) {
        volume.value = previous;
        errorMessage.value = '音量调整失败，请重试。';
      }
    }
  }

  void _selectRestored(Song? song, Duration savedPosition) {
    currentSong.value = song;
    duration.value = song?.duration ?? Duration.zero;
    position.value = song == null
        ? Duration.zero
        : _clampPosition(savedPosition);
    _restored = song != null;
  }

  Future<void> _clearSelection() async {
    _playbackGuard?.onManualSelection(null);
    final request = _beginSelection();
    ++_loadGeneration;
    ++_playIntent;
    _wantsPlayback = false;
    _loaded.value = false;
    _restored = false;
    _completed = false;
    isLoading.value = false;
    isPlaying.value = false;
    currentSong.value = null;
    position.value = Duration.zero;
    duration.value = Duration.zero;
    errorMessage.value = null;
    _resetNavigation();
    final work = _selectionTail.then((_) async {
      if (!_active(request)) return;
      if (_errorPause case final pending?) await pending;
      if (!_active(request)) return;
      try {
        await _backend.pause();
      } catch (_) {
        if (_active(request)) errorMessage.value = '未能暂停播放，请关闭应用以停止音频。';
      }
    });
    _selectionTail = work;
    await work;
  }

  bool _active(int request) => !_disposed && request == _selectionGeneration;

  List<Song> _unique(List<Song> songs) {
    final seen = <String>{};
    return songs.where((song) => seen.add(song.id)).toList();
  }

  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    _beginSelection();
    ++_loadGeneration;
    ++_playIntent;
    _wantsPlayback = false;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _backend.dispose();
  }

  @override
  void onClose() {
    unawaited(shutdown());
    super.onClose();
  }
}

enum _LoadResult { loaded, failed, cancelled }
