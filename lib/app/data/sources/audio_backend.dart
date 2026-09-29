import 'dart:async';

class BackendPlaybackState {
  const BackendPlaybackState({
    required this.playing,
    this.loading = false,
    this.completed = false,
  });

  final bool playing;
  final bool loading;
  final bool completed;
}

/// Service boundary: native SDK types never reach the controller or view.
abstract interface class AudioBackend {
  Stream<BackendPlaybackState> get states;
  Stream<Duration> get positions;
  Stream<Duration?> get durations;
  Stream<Object> get errors;
  Future<Duration?> load(Uri uri);

  /// Completes when play is requested, not when the whole track has finished.
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> dispose();
}
