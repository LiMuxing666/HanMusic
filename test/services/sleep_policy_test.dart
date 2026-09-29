import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/play_mode.dart';
import 'package:han_music/app/data/models/sleep_timer_mode.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/sleep_timer_coordinator.dart';
import 'package:han_music/app/services/timer_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  late DateTime now;
  late _GatedPauseBackend backend;
  late PlayerService player;
  late TimerService timer;
  late SleepTimerCoordinator coordinator;
  final first = Song(
    uri: Uri.file('D:/generated/first.wav'),
    fileName: 'first.wav',
  );
  final second = Song(
    uri: Uri.file('D:/generated/second.wav'),
    fileName: 'second.wav',
  );

  setUp(() {
    now = DateTime.utc(2026, 9, 29);
    backend = _GatedPauseBackend();
    player = PlayerService(backend);
    timer = TimerService(now: () => now, onExpired: player.pause);
    coordinator = SleepTimerCoordinator(player: player, timer: timer);
  });
  tearDown(() async {
    backend.releasePause();
    coordinator.dispose();
    timer.onClose();
    await player.shutdown();
  });

  for (final mode in PlayMode.values) {
    test(
      'end of current track stops ${mode.name} without loading another source',
      () async {
        player.playMode.value = mode;
        await player.playQueue([first, second]);
        timer.startEndOfTrack(first.id);
        final pauses = backend.pauseCalls;
        backend.emitState(playing: false, completed: true);
        backend.emitPosition(Duration.zero);
        await _flush();
        backend.emitState(playing: false, completed: true);
        await _flush();
        expect(backend.loadedUris, [first.uri]);
        expect(backend.pauseCalls, pauses + 1);
        expect(player.currentSong.value?.id, first.id);
        expect(player.queue, hasLength(2));
        expect(player.position.value, player.duration.value);
        expect(player.isPlaying.value, isFalse);
        expect(timer.mode.value, SleepTimerMode.off);
        expect(timer.statusMessage.value, '定时已停止播放');
        await player.togglePlayback();
        expect(backend.seekPositions.last, Duration.zero);
        expect(player.isPlaying.value, isTrue);
      },
    );
  }

  for (final timerFirst in [false, true]) {
    test(
      'deadline/completion race with timerFirst=$timerFirst never loads the next track',
      () async {
        await player.playQueue([first, second]);
        timer.start(const Duration(seconds: 1));
        now = now.add(const Duration(seconds: 2));
        if (timerFirst) timer.checkDeadline();
        backend.emitState(playing: false, completed: true);
        if (!timerFirst) timer.checkDeadline();
        await _flush();
        expect(backend.loadedUris, [first.uri]);
        expect(player.currentSong.value?.id, first.id);
        expect(player.queue, hasLength(2));
        expect(player.isPlaying.value, isFalse);
      },
    );
  }

  test(
    'error consumes track-end timer instead of automatically skipping',
    () async {
      await player.playQueue([first, second]);
      timer.startEndOfTrack(first.id);
      backend.emitError(StateError('generated decode failure'));
      await _flush();
      expect(backend.loadedUris, [first.uri]);
      expect(player.currentSong.value?.id, first.id);
      expect(player.queue, hasLength(2));
      expect(player.isPlaying.value, isFalse);
      expect(player.errorMessage.value, isNotNull);
      expect(timer.isActive, isFalse);
    },
  );

  test(
    'a load completing after deadline becomes ready without calling native play',
    () async {
      backend.loadCompleter = Completer<Duration?>();
      final loading = player.playQueue([first, second]);
      await _flush();
      timer.start(const Duration(seconds: 1));
      now = now.add(const Duration(seconds: 2));
      backend.loadCompleter!.complete(const Duration(minutes: 3));
      await loading;
      await _flush();
      expect(backend.playCalls, 0);
      expect(backend.loadedUris, [first.uri]);
      expect(player.currentSong.value?.id, first.id);
      expect(player.isPlaying.value, isFalse);
      expect(player.canPlay, isTrue);
      await player.togglePlayback();
      expect(backend.playCalls, 1);
    },
  );

  test(
    'pausing, seeking and reordering keep track-end policy; removing current cancels it',
    () async {
      await player.playQueue([first, second]);
      timer.startEndOfTrack(first.id);
      await player.pause();
      await player.seek(const Duration(seconds: 20));
      player.reorderQueue(0, 2);
      expect(timer.currentSongId.value, first.id);
      expect(timer.mode.value, SleepTimerMode.endOfTrack);
      await player.togglePlayback();
      expect(timer.mode.value, SleepTimerMode.endOfTrack);
      await player.removeFromQueue(first.id);
      expect(timer.isActive, isFalse);
      expect(player.currentSong.value?.id, second.id);
      expect(player.isPlaying.value, isTrue);
    },
  );

  test(
    'manual next cancels track-end mode while ordinary countdown survives navigation',
    () async {
      await player.playQueue([first, second]);
      timer.startEndOfTrack(first.id);
      await player.next();
      expect(timer.isActive, isFalse);
      expect(timer.statusMessage.value, contains('已取消'));
      timer.start(const Duration(minutes: 5));
      final deadline = timer.deadline.value;
      await player.previous();
      expect(timer.deadline.value, deadline);
      expect(timer.mode.value, SleepTimerMode.countdown);
    },
  );

  test(
    'extension uses original deadline and overdue extension expires instead of reviving',
    () async {
      await player.playQueue([first]);
      timer.start(const Duration(minutes: 5));
      final original = timer.deadline.value!;
      now = now.add(const Duration(minutes: 2));
      expect(timer.extend10Minutes(), isTrue);
      expect(timer.deadline.value, original.add(const Duration(minutes: 10)));
      expect(timer.remaining.value, const Duration(minutes: 13));
      now = original.add(const Duration(minutes: 11));
      expect(timer.extend10Minutes(), isFalse);
      await _flush();
      expect(timer.isActive, isFalse);
      expect(player.isPlaying.value, isFalse);
    },
  );

  test(
    'new countdown replaces track-end policy and cancellation permits automatic advancement',
    () async {
      await player.playQueue([first, second]);
      timer.startEndOfTrack(first.id);
      timer.start(const Duration(minutes: 10));
      expect(timer.currentSongId.value, isNull);
      backend.emitState(playing: false, completed: true);
      await _flush();
      expect(player.currentSong.value?.id, second.id);
      expect(timer.mode.value, SleepTimerMode.countdown);
      timer.startEndOfTrack(second.id);
      timer.cancel();
      player.playMode.value = PlayMode.repeatAll;
      backend.emitState(playing: false, completed: true);
      await _flush();
      expect(player.currentSong.value?.id, first.id);
      expect(player.isPlaying.value, isTrue);
    },
  );

  test(
    'manual selection waits for an in-flight expiry pause before starting the new source',
    () async {
      await player.playQueue([first, second]);
      backend.gateNextPause();
      timer.start(const Duration(seconds: 1));
      now = now.add(const Duration(seconds: 2));
      timer.checkDeadline();
      await _flush();
      final playCalls = backend.playCalls;
      final selection = player.playAt(1);
      await _flush();
      expect(backend.playCalls, playCalls);
      backend.releasePause();
      await selection;
      await _flush();
      expect(player.currentSong.value?.id, second.id);
      expect(player.isPlaying.value, isTrue);
      expect(backend.playCalls, playCalls + 1);
    },
  );

  test(
    'dispose clears both active and pending policy without changing the queue',
    () async {
      await player.playQueue([first, second]);
      timer.start(const Duration(seconds: 1));
      now = now.add(const Duration(seconds: 2));
      timer.checkDeadline();
      coordinator.dispose();
      await _flush();
      expect(timer.isActive, isFalse);
      expect(player.isPlaying.value, isTrue);
      expect(player.queue, hasLength(2));
    },
  );
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _GatedPauseBackend extends FakeAudioBackend {
  Completer<void>? _gate;
  bool _gateNext = false;

  void gateNextPause() {
    _gate = Completer<void>();
    _gateNext = true;
  }

  void releasePause() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<void> pause() async {
    if (_gateNext) {
      _gateNext = false;
      await _gate!.future;
    }
    await super.pause();
  }
}
