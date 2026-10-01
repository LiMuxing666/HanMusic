import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
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
    this.debugOnArtworkStaged,
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

  /// Optional isolate-sendable test gate, after a real cache write and before
  /// its rename. Production never installs a gate.
  @visibleForTesting
  final Future<void> Function(String temporaryPath)? debugOnArtworkStaged;

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
  LibraryReadSession._(this._repository, this._cancellation) {
    // One subscription per import, rather than retaining a cancellation
    // listener for every song until a large import is closed.
    _cancellation.whenCancelled.then((_) => _cancelCurrent?.call());
  }
  final LocalLibraryRepository _repository;
  final ImportCancellation _cancellation;
  void Function()? _cancelCurrent;
  _MetadataWorker? _worker;
  Future<void>? _closeFuture;
  bool _closed = false;
  bool _reading = false;

  Future<LibraryReadResult> read(File file) async {
    _cancellation.check();
    if (_closed) throw StateError('Metadata session is closed.');
    if (_reading) throw StateError('Metadata reads must be sequential.');
    _reading = true;
    _MetadataWorker? worker;
    final fallback = Song(
      uri: file.absolute.uri,
      fileName: p.basename(file.path),
    );
    try {
      final Map<String, dynamic> result;
      if (_repository._metadataReader case final reader?) {
        // Injection is for deterministic tests. The production parser and
        // artwork writes below always run in the persistent worker isolate.
        final metadata = await _whileOpen(
          Future.sync(() => reader(file)),
        ).timeout(_repository.metadataTimeout);
        _checkOpen();
        result = await _cacheInjectedMetadata(
          metadata,
          _repository.artworkDirectory.path,
        );
      } else {
        worker = _worker ??= _MetadataWorker(_repository);
        result = await _whileOpen(
          worker.read(file),
        ).timeout(_repository.metadataTimeout);
      }
      _checkOpen();
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
      await _resetWorker(worker);
      rethrow;
    } catch (_) {
      await _resetWorker(worker);
      _checkOpen();
      return LibraryReadResult(
        song: fallback,
        warning: '元数据读取失败，使用文件名：${fallback.fileName}',
      );
    } finally {
      _reading = false;
    }
  }

  void _checkOpen() {
    _cancellation.check();
    if (_closed) throw const ImportCancelled();
  }

  Future<T> _whileOpen<T>(Future<T> operation) async {
    final pending = Completer<T>();
    void cancel() {
      if (!pending.isCompleted) pending.completeError(const ImportCancelled());
    }

    _cancelCurrent = cancel;
    // Keep an error handler on the operation even when cancellation wins.
    operation.then<void>(
      (value) {
        if (!pending.isCompleted) pending.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!pending.isCompleted) pending.completeError(error, stack);
      },
    );
    if (_closed || _cancellation.isCancelled) cancel();
    try {
      return await pending.future;
    } finally {
      if (identical(_cancelCurrent, cancel)) _cancelCurrent = null;
    }
  }

  Future<void> _resetWorker(_MetadataWorker? worker) async {
    if (identical(_worker, worker)) _worker = null;
    await worker?.stop();
  }

  Future<void> close() {
    if (_closeFuture case final closing?) return closing;
    _closed = true;
    _cancelCurrent?.call();
    return _closeFuture = _resetWorker(_worker);
  }
}

/// Each incarnation owns its ports, pending reply, and staging directory. A late
/// reply/exit can never complete a replacement worker's request.
class _MetadataWorker {
  _MetadataWorker(this.repository) {
    _responses.listen((dynamic message) {
      if (message is SendPort) {
        if (!_ready.isCompleted) _ready.complete(message);
      } else if (message is Map) {
        final pending = _pending;
        if (pending != null && !pending.isCompleted) {
          pending.complete(Map<String, dynamic>.from(message));
        }
      } else {
        _fail(StateError('Metadata worker stopped unexpectedly.'));
      }
    });
    _exits.listen((_) => _finishExit());
    unawaited(_start());
  }

  final LocalLibraryRepository repository;
  final _responses = ReceivePort();
  final _exits = ReceivePort();
  final _ready = Completer<SendPort>();
  final _stopped = Completer<void>();
  Completer<Map<String, dynamic>>? _pending;
  Isolate? _isolate;
  Directory? _stagingDirectory;
  Future<void>? _stopFuture;
  bool _stopping = false;
  bool _exited = false;

  Future<void> _start() async {
    try {
      try {
        await repository.artworkDirectory.create(recursive: true);
        _stagingDirectory = await repository.artworkDirectory.createTemp(
          '.import-',
        );
      } on FileSystemException {
        // Tags remain usable when artwork cannot be cached. The worker will
        // report the cache warning without writing an unowned temporary file.
      }
      if (_stopping) {
        await _finishExit();
        return;
      }
      _isolate = await Isolate.spawn(
        _metadataWorker,
        [
          _responses.sendPort,
          repository.debugOnArtworkStaged,
          _stagingDirectory?.path,
        ],
        onError: _responses.sendPort,
        onExit: _exits.sendPort,
      );
      // close() may win while Isolate.spawn is awaiting its handle.
      if (_stopping) _isolate!.kill(priority: Isolate.immediate);
    } catch (_) {
      _fail(StateError('Metadata worker could not start.'));
      await _finishExit();
    }
  }

  Future<Map<String, dynamic>> read(File file) async {
    final requests = await _ready.future;
    if (_stopping) throw const ImportCancelled();
    final pending = _pending = Completer<Map<String, dynamic>>();
    requests.send([file.path, repository.artworkDirectory.path]);
    try {
      return await pending.future;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  void _fail(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
  }

  Future<void> _finishExit() async {
    if (_exited) return;
    _exited = true;
    _stopping = true;
    _fail(const ImportCancelled());
    _responses.close();
    _exits.close();
    // Isolate.kill does not run a worker's finally. Only the parent may clean
    // staged bytes after confirmed exit (or before an isolate was spawned).
    try {
      await _deleteStagingDirectory(_stagingDirectory);
    } catch (_) {
      // An unexpected cleanup failure must not escape the exit callback or
      // prevent shutdown completion. Leave uncertain files in place.
    } finally {
      _stopped.complete();
    }
  }

  Future<void> stop() {
    if (_stopFuture case final stopping?) return stopping;
    _stopping = true;
    _fail(const ImportCancelled());
    _isolate?.kill(priority: Isolate.immediate);
    // Slow filesystem calls may delay isolate exit. Keep the exit listener and
    // defer cleanup in that case; never delete a directory a worker can write.
    return _stopFuture = _stopped.future.timeout(
      const Duration(milliseconds: 500),
      onTimeout: () {},
    );
  }
}

Future<void> _deleteStagingDirectory(Directory? directory) async {
  if (directory == null) return;
  try {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    // No recursive deletion or traversal of links, and no sweep of the shared
    // cache. Unknown files cause the final non-recursive directory delete to
    // fail safely instead of deleting another writer's content.
    final ownedName = RegExp(r'^[0-9a-f]{64}\.(png|jpg)\.tmp$');
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && ownedName.hasMatch(p.basename(entity.path))) {
        await entity.delete();
      }
    }
    await directory.delete();
  } on FileSystemException {
    // Locked/unavailable files are retained. This is not a crash-recovery sweep.
  }
}

Future<Map<String, dynamic>> _cacheInjectedMetadata(
  AudioMetadata metadata,
  String directory,
) => Isolate.run(() async {
  Directory? staging;
  try {
    if (metadata.pictures.any(
      (picture) => _safeImageExtension(picture.bytes) != null,
    )) {
      try {
        final cache = await Directory(directory).create(recursive: true);
        staging = await cache.createTemp('.import-');
      } on FileSystemException {
        // Match the production fallback when only the cache is unavailable.
      }
    }
    return await _metadataResult(
      metadata,
      directory,
      stagingDirectory: staging?.path,
    );
  } finally {
    await _deleteStagingDirectory(staging);
  }
});

void _metadataWorker(List<Object?> arguments) {
  final responses = arguments[0] as SendPort;
  final onArtworkStaged =
      arguments[1] as Future<void> Function(String temporaryPath)?;
  final stagingDirectory = arguments[2] as String?;
  final requests = ReceivePort();
  responses.send(requests.sendPort);
  requests.listen((dynamic message) async {
    final request = message as List;
    try {
      final metadata = readMetadata(File(request[0] as String), getImage: true);
      responses.send(
        await _metadataResult(
          metadata,
          request[1] as String,
          onArtworkStaged: onArtworkStaged,
          stagingDirectory: stagingDirectory,
        ),
      );
    } catch (_) {
      responses.send(<String, dynamic>{'warning': '元数据读取失败，已使用文件名。'});
    }
  });
}

Future<Map<String, dynamic>> _metadataResult(
  AudioMetadata metadata,
  String artworkDirectory, {
  required String? stagingDirectory,
  Future<void> Function(String temporaryPath)? onArtworkStaged,
}) async {
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
        if (stagingDirectory == null) {
          throw const FileSystemException('Artwork staging is unavailable.');
        }
        final temporary = File(
          p.join(stagingDirectory, '$digest.$extension.tmp'),
        );
        try {
          temporary.writeAsBytesSync(picture.bytes, flush: true);
          if (onArtworkStaged != null) {
            await onArtworkStaged(temporary.path);
          }
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
