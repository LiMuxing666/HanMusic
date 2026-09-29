import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/song.dart';

typedef MetadataReader = FutureOr<AudioMetadata> Function(File file);

class ImportCancelled implements Exception {
  const ImportCancelled();
}

class ImportCancellation {
  final Completer<void> _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void check() {
    if (isCancelled) throw const ImportCancelled();
  }
}

class LibraryScanEntry {
  const LibraryScanEntry.file(this.file) : warning = null;
  const LibraryScanEntry.warning(this.warning) : file = null;
  final File? file;
  final String? warning;
}

class LibraryReadResult {
  const LibraryReadResult({required this.song, this.warning});
  final Song song;
  final String? warning;
}

/// Reads user-selected files without modifying source audio. One metadata worker
/// is reused for an import, and killed on cancellation or a per-file deadline.
class LocalLibraryRepository {
  LocalLibraryRepository({
    required this.artworkDirectory,
    MetadataReader? metadataReader,
    this.metadataTimeout = const Duration(seconds: 5),
  }) : _metadataReader = metadataReader;

  static const supportedExtensions = {
    '.mp3',
    '.flac',
    '.wav',
    '.m4a',
    '.ogg',
    '.aac',
    '.opus',
    '.ape',
    '.aif',
    '.aiff',
  };
  final Directory artworkDirectory;
  final MetadataReader? _metadataReader;
  final Duration metadataTimeout;

  LibraryReadSession openReadSession(ImportCancellation cancellation) =>
      LibraryReadSession._(this, cancellation);

  Stream<LibraryScanEntry> scan(
    List<String> paths,
    ImportCancellation cancellation,
  ) async* {
    final roots = List<String>.of(paths.reversed);
    final directories = <String>{};
    while (roots.isNotEmpty && !cancellation.isCancelled) {
      final path = roots.removeLast();
      try {
        final type = await FileSystemEntity.type(path, followLinks: true);
        if (cancellation.isCancelled) break;
        if (type == FileSystemEntityType.directory) {
          final resolved = p.normalize(
            await Directory(path).resolveSymbolicLinks(),
          );
          if (!directories.add(resolved.toLowerCase())) continue;
          // Directory links found inside a tree are deliberately not followed.
          // Explicitly selected roots may resolve to a directory link once.
          await for (final entity in Directory(
            resolved,
          ).list(followLinks: false)) {
            if (cancellation.isCancelled) break;
            if (entity is Directory) {
              roots.add(entity.path);
            } else if (entity is File && _supported(entity.path)) {
              yield await _canonicalFile(entity);
            }
          }
        } else if (type == FileSystemEntityType.file && _supported(path)) {
          yield await _canonicalFile(File(path));
        } else if (type == FileSystemEntityType.notFound) {
          yield LibraryScanEntry.warning('路径不存在：${p.basename(path)}');
        }
      } on FileSystemException {
        yield LibraryScanEntry.warning('无法访问：${p.basename(path)}');
      }
    }
  }

  static bool _supported(String path) =>
      supportedExtensions.contains(p.extension(path).toLowerCase());

  static Future<LibraryScanEntry> _canonicalFile(File file) async {
    try {
      return LibraryScanEntry.file(
        File(p.normalize(await file.resolveSymbolicLinks())),
      );
    } on FileSystemException {
      return LibraryScanEntry.warning('无法访问：${p.basename(file.path)}');
    }
  }
}

class LibraryReadSession {
  LibraryReadSession._(this._repository, this._cancellation);
  final LocalLibraryRepository _repository;
  final ImportCancellation _cancellation;
  Isolate? _isolate;
  ReceivePort? _port;
  StreamSubscription<dynamic>? _subscription;
  SendPort? _requests;
  Completer<Map<String, dynamic>>? _pending;
  bool _closed = false;

  Future<LibraryReadResult> read(File file) async {
    _cancellation.check();
    if (_closed) throw StateError('Metadata session is closed.');
    final fallback = Song(
      uri: file.absolute.uri,
      fileName: p.basename(file.path),
    );
    try {
      final Map<String, dynamic> result;
      if (_repository._metadataReader case final reader?) {
        // Injection is for deterministic tests. The production parser and
        // artwork writes below always run in the persistent worker isolate.
        final metadata = await Future.any<AudioMetadata>([
          Future.sync(() => reader(file)),
          _cancellation.whenCancelled.then(
            (_) => throw const ImportCancelled(),
          ),
        ]).timeout(_repository.metadataTimeout);
        _cancellation.check();
        result = await _cacheInjectedMetadata(
          metadata,
          _repository.artworkDirectory.path,
        );
      } else {
        await _startWorker();
        _cancellation.check();
        final pending = _pending = Completer<Map<String, dynamic>>();
        _requests!.send([file.path, _repository.artworkDirectory.path]);
        result = await Future.any<Map<String, dynamic>>([
          pending.future,
          _cancellation.whenCancelled.then(
            (_) => throw const ImportCancelled(),
          ),
        ]).timeout(_repository.metadataTimeout);
      }
      _cancellation.check();
      return LibraryReadResult(
        song: Song(
          uri: fallback.uri,
          fileName: fallback.fileName,
          trackTitle: result['title'] as String?,
          artist: result['artist'] as String?,
          album: result['album'] as String?,
          duration: result['durationMs'] == null
              ? null
              : Duration(milliseconds: result['durationMs'] as int),
          artworkPath: result['artworkPath'] as String?,
        ),
        warning: result['warning'] as String?,
      );
    } on ImportCancelled {
      await _resetWorker();
      rethrow;
    } catch (_) {
      await _resetWorker();
      return LibraryReadResult(
        song: fallback,
        warning: '元数据读取失败，使用文件名：${fallback.fileName}',
      );
    } finally {
      _pending = null;
    }
  }

  Future<void> _startWorker() async {
    if (_isolate != null) return;
    final ready = Completer<SendPort>();
    final port = _port = ReceivePort();
    _subscription = port.listen((dynamic message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is Map) {
        final pending = _pending;
        if (pending != null && !pending.isCompleted) {
          pending.complete(Map<String, dynamic>.from(message));
        }
      } else {
        final error = StateError('Metadata worker stopped unexpectedly.');
        if (!ready.isCompleted) ready.completeError(error);
        final pending = _pending;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(error);
        }
      }
    });
    _isolate = await Isolate.spawn(
      _metadataWorker,
      port.sendPort,
      onError: port.sendPort,
      onExit: port.sendPort,
    );
    _requests = await ready.future.timeout(_repository.metadataTimeout);
  }

  Future<void> _resetWorker() async {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _requests = null;
    await _subscription?.cancel();
    _subscription = null;
    _port?.close();
    _port = null;
  }

  Future<void> close() async {
    _closed = true;
    await _resetWorker();
  }
}

Future<Map<String, dynamic>> _cacheInjectedMetadata(
  AudioMetadata metadata,
  String directory,
) => Isolate.run(() => _metadataResult(metadata, directory));

void _metadataWorker(SendPort responses) {
  final requests = ReceivePort();
  responses.send(requests.sendPort);
  requests.listen((dynamic message) {
    final request = message as List;
    try {
      final metadata = readMetadata(File(request[0] as String), getImage: true);
      responses.send(_metadataResult(metadata, request[1] as String));
    } catch (_) {
      responses.send(<String, dynamic>{'warning': '元数据读取失败，已使用文件名。'});
    }
  });
}

Map<String, dynamic> _metadataResult(
  AudioMetadata metadata,
  String artworkDirectory,
) {
  String? clean(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    return text.length > 512 ? text.substring(0, 512) : text;
  }

  String? artworkPath;
  String? warning;
  final pictures = [...metadata.pictures]
    ..sort(
      (a, b) => (a.pictureType == PictureType.coverFront ? 0 : 1).compareTo(
        b.pictureType == PictureType.coverFront ? 0 : 1,
      ),
    );
  for (final picture in pictures) {
    final extension = _safeImageExtension(picture.bytes);
    if (extension == null) {
      warning = '封面格式、尺寸或大小超出限制，已使用默认封面。';
      continue;
    }
    try {
      final directory = Directory(artworkDirectory)
        ..createSync(recursive: true);
      final digest = sha256.convert(picture.bytes).toString();
      final target = File(p.join(directory.path, '$digest.$extension'));
      if (!target.existsSync()) {
        final temporary = File(
          '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        try {
          temporary.writeAsBytesSync(picture.bytes, flush: true);
          temporary.renameSync(target.path);
        } finally {
          if (temporary.existsSync()) temporary.deleteSync();
        }
      }
      artworkPath = target.path;
      warning = null;
      break;
    } on FileSystemException {
      warning = '封面缓存写入失败，已使用默认封面。';
    }
  }
  final duration = metadata.duration;
  return {
    'title': clean(metadata.title),
    'artist': clean(metadata.artist),
    'album': clean(metadata.album),
    'durationMs': duration != null && !duration.isNegative
        ? duration.inMilliseconds
        : null,
    'artworkPath': artworkPath,
    'warning': warning,
  };
}

/// Only bounded PNG/JPEG data can reach Flutter's image decoder.
String? _safeImageExtension(Uint8List bytes) {
  if (bytes.length > 4 * 1024 * 1024 || bytes.length < 24) return null;
  bool dimensions(int width, int height) =>
      width > 0 && height > 0 && width <= 4096 && height <= 4096;
  if (bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71 &&
      bytes[4] == 13 &&
      bytes[5] == 10 &&
      bytes[6] == 26 &&
      bytes[7] == 10) {
    final data = ByteData.sublistView(bytes);
    return dimensions(data.getUint32(16), data.getUint32(20)) ? 'png' : null;
  }
  if (bytes[0] != 255 || bytes[1] != 216) return null;
  var index = 2;
  while (index + 3 < bytes.length) {
    if (bytes[index] != 255) return null;
    while (index < bytes.length && bytes[index] == 255) {
      index++;
    }
    if (index >= bytes.length) return null;
    final marker = bytes[index++];
    if (marker == 217 || marker == 218) return null;
    if (marker == 1 || (marker >= 208 && marker <= 215)) continue;
    if (index + 1 >= bytes.length) return null;
    final length = (bytes[index] << 8) | bytes[index + 1];
    if (length < 2 || index + length > bytes.length) return null;
    if ({
      192,
      193,
      194,
      195,
      197,
      198,
      199,
      201,
      202,
      203,
      205,
      206,
      207,
    }.contains(marker)) {
      if (length < 8) return null;
      final height = (bytes[index + 3] << 8) | bytes[index + 4];
      final width = (bytes[index + 5] << 8) | bytes[index + 6];
      return dimensions(width, height) ? 'jpg' : null;
    }
    index += length;
  }
  return null;
}
