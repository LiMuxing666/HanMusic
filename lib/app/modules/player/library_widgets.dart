part of 'view.dart';

class _LibraryPlayerPage extends StatefulWidget {
  const _LibraryPlayerPage({
    required this.controller,
    this.libraryScrollController,
    this.libraryRowDiagnostics,
  });
  final PlayerController controller;
  final ScrollController? libraryScrollController;
  final LibraryRowLifecycleDiagnostics? libraryRowDiagnostics;

  @override
  State<_LibraryPlayerPage> createState() => _LibraryPlayerPageState();
}

class _LibraryPlayerPageState extends State<_LibraryPlayerPage> {
  int _section = 0;
  final _librarySearchKey = GlobalKey<MusicSearchFieldState>();
  final _onlineSearchKey = GlobalKey<MusicSearchFieldState>();
  final _historySearchKey = GlobalKey<MusicSearchFieldState>();
  PlayerController get controller => widget.controller;
  OnlineMusicController? _online;
  MusicRecognitionService? _recognition;
  ({String message, bool canOpenQueue})? _queueNotice;

  void _showDetails(Song song) =>
      showSongDetails(context, song, sourceName: controller.sourceLabel(song));

  void _enqueueSelectedAndNotify() {
    final result = controller.enqueueSelectedLibrarySongs();
    setState(
      () => _queueNotice = (
        message:
            '已加入 ${result.added} 首，已在队列 ${result.existing} 首'
            '${result.unavailable > 0 ? '，跳过缺失或不可用 ${result.unavailable} 首' : ''}。',
        canOpenQueue: result.added + result.existing > 0,
      ),
    );
  }

  Future<void> _addSelectedToPlaylist() async {
    if (!controller.canChangeLibrarySelection) return;
    final ids = controller.selectedLibrarySongs.map((song) => song.id).toList();
    final generation = controller.commandGeneration;
    if (ids.isEmpty) return;
    final message = await showDialog<String>(
      context: context,
      builder: (_) => _BatchLibraryPlaylistDialog(
        controller: controller,
        songIds: ids,
        generation: generation,
      ),
    );
    if (mounted && message != null) {
      setState(() => _queueNotice = (message: message, canOpenQueue: false));
    }
  }

  Future<void> _removeSelectedFromLibrary() async {
    if (!controller.canChangeLibrarySelection) return;
    final ids = controller.selectedLibrarySongs.map((song) => song.id).toList();
    final generation = controller.commandGeneration;
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('从曲库移除 ${ids.length} 首歌曲？'),
        content: const Text('仅移除曲库索引及播放队列中的对应项目。不会删除源文件，歌单和播放历史也会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('library-remove-selected-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除索引，保留文件'),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        generation != controller.commandGeneration) {
      return;
    }
    final removed = await controller.removeSelectedLibrarySongs(songIds: ids);
    if (mounted) {
      setState(
        () => _queueNotice = (
          message: '已从曲库移除 $removed 首，源文件已保留。',
          canOpenQueue: false,
        ),
      );
    }
  }

  KeyEventResult _handleLibraryKey(KeyEvent event) {
    if (_section != 0 ||
        !controller.acceptsPlaybackCommands ||
        ModalRoute.of(context)?.isCurrent == false ||
        event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return KeyEventResult.ignored;
    }
    if (const SingleActivator(
      LogicalKeyboardKey.keyA,
      control: true,
    ).accepts(event, HardwareKeyboard.instance)) {
      if (!controller.canChangeLibrarySelection) return KeyEventResult.ignored;
      controller.selectAllVisibleLibrarySongs();
      return KeyEventResult.handled;
    }
    if (const SingleActivator(
          LogicalKeyboardKey.escape,
        ).accepts(event, HardwareKeyboard.instance) &&
        controller.librarySelectionMode.value) {
      controller.exitLibrarySelection();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _playNextAndNotify(Song song) {
    final wasEmpty = controller.queue.isEmpty;
    final result = controller.playNext(song);
    if (!mounted) return;
    setState(
      () => _queueNotice = (
        message: switch (result) {
          QueueAddResult.added =>
            wasEmpty ? '已加入队列，点击播放开始：${song.title}' : '已设为下一首：${song.title}',
          QueueAddResult.unchanged =>
            controller.currentSong.value?.id == song.id
                ? '这首歌已是当前歌曲。'
                : '已安排为下一首：${song.title}',
          QueueAddResult.unavailable => '暂时无法安排播放，请检查歌曲或音乐源状态。',
        },
        canOpenQueue: result != QueueAddResult.unavailable,
      ),
    );
  }

  Future<void> _addToPlaylist(Song song) async {
    final message = await showDialog<String>(
      context: context,
      builder: (_) => _AddToPlaylistDialog(controller: controller, song: song),
    );
    if (mounted && message != null) {
      setState(() => _queueNotice = (message: message, canOpenQueue: false));
    }
  }

  void _enqueueAndNotify(Song song) {
    if (!mounted) return;
    final result = controller.addToQueue(song);
    setState(() {
      _queueNotice = (
        message: switch (result) {
          QueueAddResult.added => '已加入播放队列：${song.title}',
          QueueAddResult.unchanged => '已在播放队列中：${song.title}',
          QueueAddResult.unavailable => '暂时无法加入播放队列，请检查歌曲状态。',
        },
        canOpenQueue: result != QueueAddResult.unavailable,
      );
    });
  }

  void _enqueueVisibleAndNotify() {
    if (!mounted) return;
    final result = controller.addVisibleSongsToQueue();
    setState(() {
      _queueNotice = (
        message:
            '已加入 ${result.added} 首，已在队列 ${result.existing} 首'
            '${result.unavailable > 0 ? '，跳过缺失 ${result.unavailable} 首' : ''}。',
        canOpenQueue: result.added + result.existing > 0,
      );
    });
  }

  void _selectSection(int section) => setState(() {
    _section = section;
    _queueNotice = null;
  });

  @override
  void initState() {
    super.initState();
    if (Get.isRegistered<MusicRecognitionService>()) {
      _recognition = Get.find<MusicRecognitionService>();
    }
    final service = controller.online;
    if (service != null) {
      _online = OnlineMusicController(
        service: service,
        playSong: controller.playOnlineSong,
        enqueueSong: _enqueueAndNotify,
      );
    }
  }

  @override
  void dispose() {
    _online?.onClose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
        if (ModalRoute.of(context)?.isCurrent == false) return;
        if (_section == 0) _librarySearchKey.currentState?.focusAndSelect();
        if (_section == 3) _onlineSearchKey.currentState?.focusAndSelect();
        if (_section == 5) _historySearchKey.currentState?.focusAndSelect();
      },
    },
    child: FocusScope(
      autofocus: true,
      skipTraversal: true,
      onKeyEvent: (_, event) => _handleLibraryKey(event),
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, bounds) {
              final compact = bounds.maxWidth < 1100;
              return Row(
                children: [
                  _LibraryNavigation(
                    controller: controller,
                    compact: compact,
                    selected: _section,
                    showOnline: _online != null,
                    showRecognition: _recognition != null,
                    onSelected: _selectSection,
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              compact ? 18 : 28,
                              20,
                              compact ? 18 : 28,
                              0,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (_section < 3)
                                  _LibraryHeader(
                                    controller: controller,
                                    section: _section,
                                  ),
                                const SizedBox(height: 14),
                                Obx(() {
                                  final error = controller.errorMessage.value;
                                  if (error == null || error.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  final song = controller.currentSong.value;
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: _ErrorNotice(
                                      message: error,
                                      onDismiss: controller.dismissError,
                                      onRetry: controller.canRetryPlayback
                                          ? () => controller.retryPlayback(
                                              song!.id,
                                            )
                                          : null,
                                    ),
                                  );
                                }),
                                Expanded(
                                  child: switch (_section) {
                                    1 => SingleChildScrollView(
                                      child: Column(
                                        children: [
                                          _SongCard(controller: controller),
                                          const SizedBox(height: 16),
                                          _LyricsCard(controller: controller),
                                          const SizedBox(height: 16),
                                          _SleepTimerCard(
                                            controller: controller,
                                          ),
                                          const SizedBox(height: 20),
                                        ],
                                      ),
                                    ),
                                    2 => _QueueView(
                                      key: ObjectKey(controller),
                                      controller: controller,
                                      onPlayNext: _playNextAndNotify,
                                      onAddToPlaylist: _addToPlaylist,
                                    ),
                                    3 => OnlineMusicPage(
                                      controller: _online!,
                                      searchFieldKey: _onlineSearchKey,
                                      onPlayNext: _playNextAndNotify,
                                      onFavorite: (song) =>
                                          controller.toggleFavorite(song),
                                      isFavorite: controller.isFavorite,
                                      onAddToPlaylist: _addToPlaylist,
                                      onDetails: (song) => showSongDetails(
                                        context,
                                        song,
                                        sourceName: controller.sourceLabel(
                                          song,
                                        ),
                                      ),
                                    ),
                                    4 => _PlaylistsView(
                                      controller: controller,
                                      onQueue: _enqueueAndNotify,
                                      onPlayNext: _playNextAndNotify,
                                      onAddToPlaylist: _addToPlaylist,
                                    ),
                                    5 => _HistoryView(
                                      controller: controller,
                                      searchKey: _historySearchKey,
                                      onAddToPlaylist: _addToPlaylist,
                                      onShowDetails: _showDetails,
                                      onPlayNext: _playNextAndNotify,
                                    ),
                                    6 => SettingsPage(controller: controller),
                                    7 => RecognitionPage(
                                      service: _recognition!,
                                      canOperate: () =>
                                          controller.acceptsPlaybackCommands,
                                      onSearchLibrary: (title) {
                                        if (!controller
                                            .acceptsPlaybackCommands) {
                                          return;
                                        }
                                        controller.setSearchQuery(title);
                                        _selectSection(0);
                                      },
                                      onSearchOnline: _online == null
                                          ? null
                                          : (title) {
                                              if (!controller
                                                  .acceptsPlaybackCommands) {
                                                return;
                                              }
                                              _online!.setQuery(title);
                                              _selectSection(3);
                                              unawaited(_online!.searchNow());
                                            },
                                    ),
                                    _ => _LibraryView(
                                      controller: controller,
                                      searchFieldKey: _librarySearchKey,
                                      onQueue: _enqueueAndNotify,
                                      onQueueAll: _enqueueVisibleAndNotify,
                                      onPlayNext: _playNextAndNotify,
                                      onAddToPlaylist: _addToPlaylist,
                                      onQueueSelected:
                                          _enqueueSelectedAndNotify,
                                      onAddSelectedToPlaylist:
                                          _addSelectedToPlaylist,
                                      onRemoveSelected:
                                          _removeSelectedFromLibrary,
                                      scrollController:
                                          widget.libraryScrollController,
                                      rowDiagnostics:
                                          widget.libraryRowDiagnostics,
                                    ),
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_queueNotice case final notice?)
                          _QueueActionNotice(
                            message: notice.message,
                            onOpenQueue: notice.canOpenQueue
                                ? () => _selectSection(2)
                                : null,
                            onDismiss: () =>
                                setState(() => _queueNotice = null),
                          ),
                        _DesktopTransport(controller: controller),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _QueueActionNotice extends StatelessWidget {
  const _QueueActionNotice({
    required this.message,
    required this.onOpenQueue,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback? onOpenQueue;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      key: const Key('queue-action-notice'),
      margin: const EdgeInsets.fromLTRB(18, 8, 18, 0),
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        color: HanMusicColors.of(context).selectedSurface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            onOpenQueue == null
                ? Icons.info_outline_rounded
                : Icons.playlist_add_check_rounded,
            color: Theme.of(context).colorScheme.primary,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Tooltip(
              message: message,
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          if (onOpenQueue != null)
            TextButton(
              key: const Key('queue-notice-open'),
              onPressed: onOpenQueue,
              child: const Text('查看队列'),
            ),
          IconButton(
            key: const Key('queue-notice-dismiss'),
            tooltip: '关闭队列提示',
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    ),
  );
}

class _LibraryNavigation extends StatelessWidget {
  const _LibraryNavigation({
    required this.controller,
    required this.compact,
    required this.selected,
    required this.onSelected,
    required this.showOnline,
    required this.showRecognition,
  });
  final PlayerController controller;
  final bool compact;
  final bool showOnline;
  final bool showRecognition;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Container(
    width: compact ? 76 : 196,
    padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 18, vertical: 26),
    color: const Color(0xFF193D2E),
    child: Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.graphic_eq_rounded,
              color: Color(0xFFBFE4B6),
              size: 30,
            ),
            if (!compact) ...[
              const SizedBox(width: 9),
              const Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'HanMusic',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 40),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final item in [
                  (index: 0, label: '本地曲库', icon: Icons.library_music_outlined),
                  (index: 1, label: '正在播放', icon: Icons.album_outlined),
                  (index: 2, label: '播放队列', icon: Icons.queue_music_rounded),
                  (
                    index: 4,
                    label: '我的歌单',
                    icon: Icons.favorite_border_rounded,
                  ),
                  (index: 5, label: '最近播放', icon: Icons.history_rounded),
                  if (showOnline)
                    (index: 3, label: '在线音乐', icon: Icons.cloud_outlined),
                  if (showRecognition)
                    (index: 7, label: '听歌识曲', icon: Icons.hearing_rounded),
                  (index: 6, label: '设置', icon: Icons.settings_outlined),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: Tooltip(
                      message: item.label,
                      child: Semantics(
                        selected: selected == item.index,
                        child: Material(
                          color: selected == item.index
                              ? const Color(0xFF315542)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            key: Key('nav-${item.index}'),
                            onTap: () => onSelected(item.index),
                            borderRadius: BorderRadius.circular(12),
                            child: SizedBox(
                              height: 50,
                              child: Row(
                                mainAxisAlignment: compact
                                    ? MainAxisAlignment.center
                                    : MainAxisAlignment.start,
                                children: [
                                  if (!compact) const SizedBox(width: 12),
                                  Icon(
                                    item.icon,
                                    color: selected == item.index
                                        ? const Color(0xFFE0F2D8)
                                        : const Color(0xFFA8C3B3),
                                    size: 22,
                                  ),
                                  if (!compact) ...[
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        item.label,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: selected == item.index
                                              ? Colors.white
                                              : const Color(0xFFA8C3B3),
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        IconButton(
          key: const Key('playback-shortcuts-help'),
          tooltip: '键盘快捷键',
          color: const Color(0xFF92B3A0),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const _PlaybackShortcutsDialog(),
          ),
          icon: const Icon(Icons.keyboard_outlined),
        ),
        const SizedBox(height: 8),
        Obx(
          () => controller.trayAvailable.value
              ? IconButton(
                  key: const Key('hide-to-tray'),
                  tooltip: '收起到托盘（继续播放）',
                  color: const Color(0xFF92B3A0),
                  icon: const Icon(Icons.system_update_alt_rounded, size: 20),
                  onPressed: () async {
                    final hidden = await controller.hideToTray();
                    if (!hidden && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('暂时无法收起到托盘，请稍后重试。')),
                      );
                    }
                  },
                )
              : const Icon(
                  Icons.desktop_windows_outlined,
                  color: Color(0xFF92B3A0),
                  size: 20,
                ),
        ),
        if (!compact) ...[
          const SizedBox(height: 8),
          const Text(
            'Windows 版',
            style: TextStyle(color: Color(0xFF92B3A0), fontSize: 12),
          ),
        ],
      ],
    ),
  );
}

class _PlaybackShortcutsDialog extends StatelessWidget {
  const _PlaybackShortcutsDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('键盘快捷键'),
    content: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final shortcut in const [
            ('Ctrl + Space', '播放 / 暂停 / 重试'),
            ('Ctrl + ← / →', '上一首 / 下一首'),
            ('Ctrl + Shift + ← / →', '快退 / 快进 5 秒'),
            ('Ctrl + ↑ / ↓', '音量增加 / 减少 5%'),
            ('Ctrl + M', '静音 / 恢复音量'),
            ('Ctrl + F', '聚焦当前页面搜索'),
            ('Ctrl + 单击', '曲库：增选 / 取消选择歌曲，不播放'),
            ('Shift + 单击', '曲库：按当前筛选与排序范围选择'),
            ('Ctrl + Shift + 单击', '曲库：保留已选歌曲并追加范围'),
            ('Ctrl + A', '曲库：选中当前可见歌曲；输入框内仍为全选文字'),
            ('Esc', '曲库：退出选择；搜索框内清空搜索'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(shortcut.$2),
                  Text(
                    shortcut.$1,
                    style: TextStyle(
                      color: HanMusicColors.of(context).muted,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          Text(
            '点击“选择歌曲”可显示复选框和批量操作。播放与曲库选择快捷键在应用窗口内生效，编辑文字或打开弹窗时不接管操作。',
            style: TextStyle(
              color: HanMusicColors.of(context).muted,
              fontSize: 12,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('知道了'),
      ),
    ],
  );
}

class _LibraryHeader extends StatelessWidget {
  const _LibraryHeader({required this.controller, required this.section});
  final PlayerController controller;
  final int section;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ['本地曲库', '正在播放', '播放队列'][section],
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 5),
            Obx(
              () => Text(
                section == 2
                    ? '${controller.queue.length} 首音乐，接着听下去。'
                    : '${controller.songs.length} 首本地音乐，随时聆听。',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: HanMusicColors.of(context).muted,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 12),
      Obx(
        () => FilledButton.icon(
          key: const Key('import-file'),
          onPressed: controller.libraryBusy ? null : controller.importFile,
          icon: const Icon(Icons.add_rounded, size: 20),
          label: Text(
            controller.isImporting.value && !controller.isScanning.value
                ? '选择中…'
                : '导入音乐',
          ),
        ),
      ),
      const SizedBox(width: 4),
      Obx(
        () => PopupMenuButton<String>(
          key: const Key('library-actions'),
          tooltip: '更多曲库操作',
          enabled: !controller.libraryBusy,
          onSelected: (value) {
            if (value == 'directory') controller.importDirectory();
            if (value == 'refresh') controller.refreshMissing();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'directory', child: Text('导入文件夹（包含子文件夹）')),
            PopupMenuItem(value: 'refresh', child: Text('检查缺失文件')),
          ],
        ),
      ),
    ],
  );
}

class _LibraryView extends StatelessWidget {
  const _LibraryView({
    required this.controller,
    required this.searchFieldKey,
    required this.onQueue,
    required this.onQueueAll,
    required this.onPlayNext,
    required this.onAddToPlaylist,
    required this.onQueueSelected,
    required this.onAddSelectedToPlaylist,
    required this.onRemoveSelected,
    this.scrollController,
    this.rowDiagnostics,
  });
  final PlayerController controller;
  final GlobalKey<MusicSearchFieldState> searchFieldKey;
  final ValueChanged<Song> onQueue;
  final VoidCallback onQueueAll;
  final ValueChanged<Song> onPlayNext;
  final ValueChanged<Song> onAddToPlaylist;
  final VoidCallback onQueueSelected;
  final VoidCallback onAddSelectedToPlaylist;
  final VoidCallback onRemoveSelected;
  final ScrollController? scrollController;
  final LibraryRowLifecycleDiagnostics? rowDiagnostics;

  void _activateSong(Song song) {
    final keyboard = HardwareKeyboard.instance;
    if (controller.librarySelectionMode.value ||
        keyboard.isControlPressed ||
        keyboard.isShiftPressed) {
      controller.selectLibrarySong(
        song,
        toggle: !keyboard.isShiftPressed || keyboard.isControlPressed,
        range: keyboard.isShiftPressed,
      );
    } else {
      controller.playLibrarySong(song);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final compactControls =
          bounds.maxHeight < 340 ||
          (bounds.maxWidth < 700 &&
              MediaQuery.textScalerOf(context).scale(14) > 21);
      return Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Obx(
                  () => MusicSearchField(
                    key: searchFieldKey,
                    inputKey: const ValueKey('library-search'),
                    query: controller.searchQuery.value,
                    onChanged: controller.setSearchQuery,
                  ),
                ),
              ),
              if (compactControls)
                _LibraryControls(
                  controller: controller,
                  onQueueAll: onQueueAll,
                  compact: true,
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (!compactControls) ...[
            _LibraryControls(controller: controller, onQueueAll: onQueueAll),
            const SizedBox(height: 8),
          ],
          Obx(
            () => controller.librarySelectionMode.value
                ? _LibrarySelectionToolbar(
                    controller: controller,
                    onQueue: onQueueSelected,
                    onPlaylist: onAddSelectedToPlaylist,
                    onRemove: onRemoveSelected,
                  )
                : const SizedBox.shrink(),
          ),
          Obx(() {
            final scanning = controller.isScanning.value;
            final refreshing = controller.isRefreshing.value;
            final status = controller.libraryStatus.value;
            if (refreshing) {
              return Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Text(
                      '正在检查文件状态…',
                      style: TextStyle(
                        color: HanMusicColors.of(context).muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              );
            }
            if (!scanning && (status == null || status.isEmpty)) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          scanning
                              ? '正在导入 ${controller.importProcessed.value} / ${controller.importDiscovered.value} · ${status ?? "读取音乐"}'
                              : status!,
                          style: TextStyle(
                            color: HanMusicColors.of(context).muted,
                            fontSize: 12,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (scanning)
                        TextButton(
                          key: const Key('cancel-import'),
                          onPressed: controller.cancelImport,
                          child: const Text('取消扫描'),
                        ),
                    ],
                  ),
                  if (scanning) const LinearProgressIndicator(minHeight: 2),
                ],
              ),
            );
          }),
          Expanded(
            child: Obx(() {
              final songs = controller.visibleSongs;
              final currentId = controller.currentSong.value?.id;
              final selectionMode = controller.librarySelectionMode.value;
              final selectedIds = controller.selectedLibraryIds.toSet();
              final selectionEnabled = controller.canChangeLibrarySelection;
              if (songs.isEmpty) {
                return _LibraryEmpty(
                  searching: controller.searchQuery.value.isNotEmpty,
                  busy: controller.libraryBusy,
                  onImport: controller.importFile,
                );
              }
              final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
              final rowExtent = 78 + (textScale - 1).clamp(0.0, 4.0) * 36;
              // Resolve moved rows by song identity, preserving their focused state.
              // Build this snapshot's lookup only when the sliver needs to remap;
              // ordinary scrolling does not create a map for the entire library.
              Map<String, int>? songIndexes;
              return LayoutBuilder(
                builder: (context, bounds) => ListView.builder(
                  key: const Key('library-list'),
                  controller: scrollController,
                  itemCount: songs.length,
                  itemExtent: rowExtent,
                  findChildIndexCallback: (key) {
                    if (key is! ValueKey<String>) return null;
                    final indexes = songIndexes ??= {
                      for (var index = 0; index < songs.length; index++)
                        songs[index].id: index,
                    };
                    return indexes[key.value];
                  },
                  // Build rows as they enter the viewport, without offscreen layout.
                  cacheExtent: 0,
                  // InkWell requests keep-alive only for active ink/focus, allowing
                  // keyboard paging to retain its focused row until focus leaves.
                  addAutomaticKeepAlives: true,
                  padding: const EdgeInsets.only(bottom: 14),
                  itemBuilder: (context, index) {
                    final song = songs[index];
                    final rowKey = ValueKey(song.id);
                    final wide = bounds.maxWidth >= 850;
                    final row = _LibrarySongRow(
                      key: rowDiagnostics == null ? rowKey : null,
                      song: song,
                      current: currentId == song.id,
                      wide: wide,
                      diagnostics: rowDiagnostics,
                      selectionMode: selectionMode,
                      selected: selectedIds.contains(song.id),
                      selectionEnabled: selectionEnabled,
                      onSelect: () => controller.selectLibrarySong(song),
                      onPlay: () => _activateSong(song),
                      onQueue: () => onQueue(song),
                      onPlayNext: () => onPlayNext(song),
                      onFavorite: () => controller.toggleFavorite(song),
                      isFavorite: () => controller.isFavorite(song),
                      onAddToPlaylist: () => onAddToPlaylist(song),
                      onDetails: () => showSongDetails(context, song),
                      onRemove: () =>
                          _confirmLibraryRemoval(context, controller, song),
                    );
                    final diagnostics = rowDiagnostics;
                    if (diagnostics == null) return row;
                    // The sliver still sees the same song identity as its direct
                    // child's key. This extra Element exists only in diagnostics.
                    return _DiagnosticLibraryRow(
                      key: rowKey,
                      diagnostics: diagnostics,
                      wideAtMount: wide,
                      child: row,
                    );
                  },
                ),
              );
            }),
          ),
        ],
      );
    },
  );
}

class _LibrarySelectionToolbar extends StatelessWidget {
  const _LibrarySelectionToolbar({
    required this.controller,
    required this.onQueue,
    required this.onPlaylist,
    required this.onRemove,
  });
  final PlayerController controller;
  final VoidCallback onQueue;
  final VoidCallback onPlaylist;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Obx(() {
    final count = controller.selectedLibraryIds.length;
    final enabled = count > 0 && controller.canChangeLibrarySelection;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 4,
        children: [
          Semantics(
            liveRegion: true,
            child: Text(
              '已选 $count 首',
              key: const Key('library-selection-count'),
            ),
          ),
          TextButton(
            key: const Key('library-select-all'),
            onPressed: controller.canChangeLibrarySelection
                ? controller.selectAllVisibleLibrarySongs
                : null,
            child: const Text('全选可见歌曲'),
          ),
          TextButton(
            key: const Key('library-enqueue-selected'),
            onPressed: enabled ? onQueue : null,
            child: const Text('批量入队'),
          ),
          TextButton(
            key: const Key('library-playlist-selected'),
            onPressed: enabled ? onPlaylist : null,
            child: const Text('加入歌单'),
          ),
          TextButton(
            key: const Key('library-remove-selected'),
            onPressed: enabled ? onRemove : null,
            child: const Text('移除曲库索引'),
          ),
          TextButton(
            key: const Key('library-selection-done'),
            onPressed: controller.exitLibrarySelection,
            child: const Text('完成选择'),
          ),
        ],
      ),
    );
  });
}

class _BatchLibraryPlaylistDialog extends StatefulWidget {
  const _BatchLibraryPlaylistDialog({
    required this.controller,
    required this.songIds,
    required this.generation,
  });
  final PlayerController controller;
  final List<String> songIds;
  final int generation;

  @override
  State<_BatchLibraryPlaylistDialog> createState() =>
      _BatchLibraryPlaylistDialogState();
}

class _BatchLibraryPlaylistDialogState
    extends State<_BatchLibraryPlaylistDialog> {
  String? _error;

  void _add(String id) {
    if (!widget.controller.canChangeLibrarySelection ||
        widget.generation != widget.controller.commandGeneration) {
      Navigator.pop(context, '操作状态已改变，请重新选择歌曲。');
      return;
    }
    try {
      final result = widget.controller.addSelectedLibrarySongsToPlaylist(
        id,
        songIds: widget.songIds,
      );
      final name = widget.controller.playlists.findById(id)?.name ?? '歌单';
      Navigator.pop(
        context,
        '已向“$name”添加 ${result.added} 首，已存在 ${result.existing} 首'
        '${result.unavailable > 0 ? '，跳过缺失或不可用 ${result.unavailable} 首' : ''}。',
      );
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('将 ${widget.songIds.length} 首歌曲加入歌单'),
    scrollable: true,
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('已存在的歌曲不会重复添加，缺失或不可用的歌曲将跳过。'),
          const SizedBox(height: 12),
          SizedBox(
            height: 200,
            child: Obx(
              () => ListView(
                children: [
                  for (final playlist in widget.controller.playlists.playlists)
                    ListTile(
                      key: ValueKey('batch-playlist-${playlist.id}'),
                      title: Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _add(playlist.id),
                    ),
                ],
              ),
            ),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}

class _LibraryControls extends StatelessWidget {
  const _LibraryControls({
    required this.controller,
    required this.onQueueAll,
    this.compact = false,
  });

  final PlayerController controller;
  final VoidCallback onQueueAll;
  final bool compact;

  @override
  Widget build(BuildContext context) => Obx(() {
    final songs = controller.visibleSongs;
    final playableCount = songs.where((song) => !song.isMissing).length;
    final available = playableCount > 0 && controller.acceptsPlaybackCommands;
    final sort = controller.librarySort.value;
    final descending = controller.librarySortDescending.value;
    final searching = controller.searchQuery.value.trim().isNotEmpty;
    if (compact) {
      return PopupMenuButton<String>(
        key: const Key('library-controls-menu'),
        tooltip: '曲库操作与排序',
        icon: const Icon(Icons.tune_rounded),
        onSelected: (action) {
          switch (action) {
            case 'play':
              controller.playVisibleSongs();
            case 'queue':
              onQueueAll();
            case 'direction':
              controller.toggleLibrarySortDirection();
            case 'select':
              controller.enterLibrarySelection();
            default:
              for (final option in LibrarySort.values) {
                if (action == option.name) controller.setLibrarySort(option);
              }
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            enabled: false,
            child: Text('共 ${songs.length} 首 · 可播放 $playableCount 首'),
          ),
          PopupMenuItem(
            value: 'play',
            enabled: available && !controller.isLoading.value,
            child: Text(searching ? '播放结果' : '播放全部'),
          ),
          PopupMenuItem(
            value: 'queue',
            enabled: available,
            child: const Text('全部入队'),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'select',
            enabled: controller.canChangeLibrarySelection && songs.isNotEmpty,
            child: const Text('选择歌曲'),
          ),
          for (final option in LibrarySort.values)
            CheckedPopupMenuItem(
              value: option.name,
              checked: option == sort,
              child: Text(option.label),
            ),
          PopupMenuItem(
            value: 'direction',
            child: Text(descending ? '切换为升序' : '切换为降序'),
          ),
        ],
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          OutlinedButton.icon(
            key: const Key('library-selection-mode'),
            onPressed: controller.canChangeLibrarySelection && songs.isNotEmpty
                ? controller.enterLibrarySelection
                : null,
            icon: const Icon(Icons.checklist_rounded, size: 20),
            label: const Text('选择歌曲'),
          ),
          FilledButton.tonalIcon(
            key: const Key('library-play-visible'),
            onPressed: available && !controller.isLoading.value
                ? controller.playVisibleSongs
                : null,
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
            label: Text(searching ? '播放结果' : '播放全部'),
          ),
          OutlinedButton.icon(
            key: const Key('library-queue-visible'),
            onPressed: available ? onQueueAll : null,
            icon: const Icon(Icons.playlist_add_rounded, size: 20),
            label: const Text('全部入队'),
          ),
          PopupMenuButton<LibrarySort>(
            key: const Key('library-sort'),
            tooltip: '曲库排序',
            initialValue: sort,
            onSelected: controller.setLibrarySort,
            itemBuilder: (_) => [
              for (final option in LibrarySort.values)
                CheckedPopupMenuItem(
                  value: option,
                  checked: option == sort,
                  child: Text(option.label),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sort_rounded, size: 18),
                  const SizedBox(width: 6),
                  Text(sort.label),
                  const Icon(Icons.arrow_drop_down_rounded, size: 18),
                ],
              ),
            ),
          ),
          IconButton(
            key: const Key('library-sort-direction'),
            tooltip: descending ? '当前降序，切换为升序' : '当前升序，切换为降序',
            onPressed: controller.toggleLibrarySortDirection,
            icon: Icon(
              descending ? Icons.south_rounded : Icons.north_rounded,
              size: 20,
            ),
          ),
          Text(
            '共 ${songs.length} 首 · 可播放 $playableCount 首',
            key: const Key('library-result-count'),
            style: TextStyle(
              color: HanMusicColors.of(context).muted,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  });
}

class _DiagnosticLibraryRow extends StatefulWidget {
  const _DiagnosticLibraryRow({
    super.key,
    required this.diagnostics,
    required this.wideAtMount,
    required this.child,
  });

  final LibraryRowLifecycleDiagnostics diagnostics;
  final bool wideAtMount;
  final Widget child;

  @override
  State<_DiagnosticLibraryRow> createState() => _DiagnosticLibraryRowState();
}

class _DiagnosticLibraryRowState extends State<_DiagnosticLibraryRow> {
  late LibraryRowLifecycleDiagnostics _diagnostics;
  late bool _mountedWide;

  @override
  void initState() {
    super.initState();
    _diagnostics = widget.diagnostics;
    _mountedWide = widget.wideAtMount;
    _diagnostics._mount(_mountedWide);
  }

  @override
  void didUpdateWidget(_DiagnosticLibraryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.diagnostics, widget.diagnostics)) return;
    _diagnostics._dispose(_mountedWide);
    _diagnostics = widget.diagnostics;
    _mountedWide = widget.wideAtMount;
    _diagnostics._mount(_mountedWide);
  }

  @override
  void dispose() {
    _diagnostics._dispose(_mountedWide);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty({
    required this.searching,
    required this.busy,
    required this.onImport,
  });
  final bool searching;
  final bool busy;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            searching ? Icons.search_off_rounded : Icons.library_music_outlined,
            size: 42,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            searching ? '没有找到匹配的音乐' : '把喜欢的音乐收进曲库',
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            searching ? '换个关键词试试。' : '支持多选音乐文件，或从右上角导入整个文件夹。',
            style: TextStyle(
              color: HanMusicColors.of(context).muted,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
          if (!searching) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: busy ? null : onImport,
              icon: const Icon(Icons.add_rounded),
              label: const Text('选择音乐文件'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _LibrarySongRow extends StatelessWidget {
  const _LibrarySongRow({
    super.key,
    required this.song,
    required this.current,
    required this.wide,
    this.diagnostics,
    required this.selectionMode,
    required this.selected,
    required this.selectionEnabled,
    required this.onSelect,
    required this.onPlay,
    required this.onQueue,
    required this.onPlayNext,
    required this.onFavorite,
    required this.isFavorite,
    required this.onAddToPlaylist,
    required this.onDetails,
    required this.onRemove,
  });
  final Song song;
  final bool current;
  final bool wide;
  final LibraryRowLifecycleDiagnostics? diagnostics;
  final bool selectionMode;
  final bool selected;
  final bool selectionEnabled;
  final VoidCallback onSelect;
  final VoidCallback onPlay;
  final VoidCallback onQueue;
  final VoidCallback onPlayNext;
  final VoidCallback onFavorite;
  final bool Function() isFavorite;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onDetails;
  final VoidCallback onRemove;

  List<PopupMenuEntry<String>> _menuItems() => [
    PopupMenuItem(
      value: 'queue',
      enabled: !song.isMissing,
      child: const Text('加入播放队列'),
    ),
    PopupMenuItem(
      value: 'next',
      enabled: !song.isMissing,
      child: const Text('下一首播放'),
    ),
    PopupMenuItem(
      value: 'favorite',
      child: Text(isFavorite() ? '取消喜欢' : '加入我喜欢'),
    ),
    const PopupMenuItem(value: 'playlist', child: Text('添加到歌单')),
    const PopupMenuItem(value: 'details', child: Text('歌曲详情')),
    const PopupMenuItem(value: 'remove', child: Text('从曲库移除（保留文件）')),
  ];

  void _selectMenuAction(String action) {
    if (action == 'details') {
      onDetails();
    } else if (action == 'next') {
      if (!song.isMissing) onPlayNext();
    } else if (action == 'favorite') {
      onFavorite();
    } else if (action == 'playlist') {
      onAddToPlaylist();
    } else if (action == 'queue') {
      if (!song.isMissing) onQueue();
    } else if (action == 'remove') {
      onRemove();
    }
  }

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final position = overlay.globalToLocal(globalPosition);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: _menuItems(),
    );
    if (action != null && context.mounted) _selectMenuAction(action);
  }

  @override
  Widget build(BuildContext context) {
    diagnostics?._build(wide);
    final artist = song.artist?.trim().isNotEmpty == true
        ? song.artist!
        : '未知歌手';
    final album = song.album?.trim().isNotEmpty == true ? song.album! : '未知专辑';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected || current
            ? HanMusicColors.of(context).selectedSurface
            : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: ValueKey('library-song-${song.id}'),
          borderRadius: BorderRadius.circular(12),
          onTap: selectionEnabled ? onPlay : null,
          canRequestFocus: selectionMode || !song.isMissing,
          excludeFromSemantics: song.isMissing && !selectionMode,
          onSecondaryTapUp: (details) async =>
              _showContextMenu(context, details.globalPosition),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: [
                if (selectionMode)
                  Semantics(
                    label: '选择 ${song.title}',
                    child: Checkbox(
                      key: ValueKey('library-select-${song.id}'),
                      value: selected,
                      onChanged: selectionEnabled ? (_) => onSelect() : null,
                    ),
                  ),
                Opacity(
                  opacity: song.isMissing ? .45 : 1,
                  child: _SongThumbnail(song: song),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 4,
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: song.isMissing
                          ? HanMusicColors.of(context).muted
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: current
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: current
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          song.isMissing
                              ? '文件缺失 · 可检查或移除索引'
                              : wide
                              ? song.fileName
                              : '$artist · $album',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: HanMusicColors.of(context).muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (wide) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Text(
                      artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: HanMusicColors.of(context).muted,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Text(
                      album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: HanMusicColors.of(context).muted,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                Text(
                  song.duration == null ? '--:--' : _formatTime(song.duration!),
                  style: TextStyle(
                    color: HanMusicColors.of(context).muted,
                    fontSize: 12,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '${song.title}的操作',
                  onSelected: _selectMenuAction,
                  itemBuilder: (_) => _menuItems(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SongThumbnail extends StatelessWidget {
  const _SongThumbnail({required this.song, this.size = 44});
  final Song? song;
  final double size;

  @override
  Widget build(BuildContext context) {
    final artwork = song?.artworkPath;
    Widget fallback() => Container(
      color: HanMusicColors.of(context).coverSurface,
      child: Icon(
        Icons.music_note_rounded,
        color: Theme.of(context).colorScheme.primary,
        size: size * .52,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: SizedBox.square(
        dimension: size,
        child: artwork == null
            ? fallback()
            : Image.file(
                File(artwork),
                fit: BoxFit.cover,
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                errorBuilder: (_, _, _) => fallback(),
              ),
      ),
    );
  }
}

Future<void> _confirmLibraryRemoval(
  BuildContext context,
  PlayerController controller,
  Song song,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('从曲库移除？'),
      content: Text('“${song.title}”将从曲库和播放队列移除。电脑上的音乐文件会保留。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('保留'),
        ),
        FilledButton(
          key: const Key('confirm-remove-song'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('移除索引'),
        ),
      ],
    ),
  );
  if (confirmed == true) await controller.removeFromLibrary(song);
}

class _QueueView extends StatefulWidget {
  const _QueueView({
    super.key,
    required this.controller,
    required this.onPlayNext,
    required this.onAddToPlaylist,
  });
  final PlayerController controller;
  final ValueChanged<Song> onPlayNext;
  final ValueChanged<Song> onAddToPlaylist;

  @override
  State<_QueueView> createState() => _QueueViewState();
}

class _QueueViewState extends State<_QueueView> {
  PlayerController get controller => widget.controller;
  final _scrollController = ScrollController();
  late Worker _queueChanges;
  List<String>? _dragOrder;
  SliverReorderableListState? _reorderable;
  bool _queueCheckScheduled = false;
  bool _clearPending = false;
  bool _locateScheduled = false;

  double get _itemExtent {
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return 76 + (textScale - 1).clamp(0.0, 4.0) * 32;
  }

  @override
  void initState() {
    super.initState();
    _listenToQueue();
  }

  void _listenToQueue() {
    _queueChanges = ever<List<Song>>(controller.queue, (_) => _checkDragSoon());
  }

  void _checkDragSoon() {
    if (_dragOrder == null || _queueCheckScheduled) return;
    _queueCheckScheduled = true;
    // RxList.assignAll emits clear/addAll separately. Compare the final IDs
    // before the next frame so a metadata-only update preserves the drag.
    Future<void>.microtask(() {
      _queueCheckScheduled = false;
      if (!mounted) return;
      final order = _dragOrder;
      if (order != null && !_matchesQueue(order)) _cancelDrag();
    });
  }

  bool _matchesQueue(List<String> order) {
    final queue = controller.queue;
    if (order.length != queue.length) return false;
    for (var index = 0; index < order.length; index++) {
      if (order[index] != queue[index].id) return false;
    }
    return true;
  }

  void _cancelDrag() {
    if (_dragOrder == null) return;
    _dragOrder = null;
    final reorderable = _reorderable;
    if (reorderable != null && reorderable.mounted) {
      reorderable.cancelReorder();
    }
  }

  void _reorderQueue(List<Song> renderedQueue, int oldIndex, int newIndex) {
    final order = _dragOrder;
    final valid =
        _matchesQueue(renderedQueue.map((song) => song.id).toList()) &&
        (order == null || _matchesQueue(order));
    // Also handles accessibility reorder actions during a mouse drag. Cancel
    // before changing the list; onReorderEnd runs before the drop animation ends.
    _cancelDrag();
    if (valid) controller.reorderQueue(oldIndex, newIndex);
  }

  void _moveSong(String id, {required bool down}) {
    final index = controller.queue.indexWhere((song) => song.id == id);
    if (index < 0 ||
        (down ? index == controller.queue.length - 1 : index == 0)) {
      return;
    }
    _cancelDrag();
    controller.reorderQueue(index, down ? index + 2 : index - 1);
  }

  void _playSong(String id) {
    final index = controller.queue.indexWhere((song) => song.id == id);
    if (index >= 0 && !controller.queue[index].isMissing) {
      controller.playQueueItem(index);
    }
  }

  void _locateCurrent() {
    if (!mounted || _clearPending || _locateScheduled) return;
    _cancelDrag();
    _locateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _locateScheduled = false;
      if (!mounted || _clearPending || !_scrollController.hasClients) return;
      // Resolve identity and dimensions after any pending queue/layout change.
      final index = controller.currentIndex;
      final position = _scrollController.position;
      if (index < 0 ||
          !position.hasContentDimensions ||
          !position.hasViewportDimension) {
        return;
      }
      final extent = _itemExtent;
      final offset = index * extent - (position.viewportDimension - extent) / 2;
      _scrollController.jumpTo(
        offset.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _confirmClearQueue() async {
    if (_clearPending || controller.queue.isEmpty) return;
    _cancelDrag();
    setState(() => _clearPending = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('清空播放队列？'),
          content: const Text(
            '将停止播放并移除当前队列中的全部歌曲。曲库和音乐文件会保留。'
            '播完当前曲目的定时将取消，倒计时定时继续。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留队列'),
            ),
            FilledButton(
              key: const Key('confirm-clear-queue'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空并停止'),
            ),
          ],
        ),
      );
      if (mounted && confirmed == true) await controller.clearQueue();
    } finally {
      if (mounted) setState(() => _clearPending = false);
    }
  }

  @override
  void dispose() {
    _queueChanges.dispose();
    _scrollController.dispose();
    _dragOrder = null;
    _reorderable = null;
    // The child sliver disposes its gesture and overlay when this view leaves.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Obx(
        () => Row(
          children: [
            Expanded(
              child: Text(
                '遇到无法播放的文件时跳过',
                style: TextStyle(
                  fontSize: 13,
                  color: HanMusicColors.of(context).muted,
                ),
              ),
            ),
            Switch(
              key: const Key('skip-error-switch'),
              value: controller.skipOnError.value,
              onChanged: (value) => controller.skipOnError.value = value,
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const Key('queue-locate-current'),
              tooltip: '定位当前歌曲',
              onPressed: _clearPending || controller.currentIndex < 0
                  ? null
                  : _locateCurrent,
              icon: const Icon(Icons.my_location_rounded, size: 20),
            ),
            TextButton.icon(
              key: const Key('queue-clear'),
              onPressed: _clearPending || controller.queue.isEmpty
                  ? null
                  : _confirmClearQueue,
              icon: const Icon(Icons.playlist_remove_rounded, size: 20),
              label: Text(_clearPending ? '处理中…' : '清空队列'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: Obx(() {
          final queue = controller.queue.toList();
          final current = controller.currentSong.value?.id;
          if (queue.isEmpty) {
            return Center(
              child: Text(
                '队列还是空的，从曲库选择一首音乐开始。',
                style: TextStyle(color: HanMusicColors.of(context).muted),
              ),
            );
          }
          return ReorderableListView.builder(
            key: const Key('queue-list'),
            scrollController: _scrollController,
            padding: EdgeInsets.zero,
            buildDefaultDragHandles: false,
            itemCount: queue.length,
            itemExtent: _itemExtent,
            onReorderStart: (_) {
              _dragOrder = queue.map((song) => song.id).toList();
              // The handle can still belong to the previous frame. Wait until
              // the framework finishes starting its drag before cancelling it.
              _checkDragSoon();
            },
            onReorder: (oldIndex, newIndex) =>
                _reorderQueue(queue, oldIndex, newIndex),
            itemBuilder: (context, index) {
              _reorderable = SliverReorderableList.of(context);
              final song = queue[index];
              return Container(
                key: ValueKey('queue-song-${song.id}'),
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: song.id == current
                      ? HanMusicColors.of(context).selectedSurface
                      : Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    ReorderableDragStartListener(
                      index: index,
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(
                          Icons.drag_indicator_rounded,
                          color: HanMusicColors.of(context).muted,
                        ),
                      ),
                    ),
                    _SongThumbnail(song: song, size: 36),
                    const SizedBox(width: 10),
                    Expanded(
                      // Paint title feedback above the opaque queue-row fill.
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          onTap: song.isMissing
                              ? null
                              : () => _playSong(song.id),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: song.isMissing
                                      ? HanMusicColors.of(context).muted
                                      : song.id == current
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                              ),
                              Text(
                                song.isMissing
                                    ? '文件缺失'
                                    : song.isOnline
                                    ? '${controller.sourceLabel(song)} · ${song.artist ?? '未知歌手'}'
                                    : song.artist ?? '未知歌手',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: HanMusicColors.of(context).muted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '播放${song.title}',
                      onPressed: song.isMissing
                          ? null
                          : () => _playSong(song.id),
                      icon: const Icon(Icons.play_arrow_rounded, size: 21),
                    ),
                    IconButton(
                      tooltip: '上移',
                      onPressed: index == 0
                          ? null
                          : () => _moveSong(song.id, down: false),
                      icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                    ),
                    IconButton(
                      tooltip: '下移',
                      onPressed: index == queue.length - 1
                          ? null
                          : () => _moveSong(song.id, down: true),
                      icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                    ),
                    IconButton(
                      tooltip: '从队列移除',
                      onPressed: () => controller.removeFromQueue(song.id),
                      icon: const Icon(Icons.close_rounded, size: 19),
                    ),
                    PopupMenuButton<String>(
                      key: ValueKey('queue-actions-${song.id}'),
                      tooltip: '歌曲操作',
                      onSelected: (action) {
                        if (action == 'next') widget.onPlayNext(song);
                        if (action == 'details') {
                          showSongDetails(
                            context,
                            song,
                            sourceName: controller.sourceLabel(song),
                          );
                        }
                        if (action == 'favorite') {
                          controller.toggleFavorite(song);
                        }
                        if (action == 'playlist') widget.onAddToPlaylist(song);
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'next',
                          enabled: controller.isSongAvailable(song),
                          child: const Text('下一首播放'),
                        ),
                        PopupMenuItem(
                          value: 'favorite',
                          child: Text(
                            controller.isFavorite(song) ? '取消喜欢' : '加入我喜欢',
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'playlist',
                          child: Text('添加到歌单'),
                        ),
                        const PopupMenuItem(
                          value: 'details',
                          child: Text('歌曲详情'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        }),
      ),
    ],
  );
}

class _DesktopTransport extends StatelessWidget {
  const _DesktopTransport({required this.controller});
  final PlayerController controller;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(18, 13, 18, 10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(top: BorderSide(color: HanMusicColors.of(context).border)),
    ),
    child: Obx(() {
      final song = controller.currentSong.value;
      final playing = controller.isPlaying.value;
      final loading = controller.isLoading.value;
      final mode = controller.playMode.value;
      final timer = controller.timerRemaining.value;
      final timerMode = controller.timerMode.value;
      final timerActive = controller.timerActive;
      final volume = controller.volume.value;
      final retry = controller.canRetryPlayback;
      final enabled = controller.canPlay && !loading;
      final queueAvailable = controller.queue.isNotEmpty && !loading;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Tooltip(
                message: '歌曲详情',
                child: InkWell(
                  key: const Key('current-song-details'),
                  onTap: song == null
                      ? null
                      : () => showSongDetails(
                          context,
                          song,
                          sourceName: controller.sourceLabel(song),
                        ),
                  child: _SongThumbnail(song: song, size: 42),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song?.title ?? '选择一首音乐开始播放',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      loading
                          ? '正在加载…'
                          : song?.isOnline == true
                          ? '${controller.sourceLabel(song!)} · ${song.artist ?? '未知歌手'}'
                          : song?.artist ??
                                (song == null ? '本地音乐，随时聆听' : '未知歌手'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: HanMusicColors.of(context).muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: const Key('current-favorite'),
                tooltip: song != null && controller.isFavorite(song)
                    ? '取消喜欢'
                    : '加入我喜欢',
                onPressed: song == null
                    ? null
                    : () => controller.toggleFavorite(song),
                icon: Icon(
                  song != null && controller.isFavorite(song)
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: song != null && controller.isFavorite(song)
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  size: 21,
                ),
              ),
              IconButton(
                key: const Key('previous-track'),
                tooltip: '上一首',
                onPressed: queueAvailable ? controller.previous : null,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              IconButton.filled(
                key: const Key('toggle-playback'),
                tooltip: retry
                    ? '重试播放'
                    : playing
                    ? '暂停'
                    : '播放',
                onPressed: retry
                    ? () => controller.retryPlayback(song!.id)
                    : enabled
                    ? controller.togglePlayback
                    : null,
                style: IconButton.styleFrom(minimumSize: const Size.square(46)),
                icon: loading
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 27,
                      ),
              ),
              IconButton(
                key: const Key('next-track'),
                tooltip: '下一首',
                onPressed: queueAvailable ? controller.next : null,
                icon: const Icon(Icons.skip_next_rounded),
              ),
              IconButton(
                key: const Key('play-mode'),
                tooltip: '播放模式：${mode.label}',
                onPressed: controller.cyclePlayMode,
                icon: Icon(switch (mode) {
                  PlayMode.sequential => Icons.arrow_forward_rounded,
                  PlayMode.repeatAll => Icons.repeat_rounded,
                  PlayMode.repeatOne => Icons.repeat_one_rounded,
                  PlayMode.shuffle => Icons.shuffle_rounded,
                }, size: 22),
              ),
              Tooltip(
                message: timerActive ? _sleepTimerSummary(controller) : '睡眠定时',
                child: TextButton.icon(
                  key: const Key('sleep-timer-open'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => _SleepTimerDialog(controller: controller),
                  ),
                  icon: Icon(
                    Icons.bedtime_outlined,
                    color: timerActive
                        ? Theme.of(context).colorScheme.primary
                        : HanMusicColors.of(context).muted,
                    size: 20,
                  ),
                  label: Text(
                    timerMode == SleepTimerMode.endOfTrack
                        ? '本曲结束'
                        : timer == null
                        ? '定时'
                        : _formatTime(timer),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              if (timerActive)
                IconButton(
                  key: const Key('sleep-timer-cancel'),
                  tooltip: '取消定时',
                  onPressed: controller.cancelSleepTimer,
                  icon: const Icon(Icons.timer_off_outlined, size: 20),
                ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: _ProgressSlider(
                  key: ValueKey(song?.id),
                  selectionRevision: controller.selectionRevision,
                  position: controller.position.value,
                  duration: controller.duration.value,
                  enabled: enabled && controller.duration.value > Duration.zero,
                  onSeek: controller.seek,
                ),
              ),
              const SizedBox(width: 14),
              _VolumeButton(controller: controller),
              SizedBox(
                width: 100,
                child: Slider(
                  key: const Key('volume-slider'),
                  value: volume.clamp(0, 1),
                  semanticFormatterCallback: (value) =>
                      '音量 ${(value * 100).round()}%',
                  onChanged: controller.setVolume,
                ),
              ),
            ],
          ),
        ],
      );
    }),
  );
}
