import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../models/song.dart';

const _windowsPickerOptions = WindowsOptions(lockParentWindow: true);

abstract interface class SongPicker {
  Future<Song?> pick();
}

abstract interface class LibraryPicker {
  Future<List<String>> pickFiles();
  Future<String?> pickDirectory();
}

class LocalLibraryPicker implements LibraryPicker {
  @override
  Future<List<String>> pickFiles() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: '导入音乐文件',
      windowsOptions: _windowsPickerOptions,
      type: FileType.custom,
      allowedExtensions: [
        'mp3',
        'flac',
        'wav',
        'm4a',
        'ogg',
        'aac',
        'opus',
        'ape',
        'aif',
        'aiff',
      ],
    );
    return files.map((file) => file.path).whereType<String>().toList();
  }

  @override
  Future<String?> pickDirectory() => FilePicker.getDirectoryPath(
    dialogTitle: '导入音乐文件夹（包含子文件夹）',
    windowsOptions: _windowsPickerOptions,
  );
}

class LocalSongPicker implements SongPicker {
  @override
  Future<Song?> pick() async {
    final file = await FilePicker.pickFile(
      windowsOptions: _windowsPickerOptions,
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
