part of 'view.dart';

Future<void> showSongDetails(
  BuildContext context,
  Song song, {
  String? sourceName,
}) => showDialog<void>(
  context: context,
  builder: (_) => _SongDetailsDialog(song: song, sourceName: sourceName),
);

class _SongDetailsDialog extends StatefulWidget {
  const _SongDetailsDialog({required this.song, this.sourceName});
  final Song song;
  final String? sourceName;

  @override
  State<_SongDetailsDialog> createState() => _SongDetailsDialogState();
}

class _SongDetailsDialogState extends State<_SongDetailsDialog> {
  final _files = SongFileActions();
  late final Future<SongFileInfo?> _info;
  String? _message;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _info = _files.inspect(widget.song);
  }

  Future<void> _reveal() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await _files.reveal(widget.song);
    } catch (_) {
      if (mounted) setState(() => _message = '无法打开文件位置，请检查文件是否存在及访问权限。');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(
        ClipboardData(
          text: widget.song.isOnline ? widget.song.id : widget.song.path,
        ),
      );
      if (mounted) setState(() => _message = '已复制。');
    } catch (_) {
      if (mounted) setState(() => _message = '无法访问剪贴板，请稍后重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    String value(String? text, String fallback) =>
        text?.trim().isNotEmpty == true ? text!.trim() : fallback;
    Widget field(String label, String content) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: HanMusicColors.of(context).muted,
              fontSize: 12,
            ),
          ),
          SelectableText(content),
        ],
      ),
    );
    return AlertDialog(
      title: const Text('歌曲详情'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              field('歌曲', song.title),
              field('歌手', value(song.artist, '未知歌手')),
              field('专辑', value(song.album, '未知专辑')),
              field(
                '时长',
                song.duration == null ? '未知' : _formatTime(song.duration!),
              ),
              field(
                '格式 / 来源',
                song.isOnline ? widget.sourceName ?? '在线音乐' : song.extension,
              ),
              if (song.isOnline) ...[
                field('音乐源标识', song.sourceId!),
                field('歌曲标识', song.trackId!),
              ] else ...[
                field('文件路径', song.path),
                FutureBuilder<SongFileInfo?>(
                  future: _info,
                  builder: (_, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Text('正在检查文件…');
                    }
                    if (snapshot.hasError || snapshot.data?.exists != true) {
                      return field('文件状态', '文件缺失或无法访问');
                    }
                    final bytes = snapshot.data!.bytes!;
                    final size = bytes < 1024 * 1024
                        ? '${(bytes / 1024).toStringAsFixed(1)} KB'
                        : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
                    return field('文件大小', '$size（$bytes 字节）');
                  },
                ),
              ],
              if (_message != null)
                Text(
                  _message!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('song-details-copy'),
          onPressed: _copy,
          child: Text(song.isOnline ? '复制歌曲标识' : '复制文件路径'),
        ),
        if (!song.isOnline && _files.isWindows)
          TextButton(
            key: const Key('song-details-reveal'),
            onPressed: _opening ? null : _reveal,
            child: const Text('打开文件位置'),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
