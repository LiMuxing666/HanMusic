part of 'view.dart';

class _HistoryView extends StatefulWidget {
  const _HistoryView({
    required this.controller,
    required this.onAddToPlaylist,
    required this.onShowDetails,
    required this.onPlayNext,
    this.searchKey,
  });

  final PlayerController controller;
  final ValueChanged<Song> onAddToPlaylist;
  final ValueChanged<Song> onShowDetails;
  final ValueChanged<Song> onPlayNext;
  final GlobalKey<MusicSearchFieldState>? searchKey;

  @override
  State<_HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<_HistoryView> {
  String _query = '';
  String? _notice;
  PlayerController get controller => widget.controller;

  Future<void> _clearHistory() async {
    if (!controller.acceptsPlaybackCommands ||
        controller.historyEntries.isEmpty) {
      return;
    }
    final generation = controller.commandGeneration;
    final clear = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空播放历史？'),
        content: const Text('只清除最近播放记录，不影响正在播放的歌曲、曲库、歌单或源文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('history-confirm-clear'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空记录'),
          ),
        ],
      ),
    );
    if (!mounted ||
        clear != true ||
        !controller.acceptsPlaybackCommands ||
        generation != controller.commandGeneration) {
      return;
    }
    controller.clearHistory();
    setState(() => _notice = null);
  }

  void _enqueue(Song song) {
    if (!controller.acceptsPlaybackCommands) return;
    final result = controller.enqueueHistorySong(song);
    setState(() {
      _notice = switch (result) {
        QueueAddResult.added => '已加入播放队列。',
        QueueAddResult.unchanged => '这首歌曲已在播放队列中。',
        QueueAddResult.unavailable => '这首歌曲当前不可用。',
      };
    });
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final all = controller.historyEntries.toList();
    final query = _query.trim().toLowerCase();
    final entries = all.where((entry) {
      final song = entry.song;
      return query.isEmpty ||
          [
            song.title,
            song.artist ?? '',
            song.album ?? '',
          ].any((value) => value.toLowerCase().contains(query));
    }).toList();
    final ready = controller.acceptsPlaybackCommands;
    return CustomScrollView(
      key: const PageStorageKey('history-scroll'),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 20,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '最近播放',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  OutlinedButton.icon(
                    key: const Key('history-clear'),
                    onPressed: ready && all.isNotEmpty ? _clearHistory : null,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: const Text('清空历史'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '实际播放满 10 秒后记录，按最近播放排序，最多保留 200 首。',
                style: TextStyle(
                  color: HanMusicColors.of(context).muted,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 18),
              MusicSearchField(
                key: widget.searchKey,
                inputKey: const ValueKey('history-search'),
                query: _query,
                enabled: ready,
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 12),
              Text(
                query.isEmpty
                    ? '共 ${all.length} 首'
                    : '找到 ${entries.length} 首 · 共 ${all.length} 首',
                style: TextStyle(
                  color: HanMusicColors.of(context).muted,
                  fontSize: 12,
                ),
              ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _notice!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
            ],
          ),
        ),
        if (entries.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Column(
                children: [
                  Icon(
                    Icons.history_rounded,
                    size: 44,
                    color: HanMusicColors.of(context).muted,
                  ),
                  const SizedBox(height: 12),
                  Text(query.isEmpty ? '还没有播放记录' : '没有匹配的播放记录'),
                  const SizedBox(height: 8),
                  Text(
                    query.isEmpty ? '听一首喜欢的歌，稍后就能在这里找到。' : '试试其他歌曲、歌手或专辑名称。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: HanMusicColors.of(context).muted,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) => _HistorySongRow(
              key: ValueKey('history-row-${entries[index].song.id}'),
              controller: controller,
              entry: entries[index],
              onQueue: _enqueue,
              onPlayNext: widget.onPlayNext,
              onAddToPlaylist: widget.onAddToPlaylist,
              onShowDetails: widget.onShowDetails,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  });
}

class _HistorySongRow extends StatelessWidget {
  const _HistorySongRow({
    super.key,
    required this.controller,
    required this.entry,
    required this.onQueue,
    required this.onPlayNext,
    required this.onAddToPlaylist,
    required this.onShowDetails,
  });

  final PlayerController controller;
  final PlayHistoryEntry entry;
  final ValueChanged<Song> onQueue;
  final ValueChanged<Song> onPlayNext;
  final ValueChanged<Song> onAddToPlaylist;
  final ValueChanged<Song> onShowDetails;

  String get _playedAt {
    final time = entry.lastPlayedAt.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}/${two(time.month)}/${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final song = entry.song;
    final available = controller.isHistorySongAvailable(song);
    final ready = controller.acceptsPlaybackCommands;
    final current = controller.currentSong.value?.id == song.id;
    final favorite = controller.isFavorite(song);
    final canPlay = ready && available && !controller.isLoading.value;
    final subtitle = [
      if (song.artist?.trim().isNotEmpty == true) song.artist!.trim(),
      if (song.album?.trim().isNotEmpty == true) song.album!.trim(),
      if (!available) song.isOnline ? '音乐源不可用' : '文件缺失',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: current
            ? HanMusicColors.of(context).selectedSurface
            : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              _SongThumbnail(song: song, size: 40),
              const SizedBox(width: 10),
              Expanded(
                child: InkWell(
                  onTap: canPlay
                      ? () => controller.playHistorySong(song)
                      : null,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: HanMusicColors.of(context).muted,
                              fontSize: 12,
                            ),
                          ),
                        Text(
                          '$_playedAt · 已记录 ${entry.playCount} 次',
                          maxLines: 2,
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
                key: ValueKey('history-play-${song.id}'),
                tooltip: '播放${song.title}',
                onPressed: canPlay
                    ? () => controller.playHistorySong(song)
                    : null,
                icon: const Icon(Icons.play_arrow_rounded),
              ),
              IconButton(
                tooltip: favorite ? '取消收藏' : '收藏歌曲',
                onPressed: ready ? () => controller.toggleFavorite(song) : null,
                color: favorite
                    ? Theme.of(context).colorScheme.primary
                    : HanMusicColors.of(context).muted,
                icon: Icon(
                  favorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_outline_rounded,
                ),
              ),
              PopupMenuButton<String>(
                key: ValueKey('history-menu-${song.id}'),
                tooltip: '${song.title}的历史操作',
                enabled: ready,
                onSelected: (action) {
                  if (!controller.acceptsPlaybackCommands) return;
                  switch (action) {
                    case 'details':
                      onShowDetails(song);
                    case 'next':
                      if (available) onPlayNext(song);
                    case 'queue':
                      if (available) onQueue(song);
                    case 'add':
                      onAddToPlaylist(song);
                    case 'remove':
                      controller.removeHistorySong(song.id);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'details', child: Text('歌曲详情')),
                  PopupMenuItem(
                    value: 'next',
                    enabled: available,
                    child: const Text('下一首播放'),
                  ),
                  PopupMenuItem(
                    value: 'queue',
                    enabled: available,
                    child: const Text('加入播放队列'),
                  ),
                  const PopupMenuItem(value: 'add', child: Text('添加到歌单')),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'remove', child: Text('移除这条记录')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  });
}
