part of 'view.dart';

class _LibraryPlayerPage extends StatefulWidget {
  const _LibraryPlayerPage({required this.controller});
  final PlayerController controller;

  @override
  State<_LibraryPlayerPage> createState() => _LibraryPlayerPageState();
}

class _LibraryPlayerPageState extends State<_LibraryPlayerPage> {
  int _section = 0;
  PlayerController get controller => widget.controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, bounds) {
          final compact = bounds.maxWidth < 1100;
          return Row(
            children: [
              _LibraryNavigation(
                compact: compact,
                selected: _section,
                onSelected: (value) => setState(() => _section = value),
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
                                      _SleepTimerCard(controller: controller),
                                      const SizedBox(height: 20),
                                    ],
                                  ),
                                ),
                                2 => _QueueView(controller: controller),
                                _ => _LibraryView(controller: controller),
                              },
                            ),
                          ],
                        ),
                      ),
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
  );
}

class _LibraryNavigation extends StatelessWidget {
  const _LibraryNavigation({
    required this.compact,
    required this.selected,
    required this.onSelected,
  });
  final bool compact;
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
  const _LibraryView({required this.controller});
  final PlayerController controller;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextFormField(
        key: const Key('library-search'),
        initialValue: controller.searchQuery.value,
        onChanged: controller.setSearchQuery,
        decoration: const InputDecoration(
          hintText: '搜索歌曲、歌手或专辑',
          prefixIcon: Icon(Icons.search_rounded),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 13),
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
          final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
          return ListView.builder(
            key: const Key('library-list'),
            itemCount: songs.length,
            itemExtent: largeText ? 96 : 78,
            padding: const EdgeInsets.only(bottom: 14),
            itemBuilder: (context, index) => _LibrarySongRow(
              song: songs[index],
              current: currentId == songs[index].id,
              onPlay: () => controller.playLibrarySong(songs[index]),
              onQueue: () => controller.addToQueue(songs[index]),
              onRemove: () =>
                  _confirmLibraryRemoval(context, controller, songs[index]),
            ),
          );
        }),
      ),
    ],
  );
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
    required this.song,
    required this.current,
    required this.onPlay,
    required this.onQueue,
    required this.onRemove,
  });
  final Song song;
  final bool current;
  final VoidCallback onPlay;
  final VoidCallback onQueue;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final wide = bounds.maxWidth >= 850;
      final artist = song.artist?.trim().isNotEmpty == true
          ? song.artist!
          : '未知歌手';
      final album = song.album?.trim().isNotEmpty == true
          ? song.album!
          : '未知专辑';
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
                                  : FontWeight.w500,
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
                    song.duration == null
                        ? '--:--'
                        : _formatTime(song.duration!),
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '${song.title}的操作',
                    onSelected: (value) =>
                        value == 'queue' ? onQueue() : onRemove(),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'queue',
                        enabled: !song.isMissing,
                        child: const Text('加入播放队列'),
                      ),
                      const PopupMenuItem(
                        value: 'remove',
                        child: Text('从曲库移除（保留文件）'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
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

class _QueueView extends StatelessWidget {
  const _QueueView({required this.controller});
  final PlayerController controller;

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
          final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
          return ReorderableListView.builder(
            key: const Key('queue-list'),
            buildDefaultDragHandles: false,
            itemCount: queue.length,
            itemExtent: largeText ? 92 : 76,
            onReorder: controller.reorderQueue,
            itemBuilder: (context, index) {
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
                      child: InkWell(
                        onTap: song.isMissing
                            ? null
                            : () => controller.playQueueItem(index),
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
                              song.isMissing ? '文件缺失' : song.artist ?? '未知歌手',
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
                    IconButton(
                      tooltip: '播放${song.title}',
                      onPressed: song.isMissing
                          ? null
                          : () => controller.playQueueItem(index),
                      icon: const Icon(Icons.play_arrow_rounded, size: 21),
                    ),
                    IconButton(
                      tooltip: '上移',
                      onPressed: index == 0
                          ? null
                          : () => controller.reorderQueue(index, index - 1),
                      icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                    ),
                    IconButton(
                      tooltip: '下移',
                      onPressed: index == queue.length - 1
                          ? null
                          : () => controller.reorderQueue(index, index + 2),
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
                  position: controller.position.value,
                  duration: controller.duration.value,
                  enabled: enabled && controller.duration.value > Duration.zero,
                  onSeek: controller.seek,
                ),
              ),
              const SizedBox(width: 14),
              Icon(
                volume <= 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                size: 20,
                color: _muted,
              ),
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
