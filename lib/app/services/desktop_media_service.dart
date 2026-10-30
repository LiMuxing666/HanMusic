import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'player_service.dart';

/// Event-driven Windows media session and tray integration. Unsupported hosts
/// and native failures leave ordinary in-app playback available.
class DesktopMediaService extends GetxService {
  DesktopMediaService(
    this.player, {
    MethodChannel channel = const MethodChannel('hanmusic/desktop_media'),
    bool? enabled,
  }) : _channel = channel,
       _enabled = enabled ?? Platform.isWindows;

  final PlayerService player;
  final MethodChannel _channel;
  final bool _enabled;
  final trayAvailable = false.obs;
  final mediaControlsAvailable = false.obs;
  final _workers = <Worker>[];
  Future<void>? _starting;
  Future<void>? _publishing;
  Future<void>? _closing;
  Map<String, Object>? _pending;
  Map<String, Object>? _lastSent;
  bool _ready = false;
  bool _closed = false;
  bool _exitPending = false;
  bool _publishScheduled = false;

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    if (!_enabled || _closed) return;
    _channel.setMethodCallHandler(_handleCall);
    try {
      final capabilities = await _channel
          .invokeMapMethod<String, Object?>('initialize')
          .timeout(const Duration(seconds: 2));
      if (_closed) return;
      trayAvailable.value = capabilities?['tray'] == true;
      mediaControlsAvailable.value = capabilities?['mediaControls'] == true;
      _ready = trayAvailable.value || mediaControlsAvailable.value;
      if (!_ready) return;
      _workers.addAll([
        ever(player.currentSong, (_) => _schedulePublish()),
        ever(player.queue, (_) => _schedulePublish()),
        ever(player.isPlaying, (_) => _schedulePublish()),
        ever(player.isLoading, (_) => _schedulePublish()),
        ever(player.errorMessage, (_) => _schedulePublish()),
      ]);
      _pending = _snapshot();
      await _publish();
    } catch (_) {
      // MissingPluginException covers non-Windows runners and test harnesses.
      _ready = false;
      trayAvailable.value = false;
      mediaControlsAvailable.value = false;
    }
  }

  bool get _canRetry {
    final song = player.currentSong.value;
    return !player.isLoading.value &&
        !player.isPlaying.value &&
        !player.canPlay &&
        song != null &&
        !song.isMissing &&
        player.queue.any((item) => item.id == song.id && !item.isMissing);
  }

  Map<String, Object> _snapshot() {
    final song = player.currentSong.value;
    final commands = !_exitPending && !_closed;
    final loading = player.isLoading.value;
    return {
      'hasTrack': song != null,
      'title': _text(song?.title),
      'artist': _text(song?.artist),
      'album': _text(song?.album),
      'playing': player.isPlaying.value,
      'enabled': commands,
      'canPlay': commands && !loading && (player.canPlay || _canRetry),
      'canPause': commands && (player.isPlaying.value || loading),
      'canNavigate': commands && !loading && player.queue.isNotEmpty,
    };
  }

  static String _text(String? value) =>
      String.fromCharCodes((value?.trim() ?? '').runes.take(512));

  void _schedulePublish() {
    if (!_ready || _closed || _publishScheduled) return;
    _publishScheduled = true;
    scheduleMicrotask(() {
      _publishScheduled = false;
      if (!_ready || _closed) return;
      _pending = _snapshot();
      unawaited(_publish());
    });
  }

  Future<void> _publish() => _publishing ??= _drain().whenComplete(() {
    _publishing = null;
    if (_pending != null && _ready && !_closed) unawaited(_publish());
  });

  Future<void> _drain() async {
    while (!_closed && _ready && _pending != null) {
      final state = _pending!;
      _pending = null;
      if (mapEquals(state, _lastSent)) continue;
      try {
        await _channel
            .invokeMethod<bool>('updateState', state)
            .timeout(const Duration(seconds: 2));
        _lastSent = state;
      } catch (_) {
        // Retry the latest snapshot on the next actual player change.
        _lastSent = null;
      }
    }
  }

  Future<void> _handleCall(MethodCall call) async {
    if (!_ready || _closed || _exitPending || call.method != 'action') return;
    final action = call.arguments;
    try {
      switch (action) {
        case 'play':
          if (!player.isPlaying.value) await _playOrRetry();
        case 'pause':
          if (player.isPlaying.value || player.isLoading.value) {
            await player.pause();
          }
        case 'toggle':
          if (!player.isLoading.value) {
            if (player.isPlaying.value) {
              await player.pause();
            } else {
              await _playOrRetry();
            }
          }
        case 'next':
        case 'previous':
          if (!player.isLoading.value && player.queue.isNotEmpty) {
            if (action == 'next') {
              await player.next();
            } else {
              await player.previous();
            }
          }
      }
    } catch (_) {
      // PlayerService owns playback errors; never throw through a native event.
    }
  }

  Future<void> _playOrRetry() async {
    if (player.isLoading.value) return;
    if (_canRetry) {
      await player.playAt(player.currentIndex);
    } else if (player.canPlay) {
      await player.togglePlayback();
    }
  }

  void beginExit() {
    if (_closed) return;
    _exitPending = true;
    _schedulePublish();
  }

  void cancelExit() {
    if (_closed) return;
    _exitPending = false;
    _schedulePublish();
  }

  /// Returns false if no usable tray icon exists; the native side never hides
  /// the only window unless the user can restore it from that icon.
  Future<bool> hideToTray() async {
    if (!_ready || _closed || _exitPending || !trayAvailable.value) {
      return false;
    }
    try {
      return await _channel
              .invokeMethod<bool>('hideToTray')
              .timeout(const Duration(seconds: 2)) ==
          true;
    } catch (_) {
      return false;
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _ready = false;
    _pending = null;
    trayAvailable.value = false;
    mediaControlsAvailable.value = false;
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    if (!_enabled || _starting == null) return;
    _channel.setMethodCallHandler(null);
    try {
      // Native channel calls are ordered. Dispose is sent after any initial or
      // state update request, including when close races initialization.
      await _channel
          .invokeMethod<void>('dispose')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  void onClose() {
    unawaited(close());
    super.onClose();
  }
}
