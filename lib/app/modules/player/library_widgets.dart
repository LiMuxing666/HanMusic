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
  PlayerController get controller => widget.controller;
  OnlineMusicController? _online;
  ({String message, bool canOpenQueue})? _queueNotice;

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

  void _selectSection(int section) => setState(() {
    _section = section;
    _queueNotice = null;
  });

  @override
  void initState() {
    super.initState();
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
      },
    },
    child: FocusScope(
      autofocus: true,
      skipTraversal: true,
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, bounds) {
              final compact = bounds.maxWidth < 1100;
              return Row(
                children: [
                  _LibraryNavigation(
                    compact: compact,
                    selected: _section,
                    showOnline: _online != null,
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
                                if (_section != 3)
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
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: _ErrorNotice(
                                      message: error,
                                      onDismiss: controller.dismissError,
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
                                    ),
                                    3 => OnlineMusicPage(
                                      controller: _online!,
                                      searchFieldKey: _onlineSearchKey,
                                    ),
                                    _ => _LibraryView(
                                      controller: controller,
                                      searchFieldKey: _librarySearchKey,
                                      onQueue: _enqueueAndNotify,
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
        color: const Color(0xFFE7F0E2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            onOpenQueue == null
                ? Icons.info_outline_rounded
                : Icons.playlist_add_check_rounded,
            color: _green,
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
                style: const TextStyle(color: _green, fontSize: 13),
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
    required this.compact,
    required this.selected,
    required this.onSelected,
    required this.showOnline,
  });
  final bool compact;
  final bool showOnline;
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
        for (final item in [
          (index: 0, label: '本地曲库', icon: Icons.library_music_outlined),
          (index: 1, label: '正在播放', icon: Icons.album_outlined),
          (index: 2, label: '播放队列', icon: Icons.queue_music_rounded),
          if (showOnline) (index: 3, label: '在线音乐', icon: Icons.cloud_outlined),
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
        const Spacer(),
        const Icon(
          Icons.desktop_windows_outlined,
          color: Color(0xFF92B3A0),
          size: 20,
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
                style: const TextStyle(fontSize: 12, color: _muted),
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
    this.scrollController,
    this.rowDiagnostics,
  });
  final PlayerController controller;
  final GlobalKey<MusicSearchFieldState> searchFieldKey;
  final ValueChanged<Song> onQueue;
  final ScrollController? scrollController;
  final LibraryRowLifecycleDiagnostics? rowDiagnostics;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Obx(
        () => MusicSearchField(
          key: searchFieldKey,
          inputKey: const ValueKey('library-search'),
          query: controller.searchQuery.value,
          onChanged: controller.setSearchQuery,
        ),
      ),
      const SizedBox(height: 10),
      Obx(() {
        final scanning = controller.isScanning.value;
        final refreshing = controller.isRefreshing.value;
        final status = controller.libraryStatus.value;
        if (refreshing) {
          return const Padding(
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
                  style: TextStyle(color: _muted, fontSize: 12),
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
                      style: const TextStyle(color: _muted, fontSize: 12),
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
                  onPlay: () => controller.playLibrarySong(song),
                  onQueue: () => onQueue(song),
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
            color: _green,
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
            style: const TextStyle(color: _muted, fontSize: 13),
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
    required this.onPlay,
    required this.onQueue,
    required this.onRemove,
  });
  final Song song;
  final bool current;
  final bool wide;
  final LibraryRowLifecycleDiagnostics? diagnostics;
  final VoidCallback onPlay;
  final VoidCallback onQueue;
  final VoidCallback onRemove;

  List<PopupMenuEntry<String>> _menuItems() => [
    PopupMenuItem(
      value: 'queue',
      enabled: !song.isMissing,
      child: const Text('加入播放队列'),
    ),
    const PopupMenuItem(value: 'remove', child: Text('从曲库移除（保留文件）')),
  ];

  void _selectMenuAction(String action) {
    if (action == 'queue') {
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
        color: current
            ? const Color(0xFFE7F0E2)
            : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: ValueKey('library-song-${song.id}'),
          borderRadius: BorderRadius.circular(12),
          onTap: song.isMissing ? null : onPlay,
          onSecondaryTapUp: (details) async =>
              _showContextMenu(context, details.globalPosition),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: [
                Opacity(
                  opacity: song.isMissing ? .45 : 1,
                  child: _SongThumbnail(song: song),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 4,
                  child: Opacity(
                    opacity: song.isMissing ? .5 : 1,
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
                            color: current ? _green : null,
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
                          style: const TextStyle(fontSize: 12, color: _muted),
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
                      style: const TextStyle(color: _muted, fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Text(
                      album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _muted, fontSize: 13),
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                Text(
                  song.duration == null ? '--:--' : _formatTime(song.duration!),
                  style: const TextStyle(color: _muted, fontSize: 12),
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
      color: const Color(0xFFE0EAD6),
      child: Icon(Icons.music_note_rounded, color: _green, size: size * .52),
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
  const _QueueView({super.key, required this.controller});
  final PlayerController controller;

  @override
  State<_QueueView> createState() => _QueueViewState();
}

class _QueueViewState extends State<_QueueView> {
  PlayerController get controller => widget.controller;
  late Worker _queueChanges;
  List<String>? _dragOrder;
  SliverReorderableListState? _reorderable;
  bool _queueCheckScheduled = false;
  bool _clearPending = false;

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
            const Expanded(
              child: Text(
                '遇到无法播放的文件时跳过',
                style: TextStyle(fontSize: 13, color: _muted),
              ),
            ),
            Switch(
              key: const Key('skip-error-switch'),
              value: controller.skipOnError.value,
              onChanged: (value) => controller.skipOnError.value = value,
            ),
            const SizedBox(width: 8),
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
            return const Center(
              child: Text(
                '队列还是空的，从曲库选择一首音乐开始。',
                style: TextStyle(color: _muted),
              ),
            );
          }
          final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
          return ReorderableListView.builder(
            key: const Key('queue-list'),
            buildDefaultDragHandles: false,
            itemCount: queue.length,
            itemExtent: 76 + (textScale - 1).clamp(0.0, 4.0) * 32,
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
                      ? const Color(0xFFE7F0E2)
                      : Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(
                          Icons.drag_indicator_rounded,
                          color: _muted,
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
                                      ? _muted
                                      : song.id == current
                                      ? _green
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
                                style: const TextStyle(
                                  color: _muted,
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
      border: const Border(top: BorderSide(color: Color(0xFFDFE6DA))),
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
      final enabled = controller.canPlay && !loading;
      final queueAvailable = controller.queue.isNotEmpty && !loading;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _SongThumbnail(song: song, size: 42),
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
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: const Key('previous-track'),
                tooltip: '上一首',
                onPressed: queueAvailable ? controller.previous : null,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              IconButton.filled(
                key: const Key('toggle-playback'),
                tooltip: playing ? '暂停' : '播放',
                onPressed: enabled ? controller.togglePlayback : null,
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
                    color: timerActive ? _green : _muted,
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
