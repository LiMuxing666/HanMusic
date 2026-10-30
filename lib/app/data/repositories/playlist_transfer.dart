import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;

import '../models/playlist.dart';
import '../models/song.dart';

/// A portable metadata snapshot; never contains playable HTTP URLs or audio.
class PlaylistTransferDocument {
  const PlaylistTransferDocument({required this.name, required this.songs});

  final String name;
  final List<Song> songs;
}

class PlaylistTransferCodec {
  static const format = 'hanmusic-playlist';
  static const version = 1;
  static const maxFileBytes = 4 * 1024 * 1024;
  static const maxSongs = 5000;
  static const extension = '.hanmusic.json';
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

  static List<int> encode({required String name, required List<Song> songs}) {
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

  static PlaylistTransferDocument decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxFileBytes) {
      throw const FormatException('请选择不超过 4 MB 的 HanMusic 歌单文件。');
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

  static String suggestedFileName(String name) {
    final safe = Playlist.validateName(name)
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return 'HanMusic-${String.fromCharCodes(safe.runes.take(70))}$extension';
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
    dialogTitle: '导入 HanMusic JSON 歌单',
    windowsOptions: _options,
    type: FileType.custom,
    allowedExtensions: ['json'],
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
      final extension = PlaylistTransferCodec.extension;
      final base = filePath.endsWith(extension)
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
    final document = PlaylistTransferCodec.decode(bytes);
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
          )
        : null;
  }

  Future<String?> exportPlaylist({
    required String name,
    required List<Song> songs,
    required bool Function() canCommit,
  }) async {
    if (!canCommit()) return null;
    final bytes = PlaylistTransferCodec.encode(name: name, songs: songs);
    final selected = await files.pickExport(
      PlaylistTransferCodec.suggestedFileName(name),
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
