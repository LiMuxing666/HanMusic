import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/modules/player/playback_shortcuts.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import 'support/fake_audio_backend.dart';

void main() {
  late FakeAudioBackend backend;
  late PlayerService player;
  late TimerService timer;
  late PlayerController controller;
  final songs = List.generate(
    3,
    (index) => Song(
      uri: Uri.file('D:/music/shortcut-$index.mp3', windows: true),
      fileName: 'shortcut-$index.mp3',
    ),
  );

  void testShortcuts(
    String description,
    Future<void> Function(WidgetTester) run,
  ) {
    testWidgets(description, (tester) async {
      // Create the player's completed selection Future in the test's zone.
      // A fixture made by setUp can otherwise cross the fake-async boundary.
      backend = FakeAudioBackend();
      player = PlayerService(backend);
      timer = TimerService(onExpired: player.pause);
      controller = PlayerController(
        player: player,
        timer: timer,
        picker: _UnusedSongPicker(),
      );
      controller.onStart();
      try {
        await run(tester);
      } finally {
        controller.onDelete();
        timer.onClose();
        await tester.pumpWidget(const SizedBox.shrink());
        // Cancel subscriptions and close backend streams outside fake async,
        // matching the lifecycle used by the existing player widget tests.
        await tester.runAsync(player.shutdown);
        await tester.pump();
      }
    });
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPlaybackShortcuts(
          controller: controller,
          child: const Scaffold(
            body: Column(
              children: [
                TextField(key: Key('shortcut-editor')),
                SizedBox(key: Key('shortcut-content')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testShortcuts('playback commands navigate without capturing ordinary keys', (
    tester,
  ) async {
    await player.playQueue(songs);
    await mount(tester);
    final calls = backend.calls.toList();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(backend.calls, calls);

    await _shortcut(tester, LogicalKeyboardKey.space);
    expect(player.isPlaying.value, isFalse);
    await _shortcut(tester, LogicalKeyboardKey.space);
    expect(player.isPlaying.value, isTrue);
    await _shortcut(tester, LogicalKeyboardKey.arrowRight);
    expect(player.currentSong.value, songs[1]);
    await _shortcut(tester, LogicalKeyboardKey.arrowLeft);
    expect(player.currentSong.value, songs.first);
  });

  testShortcuts('seek and volume commands clamp and mute restores volume', (
    tester,
  ) async {
    await player.playQueue(songs);
    await mount(tester);
    backend.emitPosition(const Duration(seconds: 2));
    await _shortcut(tester, LogicalKeyboardKey.arrowLeft, shift: true);
    expect(backend.seekPositions.last, Duration.zero);
    backend.emitPosition(const Duration(seconds: 178));
    await _shortcut(tester, LogicalKeyboardKey.arrowRight, shift: true);
    expect(backend.seekPositions.last, const Duration(minutes: 3));
    await controller.setVolume(0.98);
    await _shortcut(tester, LogicalKeyboardKey.arrowUp);
    expect(player.volume.value, 1);
    await _shortcut(tester, LogicalKeyboardKey.arrowDown);
    expect(player.volume.value, 0.95);
    await _shortcut(tester, LogicalKeyboardKey.keyM);
    expect(player.volume.value, 0);
    await _shortcut(tester, LogicalKeyboardKey.arrowDown);
    expect(player.volume.value, 0);
    await _shortcut(tester, LogicalKeyboardKey.keyM);
    expect(player.volume.value, 0.95);
  });

  testShortcuts('text editing blocks every playback shortcut', (tester) async {
    await player.playQueue(songs);
    await mount(tester);
    await tester.enterText(find.byKey(const Key('shortcut-editor')), 'music');
    final calls = backend.calls.toList();
    await _allShortcuts(tester);
    expect(backend.calls, calls);
    expect(player.currentSong.value, songs.first);
    expect(player.isPlaying.value, isTrue);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('shortcut-editor')))
          .enabled,
      isNot(false),
    );
  });

  testShortcuts('dialog isolates the player even without taking focus', (
    tester,
  ) async {
    await player.playQueue(songs);
    await mount(tester);
    final context = tester.element(find.byKey(const Key('shortcut-content')));
    unawaited(
      showDialog<void>(
        context: context,
        requestFocus: false,
        builder: (_) => const AlertDialog(title: Text('Dialog')),
      ),
    );
    await tester.pumpAndSettle();
    final calls = backend.calls.toList();
    await _allShortcuts(tester);
    expect(backend.calls, calls);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await _shortcut(tester, LogicalKeyboardKey.space);
    expect(player.isPlaying.value, isFalse);
  });

  testShortcuts('empty and loading players ignore transport but allow volume', (
    tester,
  ) async {
    await mount(tester);
    await _transportShortcuts(tester);
    expect(backend.loadedUris, isEmpty);
    expect(backend.seekPositions, isEmpty);
    expect(backend.playCalls, 0);
    await _shortcut(tester, LogicalKeyboardKey.arrowUp);
    expect(player.volume.value, closeTo(0.75, 0.000001));

    final gate = backend.loadCompleter = Completer<Duration?>();
    final loading = player.playQueue(songs);
    try {
      await tester.pump();
      expect(player.isLoading.value, isTrue);
      final calls = backend.calls.toList();
      await _transportShortcuts(tester);
      expect(backend.calls, calls);
      await _shortcut(tester, LogicalKeyboardKey.keyM);
      expect(player.volume.value, 0);
    } finally {
      gate.complete(const Duration(minutes: 3));
      await loading;
      backend.loadCompleter = null;
    }
  });

  testShortcuts(
    'toggle retries failed track and exit suppresses all commands',
    (tester) async {
      player.skipOnError.value = false;
      backend.loadFailure = StateError('Temporary failure');
      await player.playQueue(songs);
      await mount(tester);
      expect(controller.canRetryPlayback, isTrue);
      backend.loadFailure = null;
      await _shortcut(tester, LogicalKeyboardKey.space);
      expect(player.isPlaying.value, isTrue);
      expect(backend.loadedUris, [songs.first.uri, songs.first.uri]);
      expect(player.queue, songs);

      controller.beginExit();
      final calls = backend.calls.toList();
      await _allShortcuts(tester);
      expect(backend.calls, calls);
      controller.cancelExit();
      await _shortcut(tester, LogicalKeyboardKey.space);
      expect(player.isPlaying.value, isFalse);
      controller.onDelete();
      final afterClose = backend.calls.toList();
      await _allShortcuts(tester);
      expect(backend.calls, afterClose);
    },
  );
}

Future<void> _shortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

Future<void> _transportShortcuts(WidgetTester tester) async {
  await _shortcut(tester, LogicalKeyboardKey.space);
  await _shortcut(tester, LogicalKeyboardKey.arrowLeft);
  await _shortcut(tester, LogicalKeyboardKey.arrowRight);
  await _shortcut(tester, LogicalKeyboardKey.arrowLeft, shift: true);
  await _shortcut(tester, LogicalKeyboardKey.arrowRight, shift: true);
}

Future<void> _allShortcuts(WidgetTester tester) async {
  await _transportShortcuts(tester);
  await _shortcut(tester, LogicalKeyboardKey.arrowUp);
  await _shortcut(tester, LogicalKeyboardKey.arrowDown);
  await _shortcut(tester, LogicalKeyboardKey.keyM);
}

class _UnusedSongPicker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}
