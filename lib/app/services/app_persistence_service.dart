import 'dart:async';

import 'package:get/get.dart';

import '../data/repositories/app_state_store.dart';
import 'library_service.dart';
import 'player_service.dart';

/// Coalesces imports and slider updates; playback position checkpoints at 5s.
class AppPersistenceService extends GetxService {
  AppPersistenceService({
    required this.store,
    required this.library,
    required this.player,
    required this.onError,
  });

  final AppStateStore store;
  final LibraryService library;
  final PlayerService player;
  final void Function(String message) onError;
  final _workers = <Worker>[];
  Timer? _debounce;
  Timer? _checkpoint;
  bool _closed = false;
  bool _started = false;
  bool _libraryChanged = false;

  void start() {
    if (_started || _closed) return;
    _started = true;
    _workers.addAll([
      ever(library.songs, (_) {
        _libraryChanged = true;
        _schedule();
      }),
      ever(player.queue, (_) => _schedule()),
      ever(player.currentSong, (_) => _schedule()),
      ever(player.playMode, (_) => _schedule()),
      ever(player.volume, (_) => _schedule()),
      ever(player.skipOnError, (_) => _schedule()),
      ever(player.isPlaying, (_) => _schedule()),
      ever(player.position, (_) {
        if (!player.isPlaying.value) _schedule();
      }),
    ]);
    _checkpoint = Timer.periodic(const Duration(seconds: 5), (_) {
      if (player.isPlaying.value) unawaited(flush());
    });
  }

  void _schedule() {
    if (_closed) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () {
      unawaited(flush());
    });
  }

  /// Returns false when the snapshot could not be persisted. Exit callers must
  /// decide whether to cancel closing or explicitly discard unsaved changes.
  Future<bool> flush() async {
    _debounce?.cancel();
    try {
      if (_libraryChanged) {
        _libraryChanged = false;
        player.updateSongs(library.songs.toList());
      }
      await store.save(
        AppSnapshot(
          songs: library.songs.toList(),
          queue: player.queue.toList(),
          currentId: player.currentSong.value?.id,
          position: player.position.value,
          mode: player.playMode.value,
          volume: player.volume.value,
          skipOnError: player.skipOnError.value,
        ),
      );
      return true;
    } catch (_) {
      onError(store.warning ?? '本地状态保存失败，请检查数据目录空间与权限。');
      return false;
    }
  }

  /// [flush] may be disabled after an exit coordinator has saved successfully
  /// or the user explicitly chose to exit without saving.
  Future<void> close({bool flush = true}) async {
    if (_closed) return;
    _closed = true;
    _debounce?.cancel();
    _checkpoint?.cancel();
    for (final worker in _workers) {
      worker.dispose();
    }
    if (flush) await this.flush();
  }

  @override
  void onClose() {
    unawaited(close());
    super.onClose();
  }
}
