import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../models/song.dart';

abstract interface class SongPicker {
  Future<Song?> pick();
}

class LocalSongPicker implements SongPicker {
  @override
  Future<Song?> pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'flac', 'wav', 'm4a', 'ogg', 'aac'],
    );
    if (file == null) return null;
    final path = file.path;
    if (path == null || !await File(path).exists()) {
      throw const FileSystemException('Selected audio file is unavailable.');
    }
    return Song(uri: File(path).absolute.uri, fileName: file.name);
  }
}
