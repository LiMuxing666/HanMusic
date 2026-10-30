import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

import '../data/models/lyrics.dart';
import '../data/models/song.dart';

enum LyricsLoadState { idle, loading, ready, notFound, unsupported, error }

typedef LyricsFileReader =
    Future<List<int>?> Function(String path, int maxBytes);

/// Reads a sidecar only; audio files and the user's lyric files stay untouched.
class LyricsService extends GetxService {
  LyricsService({LyricsFileReader? readFile})
    : _readFile = readFile ?? _readBounded;

  static const maxFileBytes = 1024 * 1024;
  static const readTimeout = Duration(seconds: 5);

  final LyricsFileReader _readFile;
  final state = LyricsLoadState.idle.obs;
  final document = Rxn<LyricsDocument>();
  final message = RxnString('选择一首歌曲查看歌词。');
  final filePath = RxnString();
  int _generation = 0;
  bool _closed = false;

  Future<void> selectSong(Song? song) async {
    if (_closed) return;
    final generation = ++_generation;
    document.value = null;
    filePath.value = null;
    if (song == null) {
      state.value = LyricsLoadState.idle;
      message.value = '选择一首歌曲查看歌词。';
      return;
    }
    if (song.isOnline || song.uri.scheme != 'file') {
      state.value = LyricsLoadState.unsupported;
      message.value = song.isOnline ? '在线歌曲尚未关联本地歌词。' : '此歌曲暂不支持同名本地歌词。';
      return;
    }
    state.value = LyricsLoadState.loading;
    message.value = '正在读取歌词…';
    try {
      final lyricPath = path.setExtension(File.fromUri(song.uri).path, '.lrc');
      filePath.value = lyricPath;
      final bytes = await _readFile(
        lyricPath,
        maxFileBytes,
      ).timeout(readTimeout);
      if (!_active(generation)) return;
      if (bytes == null) {
        state.value = LyricsLoadState.notFound;
        message.value = '未找到同名歌词。将同名 .lrc 文件放到歌曲所在文件夹即可自动读取。';
        return;
      }
      if (bytes.length > maxFileBytes) throw const _LyricsTooLarge();
      final text = _decode(bytes);
      final parsed = LyricsDocument.parse(text);
      if (!parsed.timedLines.any((line) => line.text.trim().isNotEmpty) &&
          !parsed.plainLines.any((line) => line.trim().isNotEmpty)) {
        state.value = LyricsLoadState.notFound;
        message.value = '歌词文件没有可显示的内容。';
        return;
      }
      document.value = parsed;
      message.value = parsed.isTimed ? null : '纯文本歌词，未检测到有效时间标签。';
      state.value = LyricsLoadState.ready;
    } on _LyricsTooLarge {
      if (_active(generation)) _fail('歌词文件超过 1 MB，请使用较小的 LRC 文件。');
    } on FormatException {
      if (_active(generation)) {
        _fail('无法解码歌词。请将文件保存为 UTF-8 或 GBK 文本后重试。');
      }
    } on TimeoutException {
      if (_active(generation)) _fail('读取歌词超时，请检查文件位置后重试。');
    } on FileSystemException {
      if (_active(generation)) _fail('无法读取歌词，请检查文件访问权限后重试。');
    } catch (_) {
      if (_active(generation)) _fail('暂时无法读取歌词，请稍后重试。');
    }
  }

  bool _active(int generation) => !_closed && generation == _generation;

  void _fail(String value) {
    document.value = null;
    state.value = LyricsLoadState.error;
    message.value = value;
  }

  static String _decode(List<int> bytes) {
    // UTF-16's BOM can otherwise accidentally decode as valid GBK glyphs.
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff))) {
      throw const FormatException('Unsupported UTF-16 lyrics.');
    }
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      text = gbk.decode(bytes, allowMalformed: false);
    }
    if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]').hasMatch(text)) {
      throw const FormatException('Lyrics must be a text file.');
    }
    return text;
  }

  static Future<List<int>?> _readBounded(String filePath, int maxBytes) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    if (await file.length() > maxBytes) throw const _LyricsTooLarge();
    final bytes = <int>[];
    // The bounded stream also protects against growth after the length check.
    await for (final chunk in file.openRead(0, maxBytes + 1)) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) throw const _LyricsTooLarge();
    }
    return bytes;
  }

  @override
  void onClose() {
    _closed = true;
    _generation++;
    super.onClose();
  }
}

class _LyricsTooLarge implements Exception {
  const _LyricsTooLarge();
}
