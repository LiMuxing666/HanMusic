import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;

import '../models/playlist.dart';
import '../models/song.dart';
import 'local_library_repository.dart';

enum PlaylistTransferFormat { hanmusicJson, m3u8 }

/// A portable metadata snapshot; never contains playable HTTP URLs or audio.
class PlaylistTransferDocument {
  const PlaylistTransferDocument({
    required this.name,
    required this.songs,
    this.formatLabel = 'HanMusic JSON',
    this.skippedCount = 0,
    this.duplicateCount = 0,
  });

  final String name;
  final List<Song> songs;
  final String formatLabel;
  final int skippedCount;
  final int duplicateCount;
}

class PlaylistTransferCodec {
  static const format = 'hanmusic-playlist';
  static const version = 1;
  static const maxFileBytes = 4 * 1024 * 1024;
  static const maxSongs = 5000;
  static const extension = '.hanmusic.json';
  static const m3u8Extension = '.m3u8';
  static const maxTextLines = 20000;
  static const _songKeys = {
    'uri',
    'fileName',
    'trackTitle',
    'artist',
    'album',
    'durationMs',
    'isMissing',
    'sourceId',
    'trackId',
  };

  static List<int> encode({
    required String name,
    required List<Song> songs,
    PlaylistTransferFormat outputFormat = PlaylistTransferFormat.hanmusicJson,
  }) {
    if (outputFormat == PlaylistTransferFormat.m3u8) {
      return _encodeM3u8(name, songs);
    }
    final document = _validate(name, songs);
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'format': format,
        'version': version,
        'playlist': {
          'name': document.name,
          'songs': [for (final song in document.songs) _portableSong(song)],
        },
      }),
    );
    if (bytes.length > maxFileBytes) {
      throw const FormatException('歌单文件超过 4 MB，请减少歌曲后重试。');
    }
    return bytes;
  }

  static PlaylistTransferDocument decode(
    List<int> bytes, {
    String? sourcePath,
  }) {
    if (bytes.isEmpty || bytes.length > maxFileBytes) {
      throw const FormatException('请选择不超过 4 MB 的 JSON、M3U 或 M3U8 歌单文件。');
    }
    if (sourcePath != null) {
      final suffix = path.windows.extension(sourcePath).toLowerCase();
      if (suffix == '.m3u' || suffix == m3u8Extension) {
        return _decodeM3u(
          bytes,
          sourcePath,
          strictUtf8: suffix == m3u8Extension,
        );
      }
      if (suffix != '.json') {
        throw const FormatException('请选择 JSON、M3U 或 M3U8 歌单文件。');
      }
    }
    dynamic value;
    try {
      var text = utf8.decode(bytes, allowMalformed: false);
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      value = jsonDecode(text);
    } on FormatException {
      throw const FormatException('歌单文件不是有效的 UTF-8 JSON，请重新选择。');
    }
    if (value is! Map<String, dynamic> ||
        !_exactKeys(value, const {'format', 'version', 'playlist'}) ||
        value['format'] != format ||
        value['version'] is! int) {
      throw const FormatException('这不是受支持的 HanMusic 歌单文件。');
    }
    if (value['version'] != version) {
      throw const FormatException('歌单文件版本不受支持，请使用兼容版本的 HanMusic。');
    }
    final playlist = value['playlist'];
    if (playlist is! Map<String, dynamic> ||
        !_exactKeys(playlist, const {'name', 'songs'}) ||
        playlist['name'] is! String ||
        playlist['songs'] is! List) {
      throw const FormatException('歌单名称或歌曲列表格式无效。');
    }
    final rawSongs = playlist['songs'] as List;
    if (rawSongs.length > maxSongs) {
      throw const FormatException('单个歌单最多导入 5000 首歌曲。');
    }
    final songs = <Song>[];
    for (var index = 0; index < rawSongs.length; index++) {
      final item = rawSongs[index];
      if (item is! Map<String, dynamic> ||
          !item.keys.every(_songKeys.contains)) {
        throw FormatException('第 ${index + 1} 首歌曲格式无效或包含不支持的字段。');
      }
      try {
        songs.add(_checkedSong(Song.fromJson(item)));
      } on FormatException {
        throw FormatException('第 ${index + 1} 首歌曲的路径、在线标识或元信息无效。');
      }
    }
    return _validate(playlist['name'] as String, songs);
  }

  static PlaylistTransferDocument _decodeM3u(
    List<int> bytes,
    String sourcePath, {
    required bool strictUtf8,
  }) {
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff))) {
      throw const FormatException('歌单不支持 UTF-16，请另存为 UTF-8 M3U8。');
    }
    String text;
    var encoding = 'UTF-8';
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      if (strictUtf8 ||
          (bytes.length >= 3 &&
              bytes[0] == 0xef &&
              bytes[1] == 0xbb &&
              bytes[2] == 0xbf)) {
        throw const FormatException('M3U8 必须使用 UTF-8 编码，请重新选择。');
      }
      try {
        text = gbk.decode(bytes, allowMalformed: false);
        encoding = 'GBK';
      } on FormatException {
        throw const FormatException('M3U 不是有效的 UTF-8 或 GBK 文本。');
      }
    }
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]').hasMatch(text)) {
      throw const FormatException('歌单含有不支持的控制字符。');
    }
    final songs = <Song>[];
    final ids = <String>{};
    var skipped = 0, duplicates = 0, entries = 0, lines = 0;
    String? title;
    Duration? duration;
    for (final rawLine in LineSplitter.split(text)) {
      if (++lines > maxTextLines || rawLine.length > 4096) {
        throw const FormatException('歌单行数或单行长度超出限制。');
      }
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.toUpperCase().startsWith('#EXT-X-')) {
        throw const FormatException('暂不支持 HLS 网络流清单，请选择本地音频歌单。');
      }
      if (line.startsWith('#')) {
        if (line.toUpperCase().startsWith('#EXTINF:')) {
          title = null;
          duration = null;
          final comma = line.indexOf(',');
          if (comma >= 0) {
            final label = line.substring(comma + 1).trim();
            if (label.isNotEmpty) title = label;
            final seconds = double.tryParse(line.substring(8, comma).trim());
            if (seconds != null &&
                seconds.isFinite &&
                seconds >= 0 &&
                seconds <= const Duration(days: 365).inSeconds) {
              duration = Duration(milliseconds: (seconds * 1000).round());
            }
          }
        }
        continue;
      }
      if (++entries > maxSongs) {
        throw const FormatException('单个歌单最多读取 5000 条歌曲路径。');
      }
      final uri = _m3uLocalUri(line, sourcePath: sourcePath);
      if (uri == null) {
        skipped++;
      } else {
        final song = _checkedSong(
          Song(
            uri: uri,
            fileName: path.windows.basename(uri.toFilePath(windows: true)),
            trackTitle: title,
            duration: duration,
            isMissing: true,
          ),
        );
        if (ids.add(song.id)) {
          songs.add(song);
        } else {
          duplicates++;
        }
      }
      // Metadata applies only to its next entry, including a skipped entry.
      title = null;
      duration = null;
    }
    if (songs.isEmpty) {
      throw FormatException('未找到可导入的本地音频，已跳过 $skipped 条不支持的路径。');
    }
    var name = path.windows.basenameWithoutExtension(sourcePath).trim();
    name = String.fromCharCodes(name.runes.take(100));
    if (name.isEmpty) name = '导入的歌单';
    return PlaylistTransferDocument(
      name: Playlist.validateName(name),
      songs: List.unmodifiable(songs),
      formatLabel: '${strictUtf8 ? 'M3U8' : 'M3U'} · $encoding',
      skippedCount: skipped,
      duplicateCount: duplicates,
    );
  }

  /// Accept only drive-qualified local audio, resolving ordinary relative
  /// paths against the selected playlist. No network/UNC/device stat is made.
  static Uri? _m3uLocalUri(String value, {String? sourcePath}) {
    try {
      var text = value.trim();
      if (text.startsWith('"') && text.endsWith('"') && text.length >= 2) {
        text = text.substring(1, text.length - 1);
      }
      if (RegExp(r'[\x00-\x1f\x7f<>"|?*]').hasMatch(text)) return null;
      if (text.toLowerCase().startsWith('file:')) {
        final uri = Uri.tryParse(text);
        if (uri == null ||
            uri.host.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment ||
            uri.userInfo.isNotEmpty) {
          return null;
        }
        text = uri.toFilePath(windows: true);
      } else if (!RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(text)) {
        if (text.contains(':') ||
            text.startsWith('/') ||
            text.startsWith(r'\')) {
          return null;
        }
        if (sourcePath == null ||
            !RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(sourcePath)) {
          return null;
        }
        text = path.windows.join(path.windows.dirname(sourcePath), text);
      }
      text = path.windows.normalize(text);
      if (!RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(text) ||
          text.substring(2).contains(':') ||
          RegExp(r'[\x00-\x1f\x7f<>"|?*]').hasMatch(text) ||
          !LocalLibraryRepository.supportedExtensions.contains(
            path.windows.extension(text).toLowerCase(),
          )) {
        return null;
      }
      for (final component in path.windows.split(text).skip(1)) {
        if (component.endsWith('.') ||
            component.endsWith(' ') ||
            RegExp(
              r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
              caseSensitive: false,
            ).hasMatch(component)) {
          return null;
        }
      }
      return Uri.file(text, windows: true);
    } on FormatException {
      return null;
    } on UnsupportedError {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  static bool canExportM3u8(Song song) =>
      !song.isOnline &&
      song.uri.scheme == 'file' &&
      _m3uLocalUri(song.uri.toString()) != null;

  static List<int> _encodeM3u8(String name, List<Song> songs) {
    final document = _validate(name, songs);
    final local = document.songs.where(canExportM3u8).toList(growable: false);
    if (local.isEmpty) {
      throw const FormatException('没有可导出的本地音频，请使用 JSON 保存完整歌单。');
    }
    final text = StringBuffer('#EXTM3U\r\n');
    for (final song in local) {
      final duration = song.duration == null
          ? '-1'
          : (song.duration!.inMilliseconds / 1000).toString();
      final metadata = '#EXTINF:$duration,${song.title}';
      if (metadata.length > 4096) {
        throw const FormatException('歌曲标题过长，无法写入 M3U8，请使用 JSON 导出。');
      }
      text.writeln('$metadata\r');
      text.writeln(
        '${_m3uLocalUri(song.uri.toString())!.toFilePath(windows: true)}\r',
      );
    }
    final bytes = utf8.encode(text.toString());
    if (bytes.length > maxFileBytes) {
      throw const FormatException('歌单文件超过 4 MB，请减少歌曲后重试。');
    }
    return bytes;
  }

  static bool _exactKeys(Map<String, dynamic> value, Set<String> keys) =>
      value.length == keys.length && value.keys.every(keys.contains);

  static Map<String, Object?> _portableSong(Song song) =>
      song.toJson()..remove('artworkPath'); // Machine-specific thumbnail cache.

  static Song _checkedSong(Song song) {
    final checked = Playlist.validateSong(Song.fromJson(_portableSong(song)));
    for (final entry in _portableSong(checked).entries) {
      if (entry.value case final String text) {
        if (text.length > 4096 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) {
          throw const FormatException('歌曲字段过长或包含控制字符。');
        }
      }
    }
    if ((checked.duration?.inMilliseconds ?? 0) >
        const Duration(days: 365).inMilliseconds) {
      throw const FormatException('歌曲时长超出可支持范围。');
    }
    return checked;
  }

  static PlaylistTransferDocument _validate(String name, List<Song> songs) {
    final checkedName = Playlist.validateName(name);
    if (songs.length > maxSongs) {
      throw const FormatException('单个歌单最多包含 5000 首歌曲。');
    }
    final ids = <String>{};
    final checked = <Song>[];
    for (final song in songs) {
      final current = _checkedSong(song);
      if (!ids.add(current.id)) {
        throw const FormatException('歌单包含重复歌曲，未导入任何内容。');
      }
      checked.add(current);
    }
    return PlaylistTransferDocument(
      name: checkedName,
      songs: List.unmodifiable(checked),
    );
  }

  static String uniqueName(String name, Iterable<String> existingNames) {
    final base = Playlist.validateName(name);
    final existing = existingNames.map((value) => value.toLowerCase()).toSet()
      ..add(Playlist.favoritesName.toLowerCase());
    if (!existing.contains(base.toLowerCase())) return base;
    for (var number = 2; ; number++) {
      final suffix = ' ($number)';
      final shortened = String.fromCharCodes(
        base.runes.take(100 - suffix.length),
      );
      final candidate = '$shortened$suffix';
      if (!existing.contains(candidate.toLowerCase())) return candidate;
    }
  }

  static String suggestedFileName(
    String name, {
    PlaylistTransferFormat outputFormat = PlaylistTransferFormat.hanmusicJson,
  }) {
    final safe = Playlist.validateName(name)
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    final suffix = outputFormat == PlaylistTransferFormat.m3u8
        ? m3u8Extension
        : extension;
    return 'HanMusic-${String.fromCharCodes(safe.runes.take(70))}$suffix';
  }
}

/// Injection boundary for native dialogs and disk I/O.
abstract interface class PlaylistTransferFiles {
  Future<String?> pickImport();
  Future<String?> pickExport(String suggestedFileName);
  Future<List<int>> read(String filePath, int maxBytes);
  Future<bool> localFileExists(Uri uri);

  /// A writer must re-check [canCommit] immediately before its final write.
  /// A false result must never modify a previously existing user file.
  Future<String> write(
    String filePath,
    List<int> bytes, {
    required bool Function() canCommit,
  });
}

class LocalPlaylistTransferFiles implements PlaylistTransferFiles {
  static const _options = WindowsOptions(lockParentWindow: true);

  @override
  Future<bool> localFileExists(Uri uri) =>
      uri.scheme == 'file' ? File.fromUri(uri).exists() : Future.value(false);

  @override
  Future<String?> pickImport() async => (await FilePicker.pickFile(
    dialogTitle: '导入 JSON / M3U / M3U8 歌单',
    windowsOptions: _options,
    type: FileType.custom,
    allowedExtensions: ['json', 'm3u', 'm3u8'],
  ))?.path;

  @override
  Future<String?> pickExport(String suggestedFileName) async {
    // file_picker 13 saveFile writes bytes before returning. Choosing a folder
    // instead lets us enforce the exit guard before creating the final file.
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择导出文件夹：$suggestedFileName',
      windowsOptions: _options,
    );
    return directory == null ? null : path.join(directory, suggestedFileName);
  }

  @override
  Future<List<int>> read(String filePath, int maxBytes) async {
    final file = File(filePath);
    if (await file.length() > maxBytes) {
      throw const FormatException('歌单文件超过 4 MB，未导入任何内容。');
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead(0, maxBytes + 1)) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) {
        throw const FormatException('歌单文件超过 4 MB，未导入任何内容。');
      }
    }
    return bytes;
  }

  @override
  Future<String> write(
    String filePath,
    List<int> bytes, {
    required bool Function() canCommit,
  }) async {
    if (!canCommit()) throw const PlaylistTransferCanceled();
    if (bytes.length > PlaylistTransferCodec.maxFileBytes) {
      throw const FormatException('歌单文件超过 4 MB，无法导出。');
    }
    final directory = await Directory(
      path.dirname(filePath),
    ).createTemp('.hanmusic-export-');
    try {
      if (!canCommit()) throw const PlaylistTransferCanceled();
      final temporary = File(path.join(directory.path, 'playlist.json'));
      await temporary.writeAsBytes(bytes, flush: true);
      if (!canCommit()) throw const PlaylistTransferCanceled();
      // Reserve a NEW destination atomically. rename may replace files, so it
      // may only replace the empty placeholder exclusively created by this call.
      final extension =
          filePath.toLowerCase().endsWith(PlaylistTransferCodec.m3u8Extension)
          ? PlaylistTransferCodec.m3u8Extension
          : PlaylistTransferCodec.extension;
      final base = filePath.toLowerCase().endsWith(extension)
          ? filePath.substring(0, filePath.length - extension.length)
          : filePath;
      for (var index = 1; index <= 10000; index++) {
        if (!canCommit()) throw const PlaylistTransferCanceled();
        final destination = File(
          '$base${index == 1 ? '' : ' ($index)'}$extension',
        );
        try {
          destination.createSync(exclusive: true);
        } on FileSystemException {
          if (FileSystemEntity.typeSync(destination.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            continue;
          }
          rethrow;
        }
        var committed = false;
        try {
          if (!canCommit()) throw const PlaylistTransferCanceled();
          // No await from the final guard through commit: an exit event cannot
          // invalidate the operation between these synchronous steps.
          temporary.renameSync(destination.path);
          committed = true;
          return destination.path;
        } finally {
          if (!committed) destination.deleteSync();
        }
      }
      throw const FileSystemException('导出文件重名过多，请选择其他文件夹。');
    } finally {
      try {
        directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Only our temporary directory can remain; never delete user audio.
      }
    }
  }
}

class PlaylistTransferCanceled implements Exception {
  const PlaylistTransferCanceled();
}

/// Performs no playlist mutation. The caller commits a fully validated document
/// synchronously only after checking its controller's exit generation again.
class PlaylistTransfer {
  PlaylistTransfer({
    required this.files,
    this.ioTimeout = const Duration(seconds: 10),
    this.localProbeTimeout = const Duration(seconds: 3),
  });

  static const localProbeConcurrency = 8;
  final PlaylistTransferFiles files;
  final Duration ioTimeout;
  final Duration localProbeTimeout;

  Future<PlaylistTransferDocument?> importPlaylist({
    required bool Function() canCommit,
  }) async {
    if (!canCommit()) return null;
    final selected = await files.pickImport();
    if (selected == null || !canCommit()) return null;
    final bytes = await files
        .read(selected, PlaylistTransferCodec.maxFileBytes)
        .timeout(ioTimeout);
    if (!canCommit()) return null;
    final document = PlaylistTransferCodec.decode(bytes, sourcePath: selected);
    if (!canCommit()) return null;
    return _probeLocalFiles(document, canCommit);
  }

  Future<PlaylistTransferDocument?> _probeLocalFiles(
    PlaylistTransferDocument document,
    bool Function() canCommit,
  ) async {
    final localIndexes = [
      for (var index = 0; index < document.songs.length; index++)
        if (!document.songs[index].isOnline) index,
    ];
    if (localIndexes.isEmpty) return canCommit() ? document : null;
    // Exported availability is specific to another moment/machine. Unchecked,
    // inaccessible and timed-out local files stay missing until proven present.
    final checked = [
      for (final song in document.songs)
        song.isOnline ? song : song.copyWith(isMissing: true),
    ];
    var next = 0;
    var stopped = false;
    Future<void> worker() async {
      while (!stopped && canCommit() && next < localIndexes.length) {
        final index = localIndexes[next++];
        var exists = false;
        try {
          exists = await files.localFileExists(document.songs[index].uri);
        } catch (_) {
          // An inaccessible path is retained as a missing song, never dropped.
        }
        if (stopped || !canCommit()) return;
        checked[index] = document.songs[index].copyWith(isMissing: !exists);
      }
    }

    try {
      await Future.wait([
            for (
              var workerIndex = 0;
              workerIndex < localProbeConcurrency &&
                  workerIndex < localIndexes.length;
              workerIndex++
            )
              worker(),
          ])
          .then<void>((_) {})
          .timeout(
            localProbeTimeout,
            onTimeout: () {
              stopped = true;
            },
          );
    } finally {
      // Native stat requests cannot be canceled. Never start another request or
      // alter the returned snapshot when an in-flight request completes late.
      stopped = true;
    }
    return canCommit()
        ? PlaylistTransferDocument(
            name: document.name,
            songs: List.unmodifiable(checked),
            formatLabel: document.formatLabel,
            skippedCount: document.skippedCount,
            duplicateCount: document.duplicateCount,
          )
        : null;
  }

  Future<String?> exportPlaylist({
    required String name,
    required List<Song> songs,
    required bool Function() canCommit,
    PlaylistTransferFormat outputFormat = PlaylistTransferFormat.hanmusicJson,
  }) async {
    if (!canCommit()) return null;
    final bytes = PlaylistTransferCodec.encode(
      name: name,
      songs: songs,
      outputFormat: outputFormat,
    );
    final selected = await files.pickExport(
      PlaylistTransferCodec.suggestedFileName(name, outputFormat: outputFormat),
    );
    if (selected == null || !canCommit()) return null;
    var pending = true;
    try {
      final saved = await files
          .write(selected, bytes, canCommit: () => pending && canCommit())
          .timeout(ioTimeout);
      return canCommit() ? saved : null;
    } on PlaylistTransferCanceled {
      return null;
    } finally {
      // A timed-out writer may finish its private temporary write later, but
      // its final user-visible commit must then be refused.
      pending = false;
    }
  }
}
