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
  }) : sourceId = null,
       trackId = null;

  Song._online({
    required this.uri,
    required this.sourceId,
    required this.trackId,
    required String title,
    this.artist,
    this.album,
    this.duration,
  }) : fileName = title,
       trackTitle = title,
       artworkPath = null,
       isMissing = false;

  factory Song.online({
    required String sourceId,
    required String trackId,
    required String title,
    String? artist,
    String? album,
    Duration? duration,
  }) {
    _validateIdentity(sourceId);
    _validateIdentity(trackId);
    if (title.trim().isEmpty ||
        (duration != null && duration < Duration.zero)) {
      throw const FormatException('Invalid online song metadata.');
    }
    return Song._online(
      uri: _onlineUri(sourceId, trackId),
      sourceId: sourceId,
      trackId: trackId,
      title: title.trim(),
      artist: artist,
      album: album,
      duration: duration,
    );
  }

  final Uri uri;
  final String fileName;
  final String? trackTitle;
  final String? artist;
  final String? album;
  final Duration? duration;
  final String? artworkPath;
  final bool isMissing;
  final String? sourceId;
  final String? trackId;
  bool get isOnline => sourceId != null && trackId != null;

  /// Windows local paths are case-insensitive; online identifiers are not.
  String get id => uri.scheme == 'file'
      ? uri.normalizePath().toString().toLowerCase()
      : uri.toString();

  String get path =>
      isOnline ? '$sourceId / $trackId' : uri.toFilePath(windows: true);
  String get extension {
    if (isOnline) return '在线';
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
    if (isOnline) 'sourceId': sourceId,
    if (isOnline) 'trackId': trackId,
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
    if (uri.scheme == 'hanmusic') {
      final sourceId = text('sourceId');
      final trackId = text('trackId');
      final title = text('trackTitle');
      if (sourceId == null ||
          trackId == null ||
          title == null ||
          missing == true ||
          json['artworkPath'] != null) {
        throw const FormatException('Incomplete online song identity.');
      }
      final song = Song.online(
        sourceId: sourceId,
        trackId: trackId,
        title: title,
        artist: text('artist'),
        album: text('album'),
        duration: millis == null ? null : Duration(milliseconds: millis as int),
      );
      if (rawUri != song.uri.toString() || fileName != song.fileName) {
        throw const FormatException('Online song URI must be canonical.');
      }
      return song;
    }
    if (uri.scheme != 'file' ||
        json['sourceId'] != null ||
        json['trackId'] != null) {
      throw const FormatException(
        'Only local files or stable online identities can be saved.',
      );
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
  }) {
    if (isOnline) {
      if ((uri != null && uri != this.uri) ||
          isMissing == true ||
          artworkPath != null) {
        throw const FormatException(
          'Online identity cannot be replaced by a stream URI.',
        );
      }
      return Song.online(
        sourceId: sourceId!,
        trackId: trackId!,
        title: trackTitle ?? this.trackTitle!,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        duration: duration ?? this.duration,
      );
    }
    return Song(
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

  static Uri _onlineUri(String sourceId, String trackId) =>
      Uri(scheme: 'hanmusic', host: 'track', pathSegments: [sourceId, trackId]);

  static void _validateIdentity(String value) {
    if (value.isEmpty ||
        value.trim() != value ||
        value == '.' ||
        value == '..' ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('Invalid online song identity.');
    }
  }
}
