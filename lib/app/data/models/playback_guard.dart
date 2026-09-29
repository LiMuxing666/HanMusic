/// Synchronous checkpoints prevent a stop policy from racing the next source.
enum PlaybackBoundary { completion, error, beforePlay }

abstract interface class PlaybackGuard {
  bool shouldPause(PlaybackBoundary boundary, String? songId);
  void onManualSelection(String? nextSongId);
  void onManualPlayback();
}
