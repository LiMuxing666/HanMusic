import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

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

  Timer? _ticker;
  int _generation = 0;
  bool _closed = false;

  void start(Duration duration) {
    if (_closed) {
      throw StateError('Cannot start a closed sleep timer.');
    }
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', 'Must be positive.');
    }

    cancel();
    final generation = _generation;
    deadline.value = _now().add(duration);
    remaining.value = duration;
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateRemaining(generation),
    );
  }

  void cancel() {
    _generation++;
    _stopTicker();
    deadline.value = null;
    remaining.value = null;
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

    _stopTicker();
    deadline.value = null;
    remaining.value = null;
    unawaited(_notifyExpired(generation));
  }

  Future<void> _notifyExpired(int generation) async {
    // A cancellation or replacement can invalidate an already queued expiry.
    await Future<void>.value();
    if (_closed || generation != _generation) return;

    try {
      await _onExpired();
    } catch (error, stackTrace) {
      if (_closed || generation != _generation) return;
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
