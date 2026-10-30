import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../core/theme/app_theme.dart';
import '../../data/sources/music_capture.dart';
import '../../services/music_recognition_service.dart';

/// Recognition is a separate, explicitly started action; results never autoplay.
class RecognitionPage extends StatefulWidget {
  const RecognitionPage({
    super.key,
    required this.service,
    this.canOperate,
    this.onSearchLibrary,
    this.onSearchOnline,
  });

  final MusicRecognitionService service;
  final bool Function()? canOperate;
  final ValueChanged<String>? onSearchLibrary;
  final ValueChanged<String>? onSearchOnline;

  @override
  State<RecognitionPage> createState() => _RecognitionPageState();
}

class _RecognitionPageState extends State<RecognitionPage> {
  String? _notice;

  MusicRecognitionService get service => widget.service;
  bool get _canOperate =>
      service.acceptsCommands && (widget.canOperate?.call() ?? true);
  bool get _ready => _canOperate && !service.isBusy;

  void _start() {
    if (!_ready || !service.isAvailable) return;
    FocusScope.of(context).unfocus();
    setState(() => _notice = null);
    unawaited(service.start());
  }

  Future<void> _copyTitle() async {
    final title = service.result.value?.title;
    if (!_ready || title == null) return;
    try {
      await Clipboard.setData(ClipboardData(text: title));
      if (mounted && _ready) setState(() => _notice = '已复制歌名。');
    } catch (_) {
      if (mounted && _ready) {
        setState(() => _notice = '暂时无法复制，请选中歌名后复制。');
      }
    }
  }

  void _search(ValueChanged<String>? callback) {
    final title = service.result.value?.title;
    if (_ready && title != null) callback?.call(title);
  }

  static Future<void> _cancelQuietly(MusicRecognitionService service) async {
    try {
      await service.cancel();
    } catch (_) {
      // The service owns cancellation errors; a disposed page cannot show them.
    }
  }

  @override
  void didUpdateWidget(covariant RecognitionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != service) {
      unawaited(_cancelQuietly(oldWidget.service));
      _notice = null;
    }
  }

  @override
  void dispose() {
    unawaited(_cancelQuietly(service));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final phase = service.phase.value;
    final source = service.source.value;
    final available = service.isAvailable;
    final error = service.errorMessage.value;
    final result = service.result.value;
    final remaining = service.remainingSeconds.value;
    final busy = service.isBusy;
    final ready = _ready;
    final colors = HanMusicColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final retry =
        phase == RecognitionPhase.error || phase == RecognitionPhase.noMatch;
    return SingleChildScrollView(
      key: const Key('recognition-scroll'),
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('听歌识曲', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text('采样 12 秒，识别正在响起的歌曲。', style: TextStyle(color: colors.muted)),
              const SizedBox(height: 20),
              _RecognitionSection(
                title: '声音来源',
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      for (final (value, label, icon) in [
                        (
                          MusicCaptureSource.loopback,
                          '电脑声音',
                          Icons.volume_up_outlined,
                        ),
                        (
                          MusicCaptureSource.microphone,
                          '麦克风',
                          Icons.mic_none_rounded,
                        ),
                      ])
                        ChoiceChip(
                          key: ValueKey('recognition-source-${value.name}'),
                          avatar: Icon(icon, size: 20),
                          label: Text(label),
                          selected: source == value,
                          onSelected: ready
                              ? (_) {
                                  if (_ready) service.setSource(value);
                                }
                              : null,
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    source == MusicCaptureSource.loopback
                        ? '使用 Windows 当前默认输出设备的声音。请先播放想识别的音乐。'
                        : '使用 Windows 当前默认麦克风。请让音乐清晰可闻，并避免说话。',
                    style: TextStyle(color: colors.muted),
                  ),
                ],
              ),
              if (!available)
                const _RecognitionSection(
                  title: '识曲服务暂未开通',
                  children: [
                    Text(
                      '此版本暂不能使用听歌识曲，服务开通后即可直接使用。',
                      key: Key('recognition-unavailable'),
                    ),
                  ],
                ),
              _RecognitionSection(
                title: '开始识别',
                children: [
                  Text(
                    '本次采样的 12 秒音频会通过网络发送至识曲服务，并由 AudD 完成识别。点击“开始识曲”或“再试一次”，表示同意本次采样并上传。',
                    key: const Key('recognition-upload-disclosure'),
                    style: TextStyle(color: scheme.onSurface),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '请只采样你愿意发送的声音。离开此页会取消任务；取消前已发送的音频无法撤回。',
                    style: TextStyle(color: colors.muted),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const Key('recognition-start'),
                        onPressed: ready && available ? _start : null,
                        icon: const Icon(Icons.music_note_rounded),
                        label: Text(retry ? '再试一次' : '开始识曲'),
                      ),
                      if (busy)
                        OutlinedButton(
                          key: const Key('recognition-cancel'),
                          onPressed: phase == RecognitionPhase.cancelling
                              ? null
                              : () => unawaited(service.cancel()),
                          child: const Text('取消本次识别'),
                        ),
                    ],
                  ),
                  if (busy) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(switch (phase) {
                        RecognitionPhase.listening => '正在采样，还剩 $remaining 秒…',
                        RecognitionPhase.recognizing => '正在发送至识曲服务并识别歌曲…',
                        RecognitionPhase.cancelling => '正在取消，请稍候…',
                        _ => '正在准备…',
                      }, key: const Key('recognition-progress-label')),
                    ),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      key: const Key('recognition-progress'),
                      value: phase == RecognitionPhase.listening
                          ? (1 -
                                    remaining /
                                        MusicRecognitionService
                                            .sampleDuration
                                            .inSeconds)
                                .clamp(0.0, 1.0)
                          : null,
                      // Progress-bar semantics require a numeric value. Keep
                      // the default percentage and announce time in the label.
                      semanticsLabel: phase == RecognitionPhase.listening
                          ? '识曲进度，还剩 $remaining 秒'
                          : '识曲进度',
                    ),
                  ],
                ],
              ),
              if (error != null && error.isNotEmpty)
                _RecognitionNotice(
                  message: error,
                  warning: true,
                  valueKey: const Key('recognition-error'),
                ),
              if (phase == RecognitionPhase.noMatch)
                const _RecognitionNotice(
                  message: '没有识别到歌曲。试试更清晰、连续的音乐片段，并确认声音来源正确。',
                  valueKey: Key('recognition-no-match'),
                ),
              if (phase == RecognitionPhase.success && result != null)
                _RecognitionSection(
                  title: '识别结果',
                  children: [
                    _ResultField(
                      label: '歌名',
                      value: result.title,
                      valueKey: const Key('recognition-title'),
                    ),
                    _ResultField(
                      label: '歌手',
                      value: result.artist,
                      valueKey: const Key('recognition-artist'),
                    ),
                    _ResultField(
                      label: '专辑',
                      value: result.album?.trim().isNotEmpty == true
                          ? result.album!
                          : '未提供',
                      valueKey: const Key('recognition-album'),
                    ),
                    _ResultField(
                      label: '发行日期',
                      value: result.releaseDate?.trim().isNotEmpty == true
                          ? result.releaseDate!
                          : '未提供',
                      valueKey: const Key('recognition-date'),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('recognition-copy-title'),
                          onPressed: ready ? _copyTitle : null,
                          icon: const Icon(Icons.copy_outlined),
                          label: const Text('复制歌名'),
                        ),
                        OutlinedButton(
                          key: const Key('recognition-search-library'),
                          onPressed: ready && widget.onSearchLibrary != null
                              ? () => _search(widget.onSearchLibrary)
                              : null,
                          child: const Text('在本地曲库搜索'),
                        ),
                        OutlinedButton(
                          key: const Key('recognition-search-online'),
                          onPressed: ready && widget.onSearchOnline != null
                              ? () => _search(widget.onSearchOnline)
                              : null,
                          child: const Text('在线搜索'),
                        ),
                      ],
                    ),
                  ],
                ),
              if (_notice case final notice?)
                _RecognitionNotice(message: notice),
            ],
          ),
        ),
      ),
    );
  });
}

class _RecognitionSection extends StatelessWidget {
  const _RecognitionSection({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border.all(color: HanMusicColors.of(context).border),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 14),
        ...children,
      ],
    ),
  );
}

class _RecognitionNotice extends StatelessWidget {
  const _RecognitionNotice({
    required this.message,
    this.warning = false,
    this.valueKey,
  });
  final String message;
  final bool warning;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final colors = HanMusicColors.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: warning ? colors.warningSurface : colors.selectedSurface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          message,
          key: valueKey,
          style: TextStyle(
            color: warning
                ? colors.onWarning
                : Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

class _ResultField extends StatelessWidget {
  const _ResultField({
    required this.label,
    required this.value,
    required this.valueKey,
  });
  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) => Padding(
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
        const SizedBox(height: 3),
        SelectableText(value, key: valueKey),
      ],
    ),
  );
}
