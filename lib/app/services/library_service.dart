import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';

import '../data/models/song.dart';
import '../data/repositories/local_library_repository.dart';

class LibraryService extends GetxService {
  LibraryService({required LocalLibraryRepository repository})
    : _repository = repository;
  final LocalLibraryRepository _repository;
  final songs = <Song>[].obs;
  final isImporting = false.obs;
  final processed = 0.obs;
  final discovered = 0.obs;
  final errorCount = 0.obs;
  final warningCount = 0.obs;
  final statusMessage = RxnString();
  ImportCancellation? _cancellation;
  bool _closed = false;

  Future<List<Song>> importPaths(List<String> paths) async {
    if (_closed || isImporting.value || paths.isEmpty) return [];
    final cancellation = _cancellation = ImportCancellation();
    final session = _repository.openReadSession(cancellation);
    final waiting = _ImportWaiter(cancellation);
    StreamIterator<LibraryScanEntry>? scan;
    final imported = <Song>[];
    final known = songs.map((song) => song.id).toSet();
    var duplicates = 0;
    isImporting.value = true;
    processed.value = 0;
    discovered.value = 0;
    errorCount.value = 0;
    warningCount.value = 0;
    statusMessage.value = '正在扫描音频文件…';
    try {
      scan = StreamIterator(_repository.scan(paths, cancellation));
      while (await waiting.wait(scan.moveNext())) {
        cancellation.check();
        final entry = scan.current;
        if (entry.warning != null) {
          errorCount.value++;
          statusMessage.value = entry.warning;
          continue;
        }
        final file = entry.file!;
        final id = file.uri.normalizePath().toString().toLowerCase();
        if (!known.add(id)) {
          duplicates++;
          continue;
        }
        discovered.value++;
        final result = await session.read(file);
        cancellation.check();
        if (result.warning != null) warningCount.value++;
        final exists = await waiting.wait(file.exists());
        cancellation.check();
        if (!exists) {
          errorCount.value++;
          processed.value++;
          continue;
        }
        cancellation.check();
        // Keep each successful import if cancellation happens later.
        songs.add(result.song);
        imported.add(result.song);
        processed.value++;
        statusMessage.value =
            '已处理 ${processed.value} 首，新增 ${imported.length} 首';
      }
    } on ImportCancelled {
      // Completed songs stay in the index; an interrupted result is discarded.
    } catch (_) {
      if (!cancellation.isCancelled) errorCount.value++;
    } finally {
      final activeScan = scan;
      if (activeScan != null) {
        try {
          // async* cancellation can itself wait for old filesystem I/O. Stop
          // listening now, but do not hold the UI behind that cleanup Future.
          await waiting.wait(Future<void>.sync(activeScan.cancel));
        } on ImportCancelled {
          // The waiter still consumes a late cancellation failure.
        } catch (_) {
          if (!cancellation.isCancelled) errorCount.value++;
        }
      }
      try {
        await session.close();
      } catch (_) {
        if (!cancellation.isCancelled) errorCount.value++;
      }
      await waiting.close();
      if (!_closed && identical(_cancellation, cancellation)) {
        final outcome = cancellation.isCancelled ? '已取消导入' : '导入完成';
        statusMessage.value =
            '$outcome：新增 ${imported.length} 首，重复 $duplicates 首'
            '${warningCount.value > 0 ? '，${warningCount.value} 首元数据或封面降级' : ''}'
            '${errorCount.value > 0 ? '，${errorCount.value} 项无法访问或处理' : ''}';
        isImporting.value = false;
      }
      if (identical(_cancellation, cancellation)) _cancellation = null;
    }
    return imported;
  }

  void cancelImport() => _cancellation?.cancel();

  void replaceAll(List<Song> values) {
    if (_closed) return;
    final unique = <String, Song>{};
    for (final song in values) {
      unique.putIfAbsent(song.id, () => song);
    }
    songs.assignAll(unique.values);
  }

  Future<void> refreshMissing() async {
    // Apply only missing flags to the current index after the asynchronous scan;
    // preserve simultaneous imports/removals and avoid quadratic ID lookups.
    final missing = <String, bool>{};
    for (final song in List<Song>.of(songs)) {
      if (_closed) return;
      if (song.uri.scheme != 'file') continue;
      try {
        missing[song.id] = !await File.fromUri(song.uri).exists();
      } on FileSystemException {
        missing[song.id] = true;
      }
    }
    if (_closed) return;
    final updated = songs
        .map(
          (song) => missing.containsKey(song.id)
              ? song.copyWith(isMissing: missing[song.id])
              : song,
        )
        .toList();
    if (updated.indexed.any(
      (entry) => entry.$2.isMissing != songs[entry.$1].isMissing,
    )) {
      songs.assignAll(updated);
    }
  }

  void remove(String id) {
    if (!_closed) songs.removeWhere((song) => song.id == id);
  }

  List<Song> search(String query) {
    final term = query.trim().toLowerCase();
    if (term.isEmpty) return List<Song>.of(songs);
    return songs
        .where(
          (song) => [
            song.title,
            song.artist,
            song.album,
            song.fileName,
          ].any((value) => value?.toLowerCase().contains(term) ?? false),
        )
        .toList();
  }

  @override
  void onClose() {
    _closed = true;
    cancelImport();
    super.onClose();
  }
}

/// Owns one active wait and one removable cancellation listener per import.
/// Releasing the wait does not claim to abort the underlying filesystem I/O.
class _ImportWaiter {
  _ImportWaiter(this.cancellation) {
    _subscription = cancellation.whenCancelled.asStream().listen((_) {
      final pending = _pending;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(const ImportCancelled());
      }
    });
  }

  final ImportCancellation cancellation;
  late final StreamSubscription<void> _subscription;
  Completer<dynamic>? _pending;

  Future<T> wait<T>(Future<T> operation) {
    final completion = Completer<T>();
    _pending = completion;
    // Attach both handlers before checking cancellation. Even an already
    // cancelled import must consume a late error from the original operation.
    operation.then<void>(
      (value) {
        if (!completion.isCompleted) completion.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!completion.isCompleted) completion.completeError(error, stack);
      },
    );
    if (cancellation.isCancelled) {
      completion.completeError(const ImportCancelled());
    }
    return completion.future.whenComplete(() {
      if (identical(_pending, completion)) _pending = null;
    });
  }

  Future<void> close() => _subscription.cancel();
}
