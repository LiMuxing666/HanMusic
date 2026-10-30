part of 'view.dart';

class _AddToPlaylistDialog extends StatefulWidget {
  const _AddToPlaylistDialog({required this.controller, required this.song});

  final PlayerController controller;
  final Song song;

  @override
  State<_AddToPlaylistDialog> createState() => _AddToPlaylistDialogState();
}

class _AddToPlaylistDialogState extends State<_AddToPlaylistDialog> {
  String? _error;

  void _add(String id) {
    if (!widget.controller.acceptsPlaybackCommands) return;
    try {
      final result = widget.controller.addSongsToPlaylist(id, [widget.song]);
      final name = widget.controller.playlists.findById(id)?.name ?? '歌单';
      Navigator.of(context).pop(
        result.added > 0
            ? '已添加到“$name”：${widget.song.title}'
            : result.existing > 0
            ? '“$name”中已存在这首歌曲。'
            : '歌曲状态已改变，暂时无法添加。',
      );
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _create() async {
    final id = await showDialog<String>(
      context: context,
      builder: (_) => _PlaylistNameDialog(
        title: '新建歌单',
        initialName: '',
        onSave: (name) => widget.controller.createPlaylist(name).id,
      ),
    );
    if (mounted && id != null) _add(id);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('添加到歌单'),
    content: SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.song.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Obx(() {
              final playlists = widget.controller.playlists.playlists.toList();
              return SizedBox(
                height: 180,
                child: ListView.builder(
                  itemCount: playlists.length,
                  itemBuilder: (_, index) {
                    final playlist = playlists[index];
                    return ListTile(
                      key: ValueKey('choose-playlist-${playlist.id}'),
                      leading: Icon(
                        playlist.id == Playlist.favoritesId
                            ? Icons.favorite_border_rounded
                            : Icons.queue_music_rounded,
                      ),
                      title: Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _add(playlist.id),
                    );
                  },
                ),
              );
            }),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton.icon(
        key: const Key('playlist-create-and-add'),
        onPressed: _create,
        icon: const Icon(Icons.add_rounded),
        label: const Text('新建并加入'),
      ),
    ],
  );
}
