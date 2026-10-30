import 'dart:async';

/// Recognition metadata only. Audio and the API token are never persisted here.
class MusicRecognitionResult {
  const MusicRecognitionResult({
    required this.title,
    required this.artist,
    this.album,
    this.releaseDate,
    this.songLink,
  });

  final String title;
  final String artist;
  final String? album;
  final String? releaseDate;
  final Uri? songLink;
}

class MusicRecognitionException implements Exception {
  const MusicRecognitionException(this.message, {this.cancelled = false});

  final String message;
  final bool cancelled;

  @override
  String toString() => message;
}

/// One signal per attempt; cancelled signals cannot be reused for another upload.
class RecognitionCancellation {
  final _completion = Completer<void>();

  bool get isCancelled => _completion.isCompleted;
  Future<void> get whenCancelled => _completion.future;

  void cancel() {
    if (!isCancelled) _completion.complete();
  }
}
