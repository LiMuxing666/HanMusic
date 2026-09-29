import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'controller.dart';
import '../online/controller.dart';
import '../online/view.dart';
import '../../data/models/song.dart';
import '../../data/models/play_mode.dart';
import '../../data/models/sleep_timer_mode.dart';

part 'library_widgets.dart';

const _muted = Color(0xFF738077);
const _green = Color(0xFF256747);

class PlayerPage extends StatelessWidget {
  const PlayerPage({
    super.key,
    required this.controller,
    this.libraryScrollController,
  });

  final PlayerController controller;
  final ScrollController? libraryScrollController;

  @override
  Widget build(BuildContext context) {
    if (controller.hasLibrary) {
      return _LibraryPlayerPage(
        controller: controller,
        libraryScrollController: libraryScrollController,
      );
    }
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 1050;
            return Row(
              children: [
                _Sidebar(compact: compact),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(compact ? 24 : 36),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1200),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Header(controller: controller),
                            const SizedBox(height: 26),
                            Obx(() {
                              final error = controller.errorMessage.value;
                              if (error == null || error.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 18),
                                child: _ErrorNotice(
                                  message: error,
                                  onDismiss: controller.dismissError,
                                ),
                              );
                            }),
                            _SongCard(controller: controller),
                            const SizedBox(height: 20),
                            _PlaybackCard(controller: controller),
                            const SizedBox(height: 20),
                            _SleepTimerCard(controller: controller),
                            const SizedBox(height: 18),
                            const Text(
                              '音乐在本地，心情在此刻。',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, color: _muted),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: compact ? 76 : 202,
      color: const Color(0xFF193D2E),
      padding: EdgeInsets.symmetric(
        vertical: 30,
        horizontal: compact ? 12 : 22,
      ),
      child: Column(
        crossAxisAlignment: compact
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: compact
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
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
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'HanMusic',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.7,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 48),
          if (!compact) ...[
            const Padding(
              padding: EdgeInsets.only(left: 12),
              child: Text(
                '我的音乐',
                style: TextStyle(color: Color(0xFF92B3A0), fontSize: 12),
              ),
            ),
            const SizedBox(height: 14),
          ],
          Tooltip(
            message: '本地播放',
            child: Semantics(
              selected: true,
              label: '本地播放',
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFF315542),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: compact
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    if (!compact) const SizedBox(width: 13),
                    const Icon(
                      Icons.library_music_outlined,
                      color: Color(0xFFE0F2D8),
                      size: 22,
                    ),
                    if (!compact) ...[
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          '本地播放',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          if (!compact)
            const Padding(
              padding: EdgeInsets.only(left: 12),
              child: Text(
                '留一点时间\n给喜欢的声音。',
                style: TextStyle(
                  color: Color(0xFFA8C3B3),
                  height: 1.8,
                  fontSize: 13,
                ),
              ),
            ),
          const SizedBox(height: 22),
          const Divider(color: Color(0xFF365847)),
          const SizedBox(height: 14),
          Tooltip(
            message: 'Windows 版',
            child: Row(
              mainAxisAlignment: compact
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                if (!compact) const SizedBox(width: 12),
                const Icon(
                  Icons.desktop_windows_outlined,
                  color: Color(0xFF92B3A0),
                  size: 18,
                ),
                if (!compact) ...[
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Windows 版',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Color(0xFF92B3A0), fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('本地播放', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 7),
              const Text('让喜欢的声音，陪你慢下来。', style: TextStyle(color: _muted)),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Obx(() {
          final importing = controller.isImporting.value;
          final loading = controller.isLoading.value;
          return FilledButton.icon(
            key: const Key('import-file'),
            onPressed: importing || loading ? null : controller.importFile,
            icon: importing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded, size: 21),
            label: Text(importing ? '选择中…' : '导入音乐'),
          );
        }),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(26)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: const Color(0xFFE4EAE1)),
        borderRadius: BorderRadius.circular(22),
      ),
      child: child,
    );
  }
}

class _SongCard extends StatelessWidget {
  const _SongCard({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Obx(() {
        final song = controller.currentSong.value;
        final loading = controller.isLoading.value;
        final playing = controller.isPlaying.value;
        final duration = controller.duration.value;
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'NOW PLAYING',
                  style: TextStyle(
                    color: _green,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(width: 12),
                _StatusTag(
                  label: loading
                      ? '准备中'
                      : song == null
                      ? '等待音乐'
                      : playing
                      ? '正在播放'
                      : '已暂停',
                  active: playing,
                ),
              ],
            ),
            const SizedBox(height: 18),
            Tooltip(
              message: song?.title ?? '',
              child: Text(
                song?.title ?? '从一首歌开始',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            const SizedBox(height: 12),
            if (song == null)
              const Text(
                '选择电脑中的音乐文件，\n把此刻交给熟悉的旋律。',
                style: TextStyle(color: _muted, height: 1.8),
              )
            else ...[
              Tooltip(
                message: song.isOnline
                    ? controller.sourceLabel(song)
                    : song.path,
                child: Row(
                  children: [
                    Icon(
                      song.isOnline
                          ? Icons.cloud_outlined
                          : Icons.audio_file_outlined,
                      size: 17,
                      color: _muted,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        song.isOnline ? song.artist ?? '未知歌手' : song.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _muted),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                children: [
                  _DetailLabel(text: controller.sourceLabel(song)),
                  _DetailLabel(
                    text: song.extension.replaceFirst('.', '').toUpperCase(),
                  ),
                  _DetailLabel(
                    text: duration > Duration.zero
                        ? _formatTime(duration)
                        : '读取时长中',
                  ),
                ],
              ),
            ],
            const SizedBox(height: 18),
            if (loading)
              const Row(
                children: [
                  SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 9),
                  Text(
                    '正在准备音乐…',
                    style: TextStyle(fontSize: 12, color: _muted),
                  ),
                ],
              )
            else if (song == null)
              const Text(
                '支持 MP3、FLAC、WAV、M4A、OGG',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
          ],
        );
        return LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 540) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: _MusicArtwork(size: 164)),
                  const SizedBox(height: 24),
                  details,
                ],
              );
            }
            return Row(
              children: [
                const _MusicArtwork(size: 190),
                const SizedBox(width: 30),
                Expanded(child: details),
              ],
            );
          },
        );
      }),
    );
  }
}

class _MusicArtwork extends StatelessWidget {
  const _MusicArtwork({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFDDE9D1), Color(0xFFB8D0AE)],
          ),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: -size * .25,
              right: -size * .24,
              child: _ArtworkRing(
                size: size * 1.1,
                color: Colors.white.withValues(alpha: .22),
              ),
            ),
            Positioned(
              bottom: -size * .34,
              left: -size * .2,
              child: _ArtworkRing(
                size: size * 1.13,
                color: _green.withValues(alpha: .1),
              ),
            ),
            Container(
              width: size * .6,
              height: size * .6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF214C37),
                border: Border.all(color: const Color(0xFF83A27B), width: 7),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF214C37).withValues(alpha: .17),
                    blurRadius: 24,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Icon(
                Icons.music_note_rounded,
                color: const Color(0xFFE0EDCE),
                size: size * .27,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtworkRing extends StatelessWidget {
  const _ArtworkRing({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 20),
    ),
  );
}

class _StatusTag extends StatelessWidget {
  const _StatusTag({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFE6F2DF) : const Color(0xFFF0F3EC),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: active ? _green : _muted),
      ),
    );
  }
}

class _DetailLabel extends StatelessWidget {
  const _DetailLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 12, color: _muted));
}

class _PlaybackCard extends StatelessWidget {
  const _PlaybackCard({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      padding: const EdgeInsets.fromLTRB(24, 15, 24, 20),
      child: Obx(() {
        final song = controller.currentSong.value;
        final playing = controller.isPlaying.value;
        final loading = controller.isLoading.value;
        final importing = controller.isImporting.value;
        final duration = controller.duration.value;
        final position = controller.position.value;
        final volume = controller.volume.value;
        final enabled = controller.canPlay && !loading && !importing;
        return Column(
          children: [
            _ProgressSlider(
              key: ValueKey(song?.id),
              position: position,
              duration: duration,
              enabled: enabled && duration > Duration.zero,
              onSeek: controller.seek,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton.filled(
                  key: const Key('toggle-playback'),
                  tooltip: playing ? '暂停' : '播放',
                  onPressed: enabled ? controller.togglePlayback : null,
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(52),
                    maximumSize: const Size.square(52),
                  ),
                  icon: loading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 29,
                        ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Text(
                    loading
                        ? '正在加载音乐'
                        : song == null
                        ? '导入音乐后开始播放'
                        : playing
                        ? '享受此刻的旋律'
                        : '准备好，继续聆听',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: _muted),
                  ),
                ),
                const SizedBox(width: 12),
                Tooltip(
                  message: '音量 ${(volume * 100).round()}%',
                  child: Icon(
                    volume <= 0
                        ? Icons.volume_off_rounded
                        : volume < .5
                        ? Icons.volume_down_rounded
                        : Icons.volume_up_rounded,
                    size: 22,
                    color: _muted,
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: Slider(
                    key: const Key('volume-slider'),
                    value: volume.clamp(0, 1),
                    semanticFormatterCallback: (value) =>
                        '音量 ${(value * 100).round()}%',
                    label: '${(volume * 100).round()}%',
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
}

class _ProgressSlider extends StatefulWidget {
  const _ProgressSlider({
    super.key,
    required this.position,
    required this.duration,
    required this.enabled,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final bool enabled;
  final Future<void> Function(Duration) onSeek;

  @override
  State<_ProgressSlider> createState() => _ProgressSliderState();
}

class _ProgressSliderState extends State<_ProgressSlider> {
  double? _dragPosition;

  @override
  Widget build(BuildContext context) {
    final maximum = widget.duration.inMilliseconds.toDouble();
    final safeMaximum = maximum > 0 ? maximum : 1.0;
    final value = (_dragPosition ?? widget.position.inMilliseconds.toDouble())
        .clamp(0.0, safeMaximum);
    final displayed = Duration(milliseconds: value.round());
    return Column(
      children: [
        Slider(
          key: const Key('seek-slider'),
          value: value,
          max: safeMaximum,
          label: _formatTime(displayed),
          semanticFormatterCallback: (value) =>
              '播放进度 ${_formatTime(Duration(milliseconds: value.round()))}',
          onChanged: widget.enabled
              ? (value) => setState(() => _dragPosition = value)
              : null,
          onChangeEnd: widget.enabled
              ? (value) {
                  widget.onSeek(Duration(milliseconds: value.round()));
                  setState(() => _dragPosition = null);
                }
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatTime(displayed),
                style: const TextStyle(fontSize: 12, color: _muted),
              ),
              Text(
                _formatTime(widget.duration),
                style: const TextStyle(fontSize: 12, color: _muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SleepTimerCard extends StatelessWidget {
  const _SleepTimerCard({required this.controller});
  final PlayerController controller;

  @override
  Widget build(BuildContext context) => _Panel(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
    child: Obx(() {
      final active = controller.timerActive;
      final mode = controller.timerMode.value;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 43,
                height: 43,
                decoration: BoxDecoration(
                  color: const Color(0xFFECF1E5),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: const Icon(
                  Icons.bedtime_outlined,
                  color: _green,
                  size: 21,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '睡眠定时',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (active) ...[
                          const SizedBox(width: 10),
                          _StatusTag(
                            label: mode == SleepTimerMode.countdown
                                ? '倒计时'
                                : '按曲结束',
                            active: true,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _sleepTimerSummary(controller),
                      style: TextStyle(
                        fontSize: 12,
                        color: active ? _green : _muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 6,
            children: [
              if (controller.canExtendSleepTimer)
                TextButton(
                  key: const Key('sleep-timer-extend'),
                  onPressed: controller.extendSleepTimer,
                  child: const Text('顺延 10 分钟'),
                ),
              if (active)
                TextButton(
                  key: const Key('sleep-timer-cancel'),
                  onPressed: controller.cancelSleepTimer,
                  child: const Text('取消'),
                ),
              OutlinedButton(
                key: const Key('sleep-timer-open'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => _SleepTimerDialog(controller: controller),
                ),
                child: Text(active ? '更换设定' : '设置定时'),
              ),
            ],
          ),
        ],
      );
    }),
  );
}

class _SleepTimerDialog extends StatefulWidget {
  const _SleepTimerDialog({required this.controller});
  final PlayerController controller;
  @override
  State<_SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<_SleepTimerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _minutesController = TextEditingController();
  int? _preset = 30;
  bool _afterCurrent = false;

  @override
  void initState() {
    super.initState();
    _afterCurrent =
        widget.controller.timerMode.value == SleepTimerMode.endOfTrack;
  }

  @override
  void dispose() {
    _minutesController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_afterCurrent) {
      if (!widget.controller.canStopAfterCurrentSong) return;
      widget.controller.startSleepTimerAfterCurrentSong();
    } else {
      if (!(_formKey.currentState?.validate() ?? false)) return;
      final minutes = _preset ?? int.parse(_minutesController.text);
      widget.controller.startSleepTimer(Duration(minutes: minutes));
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('睡眠定时'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Obx(
              () => Text(
                widget.controller.timerActive
                    ? '当前：${_sleepTimerSummary(widget.controller)}'
                    : widget.controller.timerStatusMessage.value ??
                          '设置后自动暂停，保留队列和播放位置。',
                key: const Key('sleep-timer-status'),
                style: const TextStyle(color: _green, fontSize: 13),
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                for (final minutes in [15, 30, 60, 90])
                  ChoiceChip(
                    label: Text('$minutes 分钟'),
                    selected: !_afterCurrent && _preset == minutes,
                    onSelected: (_) => setState(() {
                      _afterCurrent = false;
                      _preset = minutes;
                      _minutesController.clear();
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('sleep-timer-minutes'),
              controller: _minutesController,
              decoration: const InputDecoration(
                labelText: '自定义时长',
                hintText: '输入分钟数',
                suffixText: '分钟',
                helperText: '1–1440 分钟，最多 24 小时',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {
                _afterCurrent = false;
                _preset = null;
              }),
              onFieldSubmitted: (_) => _submit(),
              validator: (value) {
                if (_afterCurrent || _preset != null) return null;
                final minutes = int.tryParse(value ?? '');
                if (minutes == null || minutes < 1 || minutes > 1440) {
                  return '请输入 1–1440 的整数分钟';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            Obx(
              () => ChoiceChip(
                key: const Key('sleep-timer-end-track'),
                label: const Text('播完当前歌曲后停止'),
                selected: _afterCurrent,
                onSelected: widget.controller.canStopAfterCurrentSong
                    ? (_) => setState(() => _afterCurrent = true)
                    : null,
              ),
            ),
            const SizedBox(height: 7),
            Obx(
              () => Text(
                widget.controller.canStopAfterCurrentSong
                    ? '按曲结束绑定当前歌曲，手动切歌会取消；暂停和拖动进度不影响。'
                    : '先选择一首可播放的歌曲，再设置按曲结束。',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '新设定会替换旧任务。退出应用后，定时失效。',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
            Obx(
              () => widget.controller.timerActive
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (widget.controller.canExtendSleepTimer)
                            OutlinedButton(
                              key: const Key('sleep-timer-dialog-extend'),
                              onPressed: widget.controller.extendSleepTimer,
                              child: const Text('顺延 10 分钟'),
                            ),
                          TextButton(
                            key: const Key('sleep-timer-dialog-cancel'),
                            onPressed: () {
                              widget.controller.cancelSleepTimer();
                              Navigator.of(context).pop();
                            },
                            child: const Text('取消定时'),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('暂不设置'),
      ),
      Obx(() {
        final canStopAfterCurrent = widget.controller.canStopAfterCurrentSong;
        return FilledButton(
          key: const Key('sleep-timer-confirm'),
          onPressed: _afterCurrent && !canStopAfterCurrent ? null : _submit,
          child: Text(_afterCurrent ? '确定设置' : '开始计时'),
        );
      }),
    ],
  );
}

String _sleepTimerSummary(
  PlayerController controller,
) => switch (controller.timerMode.value) {
  SleepTimerMode.endOfTrack => '播完当前歌曲后停止',
  SleepTimerMode.countdown =>
    '${_formatTime(controller.timerRemaining.value ?? Duration.zero)} 后停止播放',
  SleepTimerMode.off =>
    controller.timerStatusMessage.value ?? '设定一个时间，让音乐陪你入眠。',
};

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 9, 8, 9),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF0E9),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: const Color(0xFFF1D9CB)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.info_outline_rounded,
              color: Color(0xFF945036),
              size: 21,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Color(0xFF7D4835), fontSize: 13),
              ),
            ),
            IconButton(
              tooltip: '关闭提示',
              onPressed: onDismiss,
              icon: const Icon(
                Icons.close_rounded,
                size: 19,
                color: Color(0xFF945036),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatTime(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 0x7FFFFFFF);
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainder = seconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = remainder.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}
