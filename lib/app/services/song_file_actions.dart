import 'dart:io';

import 'package:flutter/services.dart';

import '../data/models/song.dart';

class SongFileInfo {
  const SongFileInfo({required this.exists, this.bytes});
  final bool exists;
  final int? bytes;
}

class SongFileActions {
  SongFileActions({
    bool? isWindows,
    MethodChannel channel = const MethodChannel('hanmusic/desktop_media'),
  }) : isWindows = isWindows ?? Platform.isWindows,
       _channel = channel;

  final bool isWindows;
  final MethodChannel _channel;

  Future<SongFileInfo?> inspect(Song song) async {
    if (song.isOnline) return null;
    final stat = await File.fromUri(song.uri).stat();
    return SongFileInfo(
      exists: stat.type == FileSystemEntityType.file,
      bytes: stat.type == FileSystemEntityType.file ? stat.size : null,
    );
  }

  Future<void> reveal(Song song) async {
    if (!isWindows || song.isOnline || song.uri.scheme != 'file') {
      throw const FileSystemException('此歌曲不支持打开文件位置。');
    }
    if (song.isMissing || (await inspect(song))?.exists != true) {
      throw const FileSystemException('文件已不存在或无法访问。');
    }
    try {
      // The native Shell API selects the complete file PIDL. Paths never pass
      // through a command line, quoting rules, or Explorer's /select parser.
      final selected = await _channel
          .invokeMethod<bool>('revealFile', song.path)
          .timeout(const Duration(seconds: 10));
      if (selected != true) {
        throw const FileSystemException('无法打开文件位置，请稍后重试。');
      }
    } catch (_) {
      throw const FileSystemException('无法打开文件位置，请稍后重试。');
    }
  }
}
