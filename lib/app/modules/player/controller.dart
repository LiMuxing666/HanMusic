import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../data/models/song.dart';
import '../../data/repositories/local_song_picker.dart';
import '../../services/player_service.dart';
import '../../services/timer_service.dart';

class PlayerController extends GetxController with WidgetsBindingObserver {
  PlayerController({
    required PlayerService player,
    required TimerService timer,
    required SongPicker picker,
  }) : _player = player,
       _timer = timer,
       _picker = picker;

  final PlayerService _player;
  final TimerService _timer;
  final SongPicker _picker;
  final isImporting = false.obs;
  bool _closed = false;

  Rxn<Song> get currentSong => _player.currentSong;
  RxBool get isPlaying => _player.isPlaying;
  RxBool get isLoading => _player.isLoading;
  Rx<Duration> get position => _player.position;
  Rx<Duration> get duration => _player.duration;
  RxDouble get volume => _player.volume;
  RxnString get errorMessage => _player.errorMessage;
  Rxn<Duration> get timerRemaining => _timer.remaining;
  bool get canPlay => _player.canPlay;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    super.onInit();
  }

  Future<void> importFile() async {
    if (_closed || isImporting.value || isLoading.value) return;
    isImporting.value = true;
    try {
      final song = await _picker.pick();
      if (!_closed && song != null) await _player.open(song);
    } catch (_) {
      if (!_closed) errorMessage.value = '无法打开所选文件，请检查文件是否存在及访问权限。';
    } finally {
      if (!_closed) isImporting.value = false;
    }
  }

  Future<void> togglePlayback() => _player.togglePlayback();
  Future<void> seek(Duration value) => _player.seek(value);
  Future<void> setVolume(double value) => _player.setVolume(value);
  void startSleepTimer(Duration value) => _timer.start(value);
  void cancelSleepTimer() => _timer.cancel();
  void dismissError() => errorMessage.value = null;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _timer.checkDeadline();
  }

  @override
  void onClose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }
}
