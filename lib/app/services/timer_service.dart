import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../data/models/sleep_timer_mode.dart';

/// A sleep timer whose remaining time is based on the clock, not tick counts.
class TimerService extends GetxService {
  TimerService({
    required Future<void> Function() onExpired,
    DateTime Function()? now,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) : _onExpired = onExpired,
       _now = now ?? DateTime.now,
       _onError = onError;

  final Future<void> Function() _onExpired;
  final DateTime Function() _now;
  final void Function(Object error, StackTrace stackTrace)? _onError;

  final Rxn<Duration> remaining = Rxn<Duration>();
  final Rxn<DateTime> deadline = Rxn<DateTime>();
  final mode = SleepTimerMode.off.obs;
  final currentSongId = RxnString();
  final statusMessage = RxnString();

  Timer? _ticker;
  int _generation = 0;
  int? _pendingExpiration;
  bool _closed = false;

  bool get isActive => mode.value != SleepTimerMode.off;
  bool get canExtend =>
      !_closed &&
      mode.value == SleepTimerMode.countdown &&
      deadline.value != null &&
      _now().isBefore(deadline.value!);

  void start(Duration duration) {
    if (_closed) {
      throw StateError('Cannot start a closed sleep timer.');
    }
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', 'Must be positive.');
    }

    cancel();
    final generation = _generation;
    mode.value = SleepTimerMode.countdown;
    deadline.value = _now().add(duration);
    remaining.value = duration;
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateRemaining(generation),
    );
  }

  void cancel() {
    _generation++;
    _pendingExpiration = null;
    _stopTicker();
    deadline.value = null;
    remaining.value = null;
    currentSongId.value = null;
    mode.value = SleepTimerMode.off;
    statusMessage.value = null;
  }

  void startEndOfTrack(String songId) {
    if (_closed) throw StateError('Cannot start a closed sleep timer.');
    if (songId.trim().isEmpty) {
      throw ArgumentError.value(songId, 'songId', 'Must identify a track.');
    }
    cancel();
    currentSongId.value = songId;
    mode.value = SleepTimerMode.endOfTrack;
  }

  /// Extend the original deadline; an overdue timer must never be revived.
  bool extend10Minutes() {
    if (!canExtend) {
      checkDeadline();
      return false;
    }
    final extendedDeadline = deadline.value!.add(const Duration(minutes: 10));
    _generation++;
    _pendingExpiration = null;
    _stopTicker();
    final generation = _generation;
    deadline.value = extendedDeadline;
    remaining.value = extendedDeadline.difference(_now());
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateRemaining(generation),
    );
    return true;
  }

  /// A synchronous guard used before completion/error advancement or play.
  /// Pending expiry also blocks advancement until its pause callback settles.
  bool consumeIfDue({String? finishedSongId}) {
    if (_closed) return false;
    _updateRemaining(_generation);
    if (mode.value == SleepTimerMode.endOfTrack &&
        finishedSongId != null &&
        finishedSongId == currentSongId.value) {
      _expire(_generation);
    }
    return _pendingExpiration == _generation;
  }

  void handleManualSelection(String? nextSongId) {
    if (mode.value == SleepTimerMode.endOfTrack &&
        nextSongId != currentSongId.value) {
      cancel();
      statusMessage.value = '已切换曲目，播完当前曲目的定时已取消。';
    }
  }

  /// An explicit new play request can supersede a previously consumed expiry.
  void acknowledgeManualPlayback() {
    if (mode.value == SleepTimerMode.off && _pendingExpiration != null) {
      _generation++;
      _pendingExpiration = null;
    }
  }

  /// Also call this when the application resumes after suspension.
  void checkDeadline() => _updateRemaining(_generation);

  void _updateRemaining(int generation) {
    if (_closed || generation != _generation) return;
    final currentDeadline = deadline.value;
    if (currentDeadline == null) return;

    final timeLeft = currentDeadline.difference(_now());
    if (timeLeft > Duration.zero) {
      remaining.value = timeLeft;
      return;
    }

    _expire(generation);
  }

  void _expire(int generation) {
    if (_closed ||
        generation != _generation ||
        _pendingExpiration == generation) {
      return;
    }
    _stopTicker();
    _pendingExpiration = generation;
    deadline.value = null;
    remaining.value = null;
    currentSongId.value = null;
    mode.value = SleepTimerMode.off;
    statusMessage.value = '正在暂停播放…';
    unawaited(_notifyExpired(generation));
  }

  Future<void> _notifyExpired(int generation) async {
    // A cancellation or replacement can invalidate an already queued expiry.
    await Future<void>.value();
    if (_closed || generation != _generation) return;

    try {
      await _onExpired();
      if (!_closed && generation == _generation) {
        statusMessage.value = '定时已停止播放';
      }
    } catch (error, stackTrace) {
      if (_closed || generation != _generation) return;
      statusMessage.value = '暂停失败，请关闭应用以停止音频。';
      try {
        if (_onError case final onError?) {
          onError(error, stackTrace);
        } else {
          debugPrint('Sleep timer expiry failed: $error\n$stackTrace');
        }
      } catch (reportingError, reportingStack) {
        // Even a failing error reporter must not leak an asynchronous error.
        debugPrint(
          'Sleep timer error handler failed: $reportingError\n$reportingStack',
        );
      }
    } finally {
      if (_pendingExpiration == generation) _pendingExpiration = null;
    }
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void onClose() {
    _closed = true;
    cancel();
    super.onClose();
  }
}
