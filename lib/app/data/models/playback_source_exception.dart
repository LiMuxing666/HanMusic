/// The message must already be safe for display: no URLs, credentials or bodies.
class PlaybackSourceException implements Exception {
  const PlaybackSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}
