class Song {
  const Song({
    required this.uri,
    required this.fileName,
    this.trackTitle,
    this.artist,
    this.album,
    this.duration,
    this.artworkPath,
    this.isMissing = false,
  });

  final Uri uri;
  final String fileName;
  final String? trackTitle;
  final String? artist;
  final String? album;
  final Duration? duration;
  final String? artworkPath;
  final bool isMissing;

  /// Windows local paths are case-insensitive; online identifiers are not.
  String get id => uri.scheme == 'file'
      ? uri.normalizePath().toString().toLowerCase()
      : uri.toString();

  String get path => uri.toFilePath(windows: true);
  String get extension {
    final dot = fileName.lastIndexOf('.');
    return dot < 0 ? '' : fileName.substring(dot + 1).toUpperCase();
  }

  String get title {
    final tagged = trackTitle?.trim();
    if (tagged != null && tagged.isNotEmpty) return tagged;
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }

  Map<String, Object?> toJson() => {
    'uri': uri.toString(),
    'fileName': fileName,
    if (trackTitle != null) 'trackTitle': trackTitle,
    if (artist != null) 'artist': artist,
    if (album != null) 'album': album,
    if (duration != null) 'durationMs': duration!.inMilliseconds,
    if (artworkPath != null) 'artworkPath': artworkPath,
    'isMissing': isMissing,
  };

  factory Song.fromJson(Map<String, dynamic> json) {
    final rawUri = json['uri'];
    final fileName = json['fileName'];
    if (rawUri is! String || fileName is! String || fileName.isEmpty) {
      throw const FormatException('Song requires a URI and file name.');
    }
    final uri = Uri.tryParse(rawUri);
    if (uri == null || !uri.hasScheme) {
      throw const FormatException('Song URI must be absolute.');
    }
    String? text(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String) throw FormatException('Invalid song $key.');
      return value;
    }

    final millis = json['durationMs'];
    if (millis != null && (millis is! int || millis < 0)) {
      throw const FormatException('Invalid song duration.');
    }
    final missing = json['isMissing'];
    if (missing != null && missing is! bool) {
      throw const FormatException('Invalid missing-file flag.');
    }
    return Song(
      uri: uri,
      fileName: fileName,
      trackTitle: text('trackTitle'),
      artist: text('artist'),
      album: text('album'),
      duration: millis == null ? null : Duration(milliseconds: millis as int),
      artworkPath: text('artworkPath'),
      isMissing: missing as bool? ?? false,
    );
  }

  Song copyWith({
    Uri? uri,
    String? fileName,
    String? trackTitle,
    String? artist,
    String? album,
    Duration? duration,
    String? artworkPath,
    bool? isMissing,
  }) => Song(
    uri: uri ?? this.uri,
    fileName: fileName ?? this.fileName,
    trackTitle: trackTitle ?? this.trackTitle,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    duration: duration ?? this.duration,
    artworkPath: artworkPath ?? this.artworkPath,
    isMissing: isMissing ?? this.isMissing,
  );
}
