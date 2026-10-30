part of 'view.dart';

class _LyricsCard extends StatefulWidget {
  const _LyricsCard({required this.controller});
  final PlayerController controller;

  @override
  State<_LyricsCard> createState() => _LyricsCardState();
}

class _LyricsCardState extends State<_LyricsCard> {
  final _lyrics = LyricsService();
  final _scroll = ScrollController();
  late Worker _songChanges;
  late Worker _positionChanges;
  late Worker _documentChanges;
  Timer? _resumeFollowing;
  int _activeIndex = -1;
  bool _following = true;
  double _lineExtent = 92;
  String? _songId;

  PlayerController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _documentChanges = ever<LyricsDocument?>(_lyrics.document, (_) {
      if (!mounted) return;
      _updatePosition(controller.position.value);
      _scheduleFollow();
    });
    _bindController();
  }

  void _bindController() {
    _songChanges = ever<Song?>(controller.currentSong, (song) {
      // Metadata/availability refreshes do not reload the same song's lyrics.
      if (song?.id != _songId) _selectSong(song);
    });
    _positionChanges = ever<Duration>(controller.position, _updatePosition);
    _selectSong(controller.currentSong.value);
  }

  void _selectSong(Song? song) {
    _songId = song?.id;
    _resumeFollowing?.cancel();
    _following = true;
    _activeIndex = -1;
    unawaited(_lyrics.selectSong(song));
  }

  void _updatePosition(Duration position) {
    if (!mounted) return;
    final next = _lyrics.document.value?.activeIndex(position) ?? -1;
    if (next == _activeIndex) return;
    setState(() => _activeIndex = next);
    _scheduleFollow();
  }

  void _scheduleFollow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_following || !_scroll.hasClients) return;
      final position = _scroll.position;
      final target =
          (_activeIndex < 0
                  ? 0.0
                  : _activeIndex * _lineExtent -
                        (position.viewportDimension - _lineExtent) / 2)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((position.pixels - target).abs() < 1) return;
      unawaited(
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        ),
      );
    });
  }

  void _pauseFollowing() {
    if (_lyrics.document.value?.isTimed != true) return;
    _resumeFollowing?.cancel();
    if (_following) setState(() => _following = false);
    _resumeFollowing = Timer(const Duration(seconds: 8), _followCurrent);
  }

  void _followCurrent() {
    if (!mounted) return;
    _resumeFollowing?.cancel();
    setState(() => _following = true);
    _scheduleFollow();
  }

  @override
  void didUpdateWidget(covariant _LyricsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      _songChanges.dispose();
      _positionChanges.dispose();
      _bindController();
    }
  }

  @override
  void dispose() {
    _resumeFollowing?.cancel();
    _songChanges.dispose();
    _positionChanges.dispose();
    _documentChanges.dispose();
    _lyrics.onClose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Panel(
    padding: const EdgeInsets.all(18),
    child: Obx(() {
      final state = _lyrics.state.value;
      final document = _lyrics.document.value;
      final message = _lyrics.message.value;
      final song = controller.currentSong.value;
      final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
      final extent = 92 + (scale - 1).clamp(0.0, 4.0) * 72;
      if (_lineExtent != extent) {
        _lineExtent = extent;
        _scheduleFollow();
      }
      return Column(
        key: const Key('lyrics-card'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('歌词', style: Theme.of(context).textTheme.titleMedium),
              if (document?.isTimed == true)
                Text(
                  _following ? '自动跟随' : '自动跟随已暂停',
                  key: const Key('lyrics-follow-status'),
                  style: TextStyle(
                    color: HanMusicColors.of(context).muted,
                    fontSize: 12,
                  ),
                ),
              if (document?.isTimed == true)
                TextButton.icon(
                  key: const Key('lyrics-follow-current'),
                  onPressed: _followCurrent,
                  icon: const Icon(Icons.my_location_rounded, size: 18),
                  label: const Text('回到当前行'),
                ),
              IconButton(
                key: const Key('lyrics-reload'),
                tooltip: '重新读取歌词',
                onPressed:
                    song != null &&
                        !song.isOnline &&
                        state != LyricsLoadState.loading
                    ? () => _selectSong(song)
                    : null,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (state == LyricsLoadState.loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (state != LyricsLoadState.ready || document == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                message ?? '暂无歌词。',
                key: const Key('lyrics-message'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: HanMusicColors.of(context).muted,
                  height: 1.5,
                ),
              ),
            )
          else ...[
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  message,
                  key: const Key('lyrics-message'),
                  style: TextStyle(
                    color: HanMusicColors.of(context).muted,
                    fontSize: 12,
                  ),
                ),
              ),
            SizedBox(
              height: 260,
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0 &&
                      (notification is UserScrollNotification ||
                          notification is ScrollStartNotification &&
                              notification.dragDetails != null)) {
                    _pauseFollowing();
                  }
                  return false;
                },
                child: Scrollbar(
                  controller: _scroll,
                  child: ListView.builder(
                    key: const Key('lyrics-list'),
                    controller: _scroll,
                    itemCount: document.isTimed
                        ? document.timedLines.length
                        : document.plainLines.length,
                    itemExtent: _lineExtent,
                    itemBuilder: (context, index) {
                      final line = document.isTimed
                          ? document.timedLines[index].text
                          : document.plainLines[index];
                      final active = document.isTimed && index == _activeIndex;
                      return Semantics(
                        key: ValueKey('lyrics-line-$index'),
                        selected: active,
                        child: Container(
                          key: active ? const Key('lyrics-current-line') : null,
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: active
                                ? HanMusicColors.of(context).selectedSurface
                                : null,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Tooltip(
                            message: line,
                            child: Text(
                              line,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 16,
                                height: 1.4,
                                fontWeight: active
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: active
                                    ? Theme.of(context).colorScheme.primary
                                    : HanMusicColors.of(context).muted,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    }),
  );
}
