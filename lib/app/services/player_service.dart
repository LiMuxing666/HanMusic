import 'dart:async';

import 'package:get/get.dart';

import '../data/models/song.dart';
import '../data/sources/audio_backend.dart';

class PlayerService extends GetxService {
  PlayerService(this._backend) {
    _subscriptions.addAll([
      _backend.states.listen((state) {
        if (_disposed) return;
        _completed = state.completed;
        isPlaying.value = state.playing && !state.completed && _loaded.value;
      }),
      _backend.positions.listen((value) {
        if (!_disposed && !isLoading.value) position.value = value;
      }),
      _backend.durations.listen((value) {
        if (!_disposed && value != null) duration.value = value;
      }),
      _backend.errors.listen(_handleBackendError),
    ]);
  }

  final AudioBackend _backend;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final currentSong = Rxn<Song>();
  final isPlaying = false.obs;
  final isLoading = false.obs;
  final position = Duration.zero.obs;
  final duration = Duration.zero.obs;
  final volume = 0.7.obs;
  final errorMessage = RxnString();
  final _loaded = false.obs;
  bool _completed = false;
  bool _disposed = false;
  bool _toggleBusy = false;
  int _playIntent = 0;
  int _loadGeneration = 0;
  Future<void>? _errorPause;
  int _errorPauseGeneration = 0;

  bool get canPlay => !_disposed && _loaded.value && !isLoading.value;

  void _handleBackendError(Object error) {
    if (_disposed) return;
    _errorPauseGeneration = ++_loadGeneration;
    _playIntent++;
    _loaded.value = false;
    isPlaying.value = false;
    errorMessage.value = '音频播放中断，请重新选择有效的音频文件。';

    // Reserve the barrier before calling native code: pause may itself emit an
    // error. Coalesce those events instead of recursively requesting pauses.
    if (_errorPause != null) return;
    final completion = Completer<void>();
    _errorPause = completion.future;
    unawaited(_pauseAfterBackendError(completion));
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

  Future<void> open(Song song) async {
    if (_disposed || isLoading.value) return;
    final intent = ++_playIntent;
    final generation = ++_loadGeneration;
    isLoading.value = true;
    _loaded.value = false;
    _completed = false;
    errorMessage.value = null;
    isPlaying.value = false;
    currentSong.value = song;
    position.value = Duration.zero;
    duration.value = Duration.zero;
    try {
      // A late native pause must finish before a replacement source can start.
      if (_errorPause case final pendingPause?) await pendingPause;
      if (_disposed || generation != _loadGeneration) return;
      await _backend.pause();
      if (_disposed || generation != _loadGeneration) return;
      final length = await _backend
          .load(song.uri)
          .timeout(const Duration(seconds: 20));
      if (_disposed || generation != _loadGeneration) return;
      duration.value = length ?? Duration.zero;
      _loaded.value = true;
      await _backend.setVolume(volume.value);
      if (_disposed || generation != _loadGeneration) return;
      if (intent == _playIntent) await _backend.play();
    } catch (_) {
      if (_disposed) return;
      _loaded.value = false;
      isPlaying.value = false;
      errorMessage.value = '无法播放此文件，请检查文件是否损坏或已被移动。';
      // A decoder that failed midway must not keep playing a previous source.
      try {
        await _backend.pause();
      } catch (_) {
        // The original load error remains the actionable error.
      }
    } finally {
      if (!_disposed) isLoading.value = false;
    }
  }

  Future<void> togglePlayback() async {
    if (!canPlay || _toggleBusy) return;
    final intent = ++_playIntent;
    _toggleBusy = true;
    try {
      if (isPlaying.value) {
        await _backend.pause();
      } else {
        if (_completed) {
          await _backend.seek(Duration.zero);
          _completed = false;
        }
        if (!_disposed && intent == _playIntent) await _backend.play();
      }
    } catch (_) {
      if (!_disposed) errorMessage.value = '播放操作失败，请重新选择音频文件。';
    } finally {
      _toggleBusy = false;
    }
  }

  Future<void> pause() async {
    if (_disposed) return;
    _playIntent++;
    try {
      await _backend.pause();
      if (!_disposed) isPlaying.value = false;
    } catch (_) {
      if (!_disposed) errorMessage.value = '未能暂停播放，请关闭应用以停止音频。';
    }
  }

  Future<void> seek(Duration value) async {
    if (!canPlay || duration.value <= Duration.zero) return;
    final target = Duration(
      milliseconds: value.inMilliseconds.clamp(
        0,
        duration.value.inMilliseconds,
      ),
    );
    try {
      await _backend.seek(target);
      if (!_disposed) position.value = target;
    } catch (_) {
      if (!_disposed) errorMessage.value = '暂时无法跳转到该位置，请重试。';
    }
  }

  Future<void> setVolume(double value) async {
    if (_disposed) return;
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

  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
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
