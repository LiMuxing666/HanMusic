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
      await for (final entry in _repository.scan(paths, cancellation)) {
        cancellation.check();
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
        if (!await file.exists()) {
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
      await session.close();
      if (!_closed) {
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
