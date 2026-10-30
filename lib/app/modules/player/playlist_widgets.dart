part of 'view.dart';

class _PlaylistsView extends StatefulWidget {
  const _PlaylistsView({
    required this.controller,
    required this.onQueue,
    required this.onPlayNext,
    required this.onAddToPlaylist,
  });

  final PlayerController controller;
  final ValueChanged<Song> onQueue;
  final ValueChanged<Song> onPlayNext;
  final ValueChanged<Song> onAddToPlaylist;

  @override
  State<_PlaylistsView> createState() => _PlaylistsViewState();
}

class _PlaylistsViewState extends State<_PlaylistsView> {
  String _selectedId = Playlist.favoritesId;
  String? _notice;
  bool _transferBusy = false;
  late final PlaylistTransfer _transfer;

  PlayerController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _transfer = PlaylistTransfer(
      files: Get.isRegistered<PlaylistTransferFiles>()
          ? Get.find<PlaylistTransferFiles>()
          : LocalPlaylistTransferFiles(),
    );
  }

  void _select(String id) => setState(() {
    _selectedId = id;
    _notice = null;
  });

  void _showNotice(String message) {
    if (mounted) setState(() => _notice = message);
  }

  Future<void> _importPlaylist() async {
    if (_transferBusy || !controller.acceptsPlaybackCommands) return;
    final generation = controller.commandGeneration;
    setState(() {
      _transferBusy = true;
      _notice = null;
    });
    bool active() =>
        mounted &&
        _transferBusy &&
        controller.acceptsPlaybackCommands &&
        controller.commandGeneration == generation;
    try {
      final document = await _transfer.importPlaylist(canCommit: active);
      if (!active()) return;
      if (document == null) {
        _showNotice('已取消导入。');
        return;
      }
      final name = PlaylistTransferCodec.uniqueName(
        document.name,
        controller.playlists.playlists.map((playlist) => playlist.name),
      );
      // Parsing and validation are complete. No await may separate this final
      // exit-generation check from the two synchronous controller mutations.
      final created = controller.createPlaylist(name);
      final added = controller.addSongsToPlaylist(
        created.id,
        document.songs,
        preserveUnknown: true,
      );
      if (added.added != document.songs.length) {
        controller.deletePlaylist(created.id);
        throw const FormatException('歌单导入未完成，请稍后重试。');
      }
      setState(() {
        _selectedId = created.id;
        _notice = '已导入“$name”，共 ${document.songs.length} 首。原文件和播放队列未改变。';
      });
    } on FormatException catch (error) {
      if (active()) _showNotice(error.message);
    } on TimeoutException {
      if (active()) _showNotice('读取歌单超时，未导入任何内容，请重试。');
    } on FileSystemException {
      if (active()) _showNotice('无法读取歌单文件，请检查文件位置及访问权限。');
    } catch (_) {
      if (active()) _showNotice('暂时无法导入歌单，请稍后重试。');
    } finally {
      if (mounted) setState(() => _transferBusy = false);
    }
  }

  Future<void> _exportPlaylist(Playlist playlist) async {
    if (_transferBusy || !controller.acceptsPlaybackCommands) return;
    final generation = controller.commandGeneration;
    final songs = controller.playlistSongs(playlist.id);
    setState(() {
      _transferBusy = true;
      _notice = null;
    });
    bool active() =>
        mounted &&
        _transferBusy &&
        controller.acceptsPlaybackCommands &&
        controller.commandGeneration == generation;
    try {
      final saved = await _transfer.exportPlaylist(
        name: playlist.name,
        songs: songs,
        canCommit: active,
      );
      if (active()) _showNotice(saved == null ? '已取消导出。' : '已导出到：$saved');
    } on FormatException catch (error) {
      if (active()) _showNotice(error.message);
    } on TimeoutException {
      if (active()) _showNotice('写入歌单超时，未完成导出，请选择可用的文件夹重试。');
    } on FileSystemException {
      if (active()) _showNotice('无法写入歌单文件，请检查所选文件夹的访问权限。');
    } catch (_) {
      if (active()) _showNotice('暂时无法导出歌单，请稍后重试。');
    } finally {
      if (mounted) setState(() => _transferBusy = false);
    }
  }

  Future<void> _editName({Playlist? playlist}) async {
    final createdId = await showDialog<String>(
      context: context,
      builder: (_) => _PlaylistNameDialog(
        title: playlist == null ? '新建歌单' : '重命名歌单',
        initialName: playlist?.name ?? '',
        onSave: (name) {
          if (playlist == null) return controller.createPlaylist(name).id;
          controller.renamePlaylist(playlist.id, name);
          return playlist.id;
        },
      ),
    );
    if (mounted && createdId != null) _select(createdId);
  }

  Future<void> _delete(Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除歌单？'),
        content: SingleChildScrollView(
          child: Text('删除“${playlist.name}”后，歌曲仍保留在曲库和原文件中，播放队列也会保留。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('playlist-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除歌单'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    controller.deletePlaylist(playlist.id);
    if (controller.playlists.findById(playlist.id) == null) {
      _select(Playlist.favoritesId);
    }
  }

  void _enqueueAll(String id) {
    final result = controller.enqueuePlaylist(id);
    _showNotice(
      '已加入 ${result.added} 首，已在队列 ${result.existing} 首'
      '${result.unavailable > 0 ? '，跳过不可用 ${result.unavailable} 首' : ''}。',
    );
  }

  void _moveSong(String playlistId, String songId, {required bool down}) {
    // Menus may remain open while the playlist changes; resolve by identity.
    final songs = controller.playlistSongs(playlistId);
    final index = songs.indexWhere((song) => song.id == songId);
    if (index < 0 || (down ? index == songs.length - 1 : index == 0)) return;
    controller.reorderPlaylistSongs(
      playlistId,
      index,
      down ? index + 2 : index - 1,
    );
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final playlists = controller.playlists.playlists.toList(growable: false);
    final selected =
        controller.playlists.findById(_selectedId) ??
        controller.playlists.findById(Playlist.favoritesId);
    final songs = selected == null
        ? <Song>[]
        : controller.playlistSongs(selected.id);
    final playable = songs.where(controller.isSongAvailable).length;
    final ready = controller.acceptsPlaybackCommands && !_transferBusy;
    final loading = controller.isLoading.value;
    Map<String, int>? songIndexes;
    return CustomScrollView(
      key: PageStorageKey('playlist-scroll-${selected?.id ?? _selectedId}'),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('我的歌单', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 6),
              Text(
                '收藏喜欢的歌曲，也为不同心情整理一份歌单。',
                style: TextStyle(
                  color: HanMusicColors.of(context).muted,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
              PopupMenuButton<String>(
                key: const Key('playlist-select'),
                enabled: ready,
                tooltip: '选择歌单',
                initialValue: selected?.id,
                onSelected: _select,
                itemBuilder: (_) => [
                  for (final playlist in playlists)
                    PopupMenuItem(
                      value: playlist.id,
                      child: Row(
                        children: [
                          Icon(
                            playlist.id == selected?.id
                                ? Icons.check_rounded
                                : playlist.isFavorites
                                ? Icons.favorite_outline_rounded
                                : Icons.queue_music_rounded,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              playlist.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: HanMusicColors.of(context).border,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          selected?.isFavorites == true
                              ? Icons.favorite_rounded
                              : Icons.queue_music_rounded,
                          size: 22,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Tooltip(
                            message: selected?.name ?? Playlist.favoritesName,
                            child: Text(
                              selected?.name ?? Playlist.favoritesName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down_rounded),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton.icon(
                    key: const Key('playlist-create'),
                    onPressed: ready ? () => _editName() : null,
                    icon: const Icon(Icons.add_rounded, size: 20),
                    label: const Text('新建歌单'),
                  ),
                  TextButton.icon(
                    key: const Key('playlist-rename'),
                    onPressed:
                        ready && selected != null && !selected.isFavorites
                        ? () => _editName(playlist: selected)
                        : null,
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    label: const Text('重命名'),
                  ),
                  TextButton.icon(
                    key: const Key('playlist-delete'),
                    onPressed:
                        ready && selected != null && !selected.isFavorites
                        ? () => _delete(selected)
                        : null,
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                    label: const Text('删除'),
                  ),
                  TextButton.icon(
                    key: const Key('playlist-import'),
                    onPressed: ready ? _importPlaylist : null,
                    icon: const Icon(Icons.file_open_outlined, size: 20),
                    label: const Text('导入歌单'),
                  ),
                  TextButton.icon(
                    key: const Key('playlist-export'),
                    onPressed: ready && selected != null
                        ? () => _exportPlaylist(selected)
                        : null,
                    icon: const Icon(Icons.file_download_outlined, size: 20),
                    label: const Text('导出当前歌单'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '导出文件：${PlaylistTransferCodec.suggestedFileName(selected?.name ?? Playlist.favoritesName)}\n'
                '选择导出文件夹保存 JSON；同名文件自动编号。只记录路径、在线标识与歌曲信息，不复制音频和封面缓存。',
                key: const Key('playlist-transfer-help'),
                style: TextStyle(
                  color: HanMusicColors.of(context).muted,
                  fontSize: 12,
                ),
              ),
              if (_transferBusy) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(
                  key: Key('playlist-transfer-busy'),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.tonalIcon(
                    key: const Key('playlist-play-all'),
                    onPressed: ready && playable > 0 && !loading
                        ? () => controller.playPlaylist(selected!.id)
                        : null,
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: const Text('播放歌单'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('playlist-enqueue-all'),
                    onPressed: ready && playable > 0
                        ? () => _enqueueAll(selected!.id)
                        : null,
                    icon: const Icon(Icons.playlist_add_rounded, size: 20),
                    label: const Text('全部入队'),
                  ),
                  Text(
                    '共 ${songs.length} 首 · 可播放 $playable 首',
                    style: TextStyle(
                      color: HanMusicColors.of(context).muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              if (_notice case final notice?) ...[
                const SizedBox(height: 10),
                Semantics(
                  liveRegion: true,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          notice,
                          key: const Key('playlist-notice'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭提示',
                        onPressed: () => setState(() => _notice = null),
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
        if (songs.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 28, horizontal: 12),
              child: Column(
                children: [
                  Icon(
                    Icons.library_music_outlined,
                    color: HanMusicColors.of(context).muted,
                    size: 42,
                  ),
                  SizedBox(height: 12),
                  Text('歌单里还没有歌曲', textAlign: TextAlign.center),
                  SizedBox(height: 8),
                  Text(
                    '从本地曲库或在线歌曲的操作菜单中选择“添加到歌单”，也可以点击爱心收藏歌曲。',
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
            itemCount: songs.length,
            findChildIndexCallback: (key) {
              if (key is! ValueKey<String>) return null;
              final indexes = songIndexes ??= {
                for (var index = 0; index < songs.length; index++)
                  '${selected!.id}-${songs[index].id}': index,
              };
              return indexes[key.value];
            },
            itemBuilder: (context, index) => _PlaylistSongRow(
              key: ValueKey('${selected!.id}-${songs[index].id}'),
              controller: controller,
              song: songs[index],
              playlistId: selected.id,
              first: index == 0,
              last: index == songs.length - 1,
              enabled: !_transferBusy,
              onQueue: widget.onQueue,
              onPlayNext: widget.onPlayNext,
              onAddToPlaylist: widget.onAddToPlaylist,
              onMove: (down) =>
                  _moveSong(selected.id, songs[index].id, down: down),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  });
}

class _PlaylistSongRow extends StatelessWidget {
  const _PlaylistSongRow({
    super.key,
    required this.controller,
    required this.song,
    required this.playlistId,
    required this.first,
    required this.last,
    this.enabled = true,
    required this.onQueue,
    required this.onPlayNext,
    required this.onAddToPlaylist,
    required this.onMove,
  });

  final PlayerController controller;
  final Song song;
  final String playlistId;
  final bool first;
  final bool last;
  final bool enabled;
  final ValueChanged<Song> onQueue;
  final ValueChanged<Song> onPlayNext;
  final ValueChanged<Song> onAddToPlaylist;
  final ValueChanged<bool> onMove;

  void _selectAction(BuildContext context, String action) {
    if (!enabled || !controller.acceptsPlaybackCommands) return;
    switch (action) {
      case 'details':
        showSongDetails(
          context,
          song,
          sourceName: controller.sourceLabel(song),
        );
      case 'next':
        if (controller.isSongAvailable(song)) onPlayNext(song);
      case 'queue':
        if (controller.isSongAvailable(song)) onQueue(song);
      case 'add':
        onAddToPlaylist(song);
      case 'up':
        onMove(false);
      case 'down':
        onMove(true);
      case 'remove':
        controller.removePlaylistSong(playlistId, song.id);
    }
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final available = controller.isSongAvailable(song);
    final favorite = controller.isFavorite(song);
    final current = controller.currentSong.value?.id == song.id;
    final ready = enabled && controller.acceptsPlaybackCommands;
    final artist = song.artist?.trim();
    final album = song.album?.trim();
    final subtitle = [
      artist == null || artist.isEmpty ? '未知歌手' : artist,
      album == null || album.isEmpty ? '未知专辑' : album,
      if (!available) song.isOnline ? '音乐源不可用' : '文件缺失',
    ].join(' · ');
    return Padding(
      key: ValueKey('playlist-row-${song.id}'),
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
                child: Tooltip(
                  message: '${song.title}\n$subtitle',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: ready && available && !controller.isLoading.value
                        ? () => controller.playPlaylist(
                            playlistId,
                            startSongId: song.id,
                          )
                        : null,
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
                            style: TextStyle(
                              color: available
                                  ? null
                                  : HanMusicColors.of(context).muted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
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
              ),
              IconButton(
                key: ValueKey('playlist-play-${song.id}'),
                tooltip: '播放${song.title}',
                onPressed: ready && available && !controller.isLoading.value
                    ? () => controller.playPlaylist(
                        playlistId,
                        startSongId: song.id,
                      )
                    : null,
                icon: const Icon(Icons.play_arrow_rounded, size: 24),
              ),
              IconButton(
                key: ValueKey('favorite-${song.id}'),
                tooltip: favorite ? '取消收藏' : '收藏歌曲',
                onPressed: ready ? () => controller.toggleFavorite(song) : null,
                color: favorite
                    ? Theme.of(context).colorScheme.primary
                    : HanMusicColors.of(context).muted,
                icon: Icon(
                  favorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_outline_rounded,
                  size: 22,
                ),
              ),
              PopupMenuButton<String>(
                key: ValueKey('playlist-menu-${song.id}'),
                tooltip: '${song.title}的歌单操作',
                enabled: ready,
                onSelected: (action) => _selectAction(context, action),
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
                  PopupMenuItem(
                    key: ValueKey('playlist-up-${song.id}'),
                    value: 'up',
                    enabled: !first,
                    child: const Text('上移'),
                  ),
                  PopupMenuItem(
                    key: ValueKey('playlist-down-${song.id}'),
                    value: 'down',
                    enabled: !last,
                    child: const Text('下移'),
                  ),
                  PopupMenuItem(
                    key: ValueKey('playlist-remove-${song.id}'),
                    value: 'remove',
                    child: const Text('从此歌单移除'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  });
}

class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({
    required this.title,
    required this.initialName,
    required this.onSave,
  });

  final String title;
  final String initialName;
  final String Function(String name) onSave;

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final TextEditingController _name;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _name.text.length,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final name = Playlist.validateName(_name.text);
      final id = widget.onSave(name);
      Navigator.of(context).pop(id);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: SizedBox(
        width: 360,
        child: TextField(
          key: const Key('playlist-name'),
          controller: _name,
          autofocus: true,
          maxLines: 1,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _save(),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: InputDecoration(
            labelText: '歌单名称',
            helperText: '1–100 个字符',
            errorText: _error,
            errorMaxLines: 3,
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('playlist-name-confirm'),
        onPressed: _save,
        child: const Text('保存'),
      ),
    ],
  );
}
