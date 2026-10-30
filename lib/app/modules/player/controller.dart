import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../data/models/library_sort.dart';
import '../../data/models/playlist.dart';
import '../../data/models/play_history_entry.dart';
import '../../data/models/song.dart';
import '../../data/models/play_mode.dart';
import '../../data/models/queue_add_result.dart';
import '../../data/models/sleep_timer_mode.dart';
import '../../data/repositories/local_song_picker.dart';
import '../../services/library_service.dart';
import '../../services/desktop_media_service.dart';
import '../../services/playlist_service.dart';
import '../../services/player_service.dart';
import '../../services/play_history_service.dart';
import '../../services/timer_service.dart';
import '../../services/online_music_service.dart';
import '../../services/app_settings_service.dart';

class PlayerController extends GetxController with WidgetsBindingObserver {
  PlayerController({
    required PlayerService player,
    required TimerService timer,
    required SongPicker picker,
    LibraryService? library,
    LibraryPicker? libraryPicker,
    PlaylistService? playlists,
    this.online,
    this.desktopMedia,
    this.history,
    this.settings,
  }) : playlists = playlists ?? PlaylistService(),
       _ownsPlaylists = playlists == null,
       librarySort =
           (settings?.settings.value.librarySort ?? LibrarySort.importOrder)
               .obs,
       librarySortDescending =
           (settings?.settings.value.librarySortDescending ?? false).obs,
       _player = player,
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
  final DesktopMediaService? desktopMedia;
  final PlayHistoryService? history;
  final AppSettingsService? settings;
  final PlaylistService playlists;
  final bool _ownsPlaylists;

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
  final Rx<LibrarySort> librarySort;
  final RxBool librarySortDescending;
  final librarySelectionMode = false.obs;
  final selectedLibraryIds = <String>{}.obs;
  final isRemovingLibrarySongs = false.obs;
  final _emptyHistory = <PlayHistoryEntry>[].obs;
  final _selectionWorkers = <Worker>[];
  final _settingsWorkers = <Worker>[];
  bool _applyingSettings = false;
  String? _librarySelectionAnchor;
  List<String> _librarySelectionOrder = [];
  final _emptySongs = <Song>[].obs;
  final _notScanning = false.obs;
  final _zeroCount = 0.obs;
  final _emptyStatus = RxnString();
  bool _closed = false;
  bool _exitPending = false;
  double _unmuteVolume = 0.7;
  int _importGeneration = 0;
  int? _activeImport;

  bool get hasLibrary => _library != null;
  bool get acceptsPlaybackCommands => !_closed && !_exitPending;
  int get commandGeneration => _importGeneration;
  RxBool get trayAvailable => desktopMedia?.trayAvailable ?? _notScanning;
  Future<bool> hideToTray() async =>
      acceptsPlaybackCommands &&
      await (desktopMedia?.hideToTray() ?? Future.value(false));
  RxList<Song> get songs => _library?.songs ?? _emptySongs;
  RxList<PlayHistoryEntry> get historyEntries =>
      history?.entries ?? _emptyHistory;
  RxList<Song> get queue => _player.queue;
  Rx<PlayMode> get playMode => _player.playMode;
  RxBool get skipOnError => _player.skipOnError;
  RxBool get isScanning => _library?.isImporting ?? _notScanning;
  RxInt get importProcessed => _library?.processed ?? _zeroCount;
  RxInt get importDiscovered => _library?.discovered ?? _zeroCount;
  RxnString get libraryStatus => _library?.statusMessage ?? _emptyStatus;
  bool get libraryBusy =>
      isImporting.value ||
      isScanning.value ||
      isRefreshing.value ||
      isRemovingLibrarySongs.value;
  bool get canChangeLibrarySelection =>
      acceptsPlaybackCommands &&
      !libraryBusy &&
      !isLoading.value &&
      !isRemovingLibrarySongs.value;
  List<Song> get selectedLibrarySongs => visibleSongs
      .where((song) => selectedLibraryIds.contains(song.id))
      .toList();
  List<Song> get visibleSongs {
    final matches = _library?.search(searchQuery.value) ?? <Song>[];
    final sort = librarySort.value;
    final descending = librarySortDescending.value;
    if (sort == LibrarySort.importOrder) {
      return descending ? matches.reversed.toList() : matches;
    }
    // Decorate with original indexes so ties stay stable in both directions.
    // Normalize once per song instead of on every comparison for large lists.
    final entries = [
      for (final (index, song) in matches.indexed)
        (
          index: index,
          song: song,
          key: switch (sort) {
            LibrarySort.title => song.title,
            LibrarySort.artist => song.artist ?? '',
            LibrarySort.album => song.album ?? '',
            LibrarySort.importOrder => '',
          }.trim().toLowerCase(),
        ),
    ];
    entries.sort((left, right) {
      // Unknown artists/albums belong at the end in either direction.
      if (left.key.isEmpty != right.key.isEmpty) {
        return left.key.isEmpty ? 1 : -1;
      }
      final comparison = left.key.compareTo(right.key);
      if (comparison == 0) return left.index.compareTo(right.index);
      return descending ? -comparison : comparison;
    });
    return entries.map((entry) => entry.song).toList();
  }

  int get currentIndex => _player.currentIndex;

  Rxn<Song> get currentSong => _player.currentSong;
  RxBool get isPlaying => _player.isPlaying;
  RxBool get isLoading => _player.isLoading;
  Rx<Duration> get position => _player.position;
  Rx<Duration> get duration => _player.duration;
  RxDouble get volume => _player.volume;
  double get unmuteVolume => _unmuteVolume;
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
  bool get canRetryPlayback {
    if (_closed ||
        _exitPending ||
        isLoading.value ||
        isPlaying.value ||
        canPlay) {
      return false;
    }
    final song = currentSong.value;
    if (song == null || song.isMissing) return false;
    return queue.any((item) => item.id == song.id && !item.isMissing);
  }

  int get selectionRevision => _player.selectionRevision;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    final settingsService = settings;
    if (settingsService != null) {
      // A restore may have completed between construction and GetX onStart.
      _applyLibrarySettings();
      _settingsWorkers.addAll([
        ever(settingsService.settings, (_) => _applyLibrarySettings()),
        ever(librarySort, (_) => _persistLibrarySort()),
        ever(librarySortDescending, (_) => _persistLibrarySortDirection()),
      ]);
    }
    _reconcileLibrarySelection();
    _selectionWorkers.addAll([
      ever(searchQuery, (_) => _reconcileLibrarySelection()),
      ever(librarySort, (_) => _reconcileLibrarySelection()),
      ever(librarySortDescending, (_) => _reconcileLibrarySelection()),
      ever(songs, (_) => _reconcileLibrarySelection()),
    ]);
    super.onInit();
  }

  void _applyLibrarySettings() {
    final saved = settings?.settings.value;
    if (_closed || saved == null) return;
    _applyingSettings = true;
    try {
      if (librarySort.value != saved.librarySort) {
        librarySort.value = saved.librarySort;
      }
      if (librarySortDescending.value != saved.librarySortDescending) {
        librarySortDescending.value = saved.librarySortDescending;
      }
    } finally {
      _applyingSettings = false;
    }
    _reconcileLibrarySelection();
  }

  void _persistLibrarySort() {
    final settingsService = settings;
    if (_closed || _applyingSettings || settingsService == null) return;
    if (_exitPending) {
      _applyLibrarySettings();
      return;
    }
    if (settingsService.settings.value.librarySort != librarySort.value) {
      settingsService.setLibrarySort(librarySort.value);
    }
  }

  void _persistLibrarySortDirection() {
    final settingsService = settings;
    if (_closed || _applyingSettings || settingsService == null) return;
    if (_exitPending) {
      _applyLibrarySettings();
      return;
    }
    if (settingsService.settings.value.librarySortDescending !=
        librarySortDescending.value) {
      settingsService.setLibrarySortDescending(librarySortDescending.value);
    }
  }

  void _replaceLibrarySelection(Set<String> ids) {
    if (selectedLibraryIds.length == ids.length &&
        selectedLibraryIds.containsAll(ids)) {
      return;
    }
    selectedLibraryIds.assignAll(ids);
  }

  void _reconcileLibrarySelection() {
    if (_closed) return;
    // Hidden results are not part of a later bulk action. Sorting preserves
    // selected identities but starts a new range in the newly displayed order.
    final visibleIds = visibleSongs.map((song) => song.id).toList();
    _replaceLibrarySelection(
      selectedLibraryIds.intersection(visibleIds.toSet()),
    );
    if (!listEquals(_librarySelectionOrder, visibleIds)) {
      _librarySelectionAnchor = null;
      _librarySelectionOrder = visibleIds;
    }
  }

  void enterLibrarySelection() {
    if (canChangeLibrarySelection) librarySelectionMode.value = true;
  }

  void exitLibrarySelection() {
    librarySelectionMode.value = false;
    _replaceLibrarySelection({});
    _librarySelectionAnchor = null;
  }

  void selectLibrarySong(Song song, {bool toggle = true, bool range = false}) {
    if (!canChangeLibrarySelection) return;
    _reconcileLibrarySelection();
    final visible = visibleSongs;
    final target = visible.indexWhere((item) => item.id == song.id);
    if (target < 0) return;
    librarySelectionMode.value = true;
    final anchor = visible.indexWhere(
      (item) => item.id == _librarySelectionAnchor,
    );
    final ids = toggle ? selectedLibraryIds.toSet() : <String>{};
    if (range && anchor >= 0) {
      final first = anchor < target ? anchor : target;
      final last = anchor > target ? anchor : target;
      ids.addAll(visible.sublist(first, last + 1).map((item) => item.id));
    } else {
      if (!toggle || !ids.remove(song.id)) ids.add(song.id);
      _librarySelectionAnchor = song.id;
    }
    _replaceLibrarySelection(ids);
  }

  void selectAllVisibleLibrarySongs() {
    if (!canChangeLibrarySelection || visibleSongs.isEmpty) return;
    librarySelectionMode.value = true;
    _replaceLibrarySelection(visibleSongs.map((song) => song.id).toSet());
    _librarySelectionAnchor = null;
  }

  ({int added, int existing, int unavailable}) enqueueSelectedLibrarySongs() {
    if (!canChangeLibrarySelection) {
      return (added: 0, existing: 0, unavailable: 0);
    }
    final selected = selectedLibrarySongs;
    final playable = selected.where(isSongAvailable).toList();
    if (playable.isEmpty) {
      return (added: 0, existing: 0, unavailable: selected.length);
    }
    final before = queue.length;
    if (_player.addToQueue(playable) == QueueAddResult.unavailable) {
      return (added: 0, existing: 0, unavailable: selected.length);
    }
    final added = queue.length - before;
    return (
      added: added,
      existing: playable.length - added,
      unavailable: selected.length - playable.length,
    );
  }

  ({int added, int existing, int unavailable})
  addSelectedLibrarySongsToPlaylist(
    String playlistId, {
    Iterable<String>? songIds,
  }) {
    if (!canChangeLibrarySelection) {
      return (added: 0, existing: 0, unavailable: 0);
    }
    final ids = (songIds ?? selectedLibrarySongs.map((song) => song.id))
        .toSet();
    final indexed = {for (final song in songs) song.id: song};
    // Keep the visible order, or the order captured when the dialog opened,
    // while resolving each identity against the latest library metadata.
    final selected = ids.map((id) => indexed[id]).whereType<Song>().toList();
    final playable = selected.where(isSongAvailable).toList();
    final result = playlists.addSongs(playlistId, playable);
    return (
      added: result.added,
      existing: result.existing,
      unavailable: ids.length - playable.length,
    );
  }

  /// Removes index/queue references only. Never deletes source audio or playlists.
  Future<int> removeSelectedLibrarySongs({Iterable<String>? songIds}) async {
    if (!canChangeLibrarySelection || _library == null) return 0;
    final ids = (songIds ?? selectedLibraryIds).toSet();
    final selected = songs.where((song) => ids.contains(song.id)).toList();
    var removed = 0;
    isRemovingLibrarySongs.value = true;
    try {
      for (final song in selected) {
        if (!acceptsPlaybackCommands) break;
        _library.remove(song.id);
        removed++;
        await _player.removeFromQueue(song.id);
      }
      return removed;
    } finally {
      if (!_closed) {
        isRemovingLibrarySongs.value = false;
        _reconcileLibrarySelection();
      }
    }
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
  void setSearchQuery(String value) {
    searchQuery.value = value;
    _reconcileLibrarySelection();
  }

  void setLibrarySort(LibrarySort value) {
    if (!acceptsPlaybackCommands) return;
    librarySort.value = value;
    _persistLibrarySort();
    _reconcileLibrarySelection();
  }

  void toggleLibrarySortDirection() {
    if (!acceptsPlaybackCommands) return;
    librarySortDescending.value = !librarySortDescending.value;
    _persistLibrarySortDirection();
    _reconcileLibrarySelection();
  }

  Future<void> refreshMissing() async {
    if (!acceptsPlaybackCommands || _library == null || libraryBusy) return;
    isRefreshing.value = true;
    try {
      await _library.refreshMissing();
      if (acceptsPlaybackCommands) {
        await playlists.refreshMissing(_library.songs.toList());
      }
      if (acceptsPlaybackCommands) {
        await history?.refreshMissing(_library.songs.toList());
      }
      if (acceptsPlaybackCommands) _player.updateSongs(_library.songs.toList());
    } catch (_) {
      if (!_closed) errorMessage.value = '无法检查文件状态，请稍后重试。';
    } finally {
      if (!_closed) isRefreshing.value = false;
    }
  }

  Future<void> playLibrarySong(Song song) async {
    if (!canChangeLibrarySelection || song.isMissing) return;
    final playable = visibleSongs.where((item) => !item.isMissing).toList();
    final index = playable.indexWhere((item) => item.id == song.id);
    if (index >= 0) await _player.playQueue(playable, startIndex: index);
  }

  Future<void> playVisibleSongs() async {
    if (!acceptsPlaybackCommands || isLoading.value) return;
    final playable = visibleSongs.where((song) => !song.isMissing).toList();
    if (playable.isNotEmpty) await _player.playQueue(playable);
  }

  ({int added, int existing, int unavailable}) addVisibleSongsToQueue() {
    if (!acceptsPlaybackCommands) {
      return (added: 0, existing: 0, unavailable: 0);
    }
    final visible = visibleSongs;
    final playable = visible.where((song) => !song.isMissing).toList();
    final unavailable = visible.length - playable.length;
    if (playable.isEmpty) {
      return (added: 0, existing: 0, unavailable: unavailable);
    }
    final previousLength = queue.length;
    final result = _player.addToQueue(playable);
    if (result == QueueAddResult.unavailable) {
      return (added: 0, existing: 0, unavailable: visible.length);
    }
    final added = queue.length - previousLength;
    return (
      added: added,
      existing: playable.length - added,
      unavailable: unavailable,
    );
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
    final current = _resolveKnownSong(song);
    if (current == null || !isSongAvailable(current)) {
      return QueueAddResult.unavailable;
    }
    return _player.addToQueue([current]);
  }

  Song? _resolveKnownSong(Song song) {
    if (song.isOnline || _library == null) return song;
    final indexed =
        _library.songs.firstWhereOrNull((item) => item.id == song.id) ??
        queue.firstWhereOrNull((item) => item.id == song.id);
    if (indexed != null) return indexed;
    for (final playlist in playlists.playlists) {
      final saved = playlist.songs.firstWhereOrNull(
        (item) => item.id == song.id,
      );
      if (saved != null) return saved;
    }
    return historyEntries
        .firstWhereOrNull((entry) => entry.song.id == song.id)
        ?.song;
  }

  bool isHistorySongAvailable(Song song) {
    final current = _resolveKnownSong(song);
    return current != null && isSongAvailable(current);
  }

  Future<void> playHistorySong(Song song) async {
    if (!acceptsPlaybackCommands || isLoading.value) return;
    final current = _resolveKnownSong(song);
    if (current != null && isSongAvailable(current)) {
      await _player.playQueue([current]);
    }
  }

  QueueAddResult enqueueHistorySong(Song song) => addToQueue(song);

  void clearHistory() {
    if (acceptsPlaybackCommands) history?.clear();
  }

  void removeHistorySong(String songId) {
    if (acceptsPlaybackCommands) history?.remove(songId);
  }

  bool isSongAvailable(Song song) =>
      !song.isMissing &&
      (!song.isOnline ||
          online?.sources.any((source) => source.id == song.sourceId) == true);

  QueueAddResult playNext(Song song) {
    if (!acceptsPlaybackCommands) return QueueAddResult.unavailable;
    final current = _resolveKnownSong(song);
    if (current == null || !isSongAvailable(current)) {
      return QueueAddResult.unavailable;
    }
    return _player.playNext(current);
  }

  bool isFavorite(Song song) => playlists.isFavorite(song.id);

  bool toggleFavorite(Song song) {
    if (!acceptsPlaybackCommands) return isFavorite(song);
    if (isFavorite(song)) return playlists.toggleFavorite(song);
    final current = _resolveKnownSong(song);
    return current != null && playlists.toggleFavorite(current);
  }

  Playlist createPlaylist(String name) {
    if (!acceptsPlaybackCommands) throw const FormatException('正在退出，暂时无法创建歌单。');
    return playlists.create(name);
  }

  void renamePlaylist(String id, String name) {
    if (!acceptsPlaybackCommands) throw const FormatException('正在退出，暂时无法修改歌单。');
    playlists.rename(id, name);
  }

  void deletePlaylist(String id) {
    if (acceptsPlaybackCommands) playlists.delete(id);
  }

  ({int added, int existing}) addSongsToPlaylist(
    String id,
    List<Song> songs, {
    bool preserveUnknown = false,
  }) {
    if (!acceptsPlaybackCommands) return (added: 0, existing: 0);
    final checked = preserveUnknown
        ? songs.map(Playlist.validateSong).toList()
        : songs;
    final current = checked
        .map(
          (song) => _resolveKnownSong(song) ?? (preserveUnknown ? song : null),
        )
        .whereType<Song>()
        .toList();
    return playlists.addSongs(id, current);
  }

  void removePlaylistSong(String id, String songId) {
    if (acceptsPlaybackCommands) playlists.removeSong(id, songId);
  }

  void reorderPlaylistSongs(String id, int oldIndex, int newIndex) {
    if (acceptsPlaybackCommands) playlists.reorderSongs(id, oldIndex, newIndex);
  }

  List<Song> playlistSongs(String id) {
    final songs = playlists.findById(id)?.songs ?? const <Song>[];
    final indexed = {
      for (final song in _library?.songs ?? <Song>[]) song.id: song,
    };
    return songs.map((song) => indexed[song.id] ?? song).toList();
  }

  Future<void> playPlaylist(String id, {String? startSongId}) async {
    if (!acceptsPlaybackCommands || isLoading.value) return;
    final playable = playlistSongs(id).where(isSongAvailable).toList();
    if (playable.isEmpty) return;
    final index = startSongId == null
        ? 0
        : playable.indexWhere((song) => song.id == startSongId);
    if (index >= 0) await _player.playQueue(playable, startIndex: index);
  }

  ({int added, int existing, int unavailable}) enqueuePlaylist(String id) {
    if (!acceptsPlaybackCommands) {
      return (added: 0, existing: 0, unavailable: 0);
    }
    final songs = playlistSongs(id);
    final playable = songs.where(isSongAvailable).toList();
    if (playable.isEmpty) {
      return (added: 0, existing: 0, unavailable: songs.length);
    }
    final before = queue.length;
    if (_player.addToQueue(playable) == QueueAddResult.unavailable) {
      return (added: 0, existing: 0, unavailable: songs.length);
    }
    final added = queue.length - before;
    return (
      added: added,
      existing: playable.length - added,
      unavailable: songs.length - playable.length,
    );
  }

  Future<void> playQueueItem(int index) => _player.playAt(index);
  Future<void> next() => _player.next();
  Future<void> previous() => _player.previous();
  void reorderQueue(int oldIndex, int newIndex) =>
      _player.reorderQueue(oldIndex, newIndex);
  Future<void> removeFromQueue(String id) => _player.removeFromQueue(id);
  Future<void> clearQueue() async {
    if (_closed || _exitPending) return;
    await _player.clearQueue();
  }

  void cyclePlayMode() {
    final modes = PlayMode.values;
    _player.playMode.value =
        modes[(modes.indexOf(_player.playMode.value) + 1) % modes.length];
  }

  Future<void> togglePlayback() => _player.togglePlayback();
  Future<void> retryPlayback(String songId) async {
    if (!canRetryPlayback || currentSong.value?.id != songId) return;
    // The queue can be reordered between rendering the action and invoking it.
    final index = queue.indexWhere((song) => song.id == songId);
    if (index >= 0) await _player.playAt(index);
  }

  Future<void> seek(Duration value) => _player.seek(value);
  Future<void> setVolume(double value) async {
    if (_closed || _exitPending || !value.isFinite) return;
    final current = volume.value;
    if (current > 0) _unmuteVolume = current;
    final target = value.clamp(0.0, 1.0);
    await _player.setVolume(target);
    if (!_closed && !_exitPending && target > 0 && volume.value == target) {
      _unmuteVolume = target;
    }
  }

  Future<void> toggleMute() => setVolume(volume.value > 0 ? 0 : _unmuteVolume);

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
    for (final worker in _settingsWorkers) {
      worker.dispose();
    }
    for (final worker in _selectionWorkers) {
      worker.dispose();
    }
    if (_ownsPlaylists) playlists.onClose();
    _importGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }
}
