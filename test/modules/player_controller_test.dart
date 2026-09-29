import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAudioBackend backend;
  late PlayerService player;
  late TimerService timer;
  late _FakeSongPicker picker;
  late PlayerController controller;
  late DateTime now;
  final song = Song(
    uri: Uri.file(r'D:\music\测试歌曲.mp3', windows: true),
    fileName: '测试歌曲.mp3',
  );

  setUp(() {
    now = DateTime.utc(2026, 9, 29);
    backend = FakeAudioBackend();
    player = PlayerService(backend);
    timer = TimerService(onExpired: player.pause, now: () => now);
    picker = _FakeSongPicker();
    controller = PlayerController(player: player, timer: timer, picker: picker);
    controller.onStart();
  });

  tearDown(() async {
    controller.onDelete();
    timer.onClose();
    await player.shutdown();
  });

  test('picker cancellation keeps the current track and playback', () async {
    await player.open(song);
    await controller.importFile();

    expect(picker.calls, 1);
    expect(controller.currentSong.value, same(song));
    expect(controller.isPlaying.value, isTrue);
    expect(backend.loadedUris, [song.uri]);
    expect(controller.isImporting.value, isFalse);
    expect(controller.errorMessage.value, isNull);
  });

  test(
    'picker errors are reported without replacing the playing track',
    () async {
      await player.open(song);
      picker.pickAction = () async =>
          throw StateError('Picker permission denied');
      await controller.importFile();

      expect(controller.errorMessage.value, isNotEmpty);
      expect(controller.currentSong.value, same(song));
      expect(controller.isPlaying.value, isTrue);
      expect(controller.isImporting.value, isFalse);
      expect(backend.loadedUris, [song.uri]);
      controller.dismissError();
      expect(controller.errorMessage.value, isNull);
    },
  );

  test('repeated import clicks open one picker and load one track', () async {
    final picked = Completer<Song?>();
    picker.pickAction = () => picked.future;
    final firstImport = controller.importFile();
    await controller.importFile();

    expect(picker.calls, 1);
    expect(controller.isImporting.value, isTrue);
    picked.complete(song);
    await firstImport;

    expect(backend.loadedUris, [song.uri]);
    expect(backend.playCalls, 1);
    expect(controller.isImporting.value, isFalse);
  });

  test('imports are ignored while the backend is loading', () async {
    backend.loadCompleter = Completer<Duration?>();
    final opening = player.open(song);
    await _flushCallbacks();
    await controller.importFile();
    expect(picker.calls, 0);

    backend.loadCompleter!.complete(const Duration(minutes: 3));
    await opening;
  });

  test('closing the controller ignores a late picker result', () async {
    final picked = Completer<Song?>();
    picker.pickAction = () => picked.future;
    final importing = controller.importFile();
    controller.onDelete();
    picked.complete(song);
    await importing;
    await controller.importFile();

    expect(picker.calls, 1);
    expect(backend.loadedUris, isEmpty);
    expect(backend.playCalls, 0);
  });

  test(
    'resume checks an overdue timer and pauses audio exactly once',
    () async {
      await player.open(song);
      controller.startSleepTimer(const Duration(minutes: 5));
      now = now.add(const Duration(hours: 1));
      final pausesBeforeResume = backend.pauseCalls;

      controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await _flushCallbacks();
      expect(backend.pauseCalls, pausesBeforeResume);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _flushCallbacks();
      expect(controller.isPlaying.value, isFalse);
      expect(controller.timerRemaining.value, isNull);
      expect(backend.pauseCalls, pausesBeforeResume + 1);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _flushCallbacks();
      expect(backend.pauseCalls, pausesBeforeResume + 1);
    },
  );

  test('cancelling a sleep timer prevents a pause after resume', () async {
    await player.open(song);
    controller.startSleepTimer(const Duration(minutes: 5));
    controller.cancelSleepTimer();
    now = now.add(const Duration(hours: 1));
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await _flushCallbacks();

    expect(controller.isPlaying.value, isTrue);
    expect(controller.timerRemaining.value, isNull);
    expect(backend.pauseCalls, 1);
  });
}

class _FakeSongPicker implements SongPicker {
  int calls = 0;
  Future<Song?> Function() pickAction = () async => null;

  @override
  Future<Song?> pick() {
    calls++;
    return pickAction();
  }
}

Future<void> _flushCallbacks() => Future<void>.delayed(Duration.zero);
