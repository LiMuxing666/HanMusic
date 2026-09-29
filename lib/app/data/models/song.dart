class Song {
  const Song({required this.uri, required this.fileName});

  final Uri uri;
  final String fileName;

  String get path => uri.toFilePath(windows: true);
  String get extension {
    final dot = fileName.lastIndexOf('.');
    return dot < 0 ? '' : fileName.substring(dot + 1).toUpperCase();
  }

  String get title {
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }
}
