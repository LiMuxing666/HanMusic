import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../data/models/song.dart';
import '../../data/models/play_mode.dart';
import '../../data/models/queue_add_result.dart';
import '../../data/models/sleep_timer_mode.dart';
import '../../data/repositories/local_song_picker.dart';
import '../../services/library_service.dart';
import '../../services/player_service.dart';
import '../../services/timer_service.dart';
import '../../services/online_music_service.dart';

class PlayerController extends GetxController with WidgetsBindingObserver {
  PlayerController({
    required PlayerService player,
    required TimerService timer,
    required SongPicker picker,
    LibraryService? library,
    LibraryPicker? libraryPicker,
    this.online,
  }) : _player = player,
       _timer = timer,
       _picker = picker,
       _library = library,
       _libraryPicker = libraryPicker ?? LocalLibraryPicker();

  final PlayerService _player;
  final TimerService _timer;
  final SongPicker _picker;
  final LibraryService? _library;
  final LibraryPicker _libraryPicker;
  final OnlineMusicService? online;

  String sourceLabel(Song song) {
    if (!song.isOnline) return '本地文件';
    for (final source in online?.sources ?? []) {
      if (source.id == song.sourceId) return source.name;
    }
    return '在线音乐';
  }

  final isImporting = false.obs;
  final isRefreshing = false.obs;
  final searchQuery = ''.obs;
  final _emptySongs = <Song>[].obs;
  final _notScanning = false.obs;
  final _zeroCount = 0.obs;
  final _emptyStatus = RxnString();
  bool _closed = false;
  bool _exitPending = false;
  int _importGeneration = 0;
  int? _activeImport;

  bool get hasLibrary => _library != null;
  RxList<Song> get songs => _library?.songs ?? _emptySongs;
  RxList<Song> get queue => _player.queue;
  Rx<PlayMode> get playMode => _player.playMode;
  RxBool get skipOnError => _player.skipOnError;
  RxBool get isScanning => _library?.isImporting ?? _notScanning;
  RxInt get importProcessed => _library?.processed ?? _zeroCount;
  RxInt get importDiscovered => _library?.discovered ?? _zeroCount;
  RxnString get libraryStatus => _library?.statusMessage ?? _emptyStatus;
  bool get libraryBusy =>
      isImporting.value || isScanning.value || isRefreshing.value;
  List<Song> get visibleSongs =>
      _library?.search(searchQuery.value) ?? <Song>[];
  int get currentIndex => _player.currentIndex;

  Rxn<Song> get currentSong => _player.currentSong;
  RxBool get isPlaying => _player.isPlaying;
  RxBool get isLoading => _player.isLoading;
  Rx<Duration> get position => _player.position;
  Rx<Duration> get duration => _player.duration;
  RxDouble get volume => _player.volume;
  RxnString get errorMessage => _player.errorMessage;
  Rxn<Duration> get timerRemaining => _timer.remaining;
  Rx<SleepTimerMode> get timerMode => _timer.mode;
  RxnString get timerStatusMessage => _timer.statusMessage;
  bool get timerActive => _timer.isActive;
  bool get canExtendSleepTimer => _timer.canExtend;
  bool get canStopAfterCurrentSong =>
      !_closed &&
      currentSong.value != null &&
      !currentSong.value!.isMissing &&
      canPlay &&
      !isLoading.value;
  bool get canPlay => _player.canPlay;
  int get selectionRevision => _player.selectionRevision;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    super.onInit();
  }

  Future<void> importFile() async {
    if (hasLibrary) {
      await _importLibrary(directory: false);
      return;
    }
    if (_closed || _exitPending || isImporting.value || isLoading.value) return;
    final operation = _beginImport();
    try {
      final song = await _picker.pick();
      if (_canApplyImport(operation) && song != null) await _player.open(song);
    } catch (_) {
      if (_canApplyImport(operation)) {
        errorMessage.value = '无法打开所选文件，请检查文件是否存在及访问权限。';
      }
    } finally {
      _finishImport(operation);
    }
  }

  Future<void> importDirectory() => _importLibrary(directory: true);

  Future<void> _importLibrary({required bool directory}) async {
    if (_closed || _exitPending || _library == null || libraryBusy) return;
    final operation = _beginImport();
    try {
      final List<String> paths;
      if (directory) {
        final path = await _libraryPicker.pickDirectory();
        paths = path == null ? [] : [path];
      } else {
        paths = await _libraryPicker.pickFiles();
      }
      if (!_canApplyImport(operation) || paths.isEmpty) return;
      await _library.importPaths(paths);
      if (_canApplyImport(operation)) {
        _player.updateSongs(_library.songs.toList());
      }
    } catch (_) {
      if (_canApplyImport(operation)) {
        errorMessage.value = '无法导入音乐，请检查所选位置及访问权限。';
      }
    } finally {
      _finishImport(operation);
    }
  }

  /// Invalidates the whole import, including a picker that has not replied yet.
  /// The picker API cannot dismiss an open native dialog, so keep it busy until
  /// its result settles. Canceling exit must not open a second dialog beside it.
  void beginExit() {
    if (_closed || _exitPending) return;
    _exitPending = true;
    _importGeneration++;
  }

  /// A canceled exit allows new imports once the old picker has settled.
  void cancelExit() {
    if (!_closed) _exitPending = false;
  }

  int _beginImport() {
    final operation = ++_importGeneration;
    _activeImport = operation;
    isImporting.value = true;
    return operation;
  }

  bool _canApplyImport(int operation) =>
      !_closed && !_exitPending && operation == _importGeneration;

  void _finishImport(int operation) {
    if (_activeImport != operation) return;
    _activeImport = null;
    if (!_closed) isImporting.value = false;
  }

  void cancelImport() => _library?.cancelImport();
  void setSearchQuery(String value) => searchQuery.value = value;

  Future<void> refreshMissing() async {
    if (_closed || _library == null || libraryBusy) return;
    isRefreshing.value = true;
    try {
      await _library.refreshMissing();
      if (!_closed) _player.updateSongs(_library.songs.toList());
    } catch (_) {
      if (!_closed) errorMessage.value = '无法检查文件状态，请稍后重试。';
    } finally {
      if (!_closed) isRefreshing.value = false;
    }
  }

  Future<void> playLibrarySong(Song song) async {
    if (_closed || song.isMissing) return;
    final playable = visibleSongs.where((item) => !item.isMissing).toList();
    final index = playable.indexWhere((item) => item.id == song.id);
    if (index >= 0) await _player.playQueue(playable, startIndex: index);
  }

  Future<void> playOnlineSong(Song song) async {
    if (_closed || online == null) return;
    final results = online!.results.toList();
    final index = results.indexWhere((item) => item.id == song.id);
    if (index >= 0) await _player.playQueue(results, startIndex: index);
  }

  Future<void> removeFromLibrary(Song song) async {
    if (_closed || _library == null) return;
    _library.remove(song.id);
    await _player.removeFromQueue(song.id);
  }

  QueueAddResult addToQueue(Song song) {
    if (_closed || _exitPending) return QueueAddResult.unavailable;
    var current = song;
    if (!song.isOnline && _library != null) {
      // A context menu can outlive a missing-file refresh or index removal.
      final indexed = _library.songs.firstWhereOrNull(
        (item) => item.id == song.id,
      );
      if (indexed == null) return QueueAddResult.unavailable;
      current = indexed;
    }
    if (current.isMissing) return QueueAddResult.unavailable;
    return _player.addToQueue([current]);
  }

  Future<void> playQueueItem(int index) => _player.playAt(index);
  Future<void> next() => _player.next();
  Future<void> previous() => _player.previous();
  void reorderQueue(int oldIndex, int newIndex) =>
      _player.reorderQueue(oldIndex, newIndex);
  Future<void> removeFromQueue(String id) => _player.removeFromQueue(id);
  void cyclePlayMode() {
    final modes = PlayMode.values;
    _player.playMode.value =
        modes[(modes.indexOf(_player.playMode.value) + 1) % modes.length];
  }

  Future<void> togglePlayback() => _player.togglePlayback();
  Future<void> seek(Duration value) => _player.seek(value);
  Future<void> setVolume(double value) => _player.setVolume(value);
  void startSleepTimer(Duration value) {
    if (!_closed) _timer.start(value);
  }

  void startSleepTimerAfterCurrentSong() {
    if (canStopAfterCurrentSong) _timer.startEndOfTrack(currentSong.value!.id);
  }

  bool extendSleepTimer() => !_closed && _timer.extend10Minutes();
  void cancelSleepTimer() => _timer.cancel();
  void dismissError() => errorMessage.value = null;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _timer.checkDeadline();
  }

  @override
  void onClose() {
    _closed = true;
    _importGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }
}
