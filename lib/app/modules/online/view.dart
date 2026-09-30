import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../data/models/online_source_config.dart';
import '../../data/models/song.dart';
import 'controller.dart';

const _green = Color(0xFF256747);
const _muted = Color(0xFF738077);

class OnlineMusicPage extends StatelessWidget {
  const OnlineMusicPage({super.key, required this.controller});
  final OnlineMusicController controller;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      // Controls and notices can exceed the space above the fixed transport at
      // large text sizes. Keep them in the same scrollable as the lazy results.
      SliverToBoxAdapter(child: _buildControls(context)),
      Obx(_buildResults),
    ],
  );

  Widget _buildControls(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('在线音乐', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 5),
                const Text(
                  '从你选择的音乐源，发现喜欢的声音。',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            key: const Key('online-add-source'),
            onPressed: () => _editSource(context, controller),
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('添加音乐源'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Obx(
        () => Row(
          children: [
            Expanded(
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: '音乐源',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 4,
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    key: const Key('online-source-picker'),
                    value:
                        controller.service.sources.any(
                          (source) =>
                              source.id ==
                              controller.service.selectedSourceId.value,
                        )
                        ? controller.service.selectedSourceId.value
                        : null,
                    isExpanded: true,
                    hint: const Text('选择音乐源'),
                    items: controller.service.sources
                        .map(
                          (source) => DropdownMenuItem(
                            value: source.id,
                            child: Text(
                              source.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: controller.service.isTesting.value
                        ? null
                        : controller.selectSource,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              key: const Key('online-source-actions'),
              tooltip: '音乐源操作',
              enabled:
                  controller.service.selectedSource != null &&
                  !controller.service.isTesting.value,
              onSelected: (action) {
                final source = controller.service.selectedSource;
                if (source == null) return;
                if (action == 'edit') {
                  _editSource(context, controller, source: source);
                }
                if (action == 'test') _testSource(context, controller, source);
                if (action == 'remove') {
                  _removeSource(context, controller, source);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'test', child: Text('测试连接')),
                PopupMenuItem(value: 'edit', child: Text('编辑音乐源')),
                PopupMenuItem(value: 'remove', child: Text('删除音乐源')),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Obx(
        () => Row(
          children: [
            Expanded(
              child: TextFormField(
                key: const Key('online-query'),
                initialValue: controller.service.query.value,
                enabled: controller.service.selectedSource != null,
                onChanged: controller.setQuery,
                onFieldSubmitted: (_) => controller.searchNow(),
                decoration: const InputDecoration(
                  hintText: '搜索歌曲、歌手或专辑',
                  prefixIcon: Icon(Icons.search_rounded),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              key: const Key('online-search'),
              onPressed:
                  controller.service.selectedSource == null ||
                      controller.service.isSearching.value
                  ? null
                  : controller.searchNow,
              child: const Text('搜索'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      Obx(() {
        final status = controller.service.statusMessage.value;
        if (status == null || controller.service.errorMessage.value != null) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            status,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        );
      }),
      Obx(() {
        final error = controller.service.errorMessage.value;
        if (error == null || error.isEmpty) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF0E9),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 20,
                color: Color(0xFF945036),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  error,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF7D4835),
                  ),
                ),
              ),
              TextButton(
                onPressed: controller.service.selectedSource == null
                    ? null
                    : controller.searchNow,
                child: const Text('重试'),
              ),
            ],
          ),
        );
      }),
    ],
  );

  Widget _buildResults() {
    final service = controller.service;
    final results = service.results.toList();
    final selected = service.selectedSource;
    final opening = controller.isOpening.value;
    final loadingMore = service.isLoadingMore.value;
    final hasMore = service.hasMore.value;
    if (selected == null) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: _OnlineEmpty(
          icon: Icons.cloud_outlined,
          title: '连接你的音乐世界',
          message: '添加一个音乐源，即可搜索并播放在线音乐。',
        ),
      );
    }
    if (service.isSearching.value && results.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 15),
              Text('正在搜索…', style: TextStyle(color: _muted)),
            ],
          ),
        ),
      );
    }
    if (results.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _OnlineEmpty(
          icon: service.query.value.trim().isEmpty
              ? Icons.travel_explore_rounded
              : Icons.search_off_rounded,
          title: service.query.value.trim().isEmpty
              ? '下一首喜欢的歌，就在这里'
              : service.errorMessage.value == null
              ? '没有找到匹配的音乐'
              : '暂时无法获取音乐',
          message: service.query.value.trim().isEmpty
              ? '输入关键词开始搜索。'
              : '换个关键词，或检查音乐源后重试。',
        ),
      );
    }
    return SliverMainAxisGroup(
      slivers: [
        if (service.isSearching.value)
          const SliverToBoxAdapter(
            child: LinearProgressIndicator(minHeight: 2),
          ),
        SliverList.builder(
          key: const Key('online-results'),
          itemCount: results.length + 1,
          itemBuilder: (context, index) {
            if (index == results.length) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: loadingMore
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : hasMore
                      ? OutlinedButton(
                          key: const Key('online-load-more'),
                          onPressed: service.isSearching.value
                              ? null
                              : controller.loadMore,
                          child: const Text('加载更多'),
                        )
                      : const Text(
                          '已经到底了',
                          style: TextStyle(color: _muted, fontSize: 12),
                        ),
                ),
              );
            }
            final song = results[index];
            return _OnlineSongRow(
              song: song,
              sourceName: selected.name,
              onPlay: opening ? null : () => controller.play(song),
              onQueue: () => controller.enqueue(song),
            );
          },
        ),
      ],
    );
  }
}

class _OnlineSongRow extends StatelessWidget {
  const _OnlineSongRow({
    required this.song,
    required this.sourceName,
    required this.onPlay,
    required this.onQueue,
  });
  final Song song;
  final String sourceName;
  final VoidCallback? onPlay;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 6),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('online-song-${song.id}'),
        onTap: onPlay,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0EAD6),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.music_note_rounded, color: _green),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$sourceName · ${song.artist ?? "未知歌手"} · ${song.album ?? "未知专辑"}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                song.duration == null ? '--:--' : _durationText(song.duration!),
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
              IconButton(
                tooltip: '播放${song.title}',
                onPressed: onPlay,
                icon: const Icon(Icons.play_arrow_rounded, size: 23),
              ),
              IconButton(
                tooltip: '加入播放队列',
                onPressed: onQueue,
                icon: const Icon(Icons.playlist_add_rounded, size: 23),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _OnlineEmpty extends StatelessWidget {
  const _OnlineEmpty({
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: _green, size: 42),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 13),
          ),
        ],
      ),
    ),
  );
}

Future<void> _editSource(
  BuildContext context,
  OnlineMusicController controller, {
  OnlineSourceConfig? source,
}) {
  controller.clearActionError();
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SourceEditor(controller: controller, source: source),
  );
}

class _SourceEditor extends StatefulWidget {
  const _SourceEditor({required this.controller, this.source});
  final OnlineMusicController controller;
  final OnlineSourceConfig? source;
  @override
  State<_SourceEditor> createState() => _SourceEditorState();
}

class _SourceEditorState extends State<_SourceEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _json;
  late final TextEditingController _query;
  @override
  void initState() {
    super.initState();
    _json = TextEditingController(
      text: widget.controller.sourceJson(widget.source),
    );
    _query = TextEditingController(
      text: widget.controller.service.query.value.trim().isEmpty
          ? 'test'
          : widget.controller.service.query.value,
    );
  }

  @override
  void dispose() {
    _json.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final route = ModalRoute.of(context);
    final saved = await widget.controller.saveSource(
      _json.text,
      _query.text,
      originalId: widget.source?.id,
    );
    if (mounted &&
        saved &&
        !widget.controller.service.isExitPending &&
        route?.isCurrent == true) {
      Navigator.of(context).pop();
    }
    // A late save under the exit confirmation must leave that decision intact.
    // Keep this editor mounted too: the framework's pending exit request can
    // still hold its lifecycle observers. After canceling exit it can be closed
    // normally, with the successfully saved configuration retained.
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.source == null ? '添加音乐源' : '编辑音乐源'),
    scrollable: true,
    content: SizedBox(
      width: 590,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '配置提供 JSON 接口的 HTTP(S) 音乐源。目前仅支持无需登录的源，不支持凭据或自定义请求 Header。',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
            const SizedBox(height: 14),
            Obx(
              () => TextFormField(
                key: const Key('online-source-json'),
                controller: _json,
                readOnly: widget.controller.isSaving.value,
                minLines: 7,
                maxLines: 12,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: '高级配置 JSON',
                  alignLabelWithHint: true,
                ),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '请填写音乐源配置' : null,
              ),
            ),
            const SizedBox(height: 14),
            Obx(
              () => TextFormField(
                key: const Key('online-test-query'),
                controller: _query,
                readOnly: widget.controller.isSaving.value,
                decoration: const InputDecoration(
                  labelText: '测试关键词',
                  helperText: '保存前会用此关键词测试连接，成功后才保存。',
                  helperMaxLines: 2,
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? '请填写明确的测试关键词'
                    : null,
              ),
            ),
            Obx(() {
              final error = widget.controller.actionError.value;
              return error == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error,
                        key: const Key('online-source-error'),
                        style: const TextStyle(
                          color: Color(0xFF945036),
                          fontSize: 12,
                        ),
                      ),
                    );
            }),
          ],
        ),
      ),
    ),
    actions: [
      Obx(
        () => TextButton(
          onPressed: widget.controller.isSaving.value
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ),
      Obx(
        () => FilledButton(
          key: const Key('online-source-save'),
          onPressed: widget.controller.isSaving.value ? null : _save,
          child: Text(widget.controller.isSaving.value ? '正在测试并保存…' : '测试并保存'),
        ),
      ),
    ],
  );
}

Future<void> _testSource(
  BuildContext context,
  OnlineMusicController controller,
  OnlineSourceConfig source,
) {
  controller.clearActionError();
  return showDialog<void>(
    context: context,
    builder: (_) => _ConnectionTest(controller: controller, source: source),
  );
}

class _ConnectionTest extends StatefulWidget {
  const _ConnectionTest({required this.controller, required this.source});
  final OnlineMusicController controller;
  final OnlineSourceConfig source;
  @override
  State<_ConnectionTest> createState() => _ConnectionTestState();
}

class _ConnectionTestState extends State<_ConnectionTest> {
  final _form = GlobalKey<FormState>();
  final _query = TextEditingController(text: 'test');
  bool _testing = false;
  bool _succeeded = false;
  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _testing = true;
      _succeeded = false;
    });
    final ok = await widget.controller.testConnection(
      widget.source.id,
      _query.text,
    );
    if (mounted) {
      setState(() {
        _testing = false;
        _succeeded = ok;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('测试连接'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '音乐源：${widget.source.name}',
              style: const TextStyle(color: _muted),
            ),
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('online-test-query'),
              controller: _query,
              decoration: const InputDecoration(
                labelText: '测试关键词',
                helperText: '只向当前音乐源发送此关键词。',
              ),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请填写明确的测试关键词' : null,
            ),
            if (_succeeded)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  widget.controller.service.statusMessage.value ?? '连接成功',
                  style: const TextStyle(color: _green),
                ),
              ),
            Obx(
              () => widget.controller.actionError.value == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        widget.controller.actionError.value!,
                        style: const TextStyle(
                          color: Color(0xFF945036),
                          fontSize: 12,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _testing ? null : () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      FilledButton(
        key: const Key('online-test-connection'),
        onPressed: _testing ? null : _test,
        child: Text(_testing ? '正在测试…' : '开始测试'),
      ),
    ],
  );
}

Future<void> _removeSource(
  BuildContext context,
  OnlineMusicController controller,
  OnlineSourceConfig source,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除音乐源？'),
      content: Text('删除“${source.name}”的配置后，将无法继续从该源搜索或获取播放地址。本地音乐文件会保留。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('保留'),
        ),
        FilledButton(
          key: const Key('online-source-delete'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed == true) await controller.removeSource(source.id);
}

String _durationText(Duration duration) {
  final seconds = duration.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
