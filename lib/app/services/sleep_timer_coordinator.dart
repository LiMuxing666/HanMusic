import 'package:get/get.dart';

import '../data/models/playback_guard.dart';
import 'player_service.dart';
import 'timer_service.dart';

/// Connects the timer policy to synchronous playback boundaries, without giving
/// the timer ownership of queue operations or persistence.
class SleepTimerCoordinator extends GetxService implements PlaybackGuard {
  SleepTimerCoordinator({
    required PlayerService player,
    required TimerService timer,
  }) : _player = player,
       _timer = timer {
    _player.attachPlaybackGuard(this);
  }

  final PlayerService _player;
  final TimerService _timer;
  bool _disposed = false;

  @override
  bool shouldPause(PlaybackBoundary boundary, String? songId) =>
      !_disposed &&
      _timer.consumeIfDue(
        finishedSongId: boundary == PlaybackBoundary.beforePlay ? null : songId,
      );

  @override
  void onManualSelection(String? nextSongId) {
    if (!_disposed) _timer.handleManualSelection(nextSongId);
  }

  @override
  void onManualPlayback() {
    if (!_disposed) _timer.acknowledgeManualPlayback();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _player.detachPlaybackGuard(this);
    _timer.cancel();
  }

  @override
  void onClose() {
    dispose();
    super.onClose();
  }
}
