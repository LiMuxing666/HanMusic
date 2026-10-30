import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/play_mode.dart';
import 'package:han_music/app/data/models/queue_add_result.dart';
import 'package:han_music/app/data/models/sleep_timer_mode.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/sleep_timer_coordinator.dart';
import 'package:han_music/app/services/timer_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  late _SelectiveFailureBackend backend;
  late PlayerService player;
  final songs = List.generate(
    6,
    (index) => Song(
      uri: Uri.file('D:/music/play-next-$index.mp3', windows: true),
      fileName: 'play-next-$index.mp3',
      duration: const Duration(minutes: 3),
    ),
  );

  setUp(() {
    backend = _SelectiveFailureBackend();
    player = PlayerService(backend);
  });
  tearDown(() => player.shutdown());

  Future<void> completeTrack() async {
    backend.emitState(playing: true, completed: true);
    await _settle();
  }

  for (final mode in PlayMode.values) {
    for (final automatic in [false, true]) {
      test('play next wins ${mode.name} automatic=$automatic', () async {
        player.playMode.value = mode;
        await player.playQueue(songs.take(3).toList());
        final calls = backend.calls.toList();
        final revision = player.selectionRevision;
        backend.emitPosition(const Duration(seconds: 37));
        expect(player.playNext(songs[3]), QueueAddResult.added);
        expect(player.currentSong.value, songs.first);
        expect(player.position.value, const Duration(seconds: 37));
        expect(player.isPlaying.value, isTrue);
        expect(backend.calls, calls);
        expect(player.selectionRevision, revision);
        if (automatic) {
          await completeTrack();
        } else {
          await player.next();
        }
        expect(player.currentSong.value, songs[3]);
        expect(backend.loadedUris, [songs[0].uri, songs[3].uri]);
      });
    }
  }

  test('empty play next selects a paused lazy-load track', () async {
    expect(player.playNext(songs[2]), QueueAddResult.added);
    expect(player.queue, [songs[2]]);
    expect(player.currentSong.value, songs[2]);
    expect(player.isPlaying.value, isFalse);
    expect(player.canPlay, isTrue);
    expect(backend.loadedUris, isEmpty);
    expect(player.playNext(songs[2]), QueueAddResult.unchanged);
    await player.togglePlayback();
    expect(backend.loadedUris, [songs[2].uri]);
  });

  test(
    'scheduling during native loading keeps that selection active',
    () async {
      final gate = backend.loadCompleter = Completer<Duration?>();
      final opening = player.playQueue(songs.take(3).toList(), startIndex: 1);
      try {
        await _settle();
        final revision = player.selectionRevision;
        expect(player.isLoading.value, isTrue);
        expect(player.playNext(songs[0]), QueueAddResult.added);
        expect(player.queue, [songs[1], songs[0], songs[2]]);
        expect(player.currentSong.value, songs[1]);
        expect(player.selectionRevision, revision);
        expect(backend.loadedUris, [songs[1].uri]);
      } finally {
        gate.complete(const Duration(minutes: 3));
        await opening;
        backend.loadCompleter = null;
      }
      expect(player.isPlaying.value, isTrue);
      await player.next();
      expect(player.currentSong.value, songs[0]);
    },
  );

  test(
    'existing requests reorder, deduplicate and keep latest first',
    () async {
      player.playMode.value = PlayMode.shuffle;
      await player.playQueue(songs.take(4).toList());
      expect(player.playNext(songs[2]), QueueAddResult.added);
      expect(player.queue, [songs[0], songs[2], songs[1], songs[3]]);
      expect(player.playNext(songs[3]), QueueAddResult.added);
      expect(player.queue, [songs[0], songs[3], songs[2], songs[1]]);
      expect(player.playNext(songs[2]), QueueAddResult.added);
      expect(player.queue, [songs[0], songs[2], songs[3], songs[1]]);
      final revision = player.selectionRevision;
      final calls = backend.calls.toList();
      var notifications = 0;
      final subscription = player.queue.listen((_) => notifications++);
      addTearDown(subscription.cancel);
      expect(player.playNext(songs[2]), QueueAddResult.unchanged);
      expect(player.playNext(songs[0]), QueueAddResult.unchanged);
      await _settle();
      expect(notifications, 0);
      expect(player.selectionRevision, revision);
      expect(backend.calls, calls);
      await player.next();
      expect(player.currentSong.value, songs[2]);
      await player.next();
      expect(player.currentSong.value, songs[3]);
      expect(player.queue.toSet(), songs.take(4).toSet());
    },
  );

  test('latest song snapshot replaces stale missing queue metadata', () async {
    final stale = songs[2].copyWith(isMissing: true, trackTitle: '旧标题');
    final latest = songs[2].copyWith(trackTitle: '已恢复的新标题');
    await player.playQueue([songs[0], songs[1], stale]);
    final calls = backend.calls.toList();
    final revision = player.selectionRevision;
    expect(player.playNext(latest), QueueAddResult.added);
    expect(player.queue.map((song) => song.id), [
      songs[0].id,
      songs[2].id,
      songs[1].id,
    ]);
    expect(player.queue[1], same(latest));
    expect(player.queue[1].isMissing, isFalse);
    expect(player.selectionRevision, revision);
    expect(backend.calls, calls);
    await player.next();
    expect(player.currentSong.value, same(latest));
    expect(player.isPlaying.value, isTrue);
  });

  test(
    'metadata changes notify once but equal snapshot requests do not',
    () async {
      await player.playQueue(songs.take(3).toList());
      player.playNext(songs[2]);
      var notifications = 0;
      final subscription = player.queue.listen((_) => notifications++);
      addTearDown(subscription.cancel);
      final updated = songs[2].copyWith(artist: '新歌手');
      final revision = player.selectionRevision;
      final calls = backend.calls.toList();
      expect(player.playNext(updated), QueueAddResult.added);
      await _settle();
      expect(notifications, greaterThan(0));
      expect(player.queue[1], same(updated));
      notifications = 0;
      expect(player.playNext(updated.copyWith()), QueueAddResult.unchanged);
      await _settle();
      expect(notifications, 0);
      expect(player.queue[1], same(updated));
      expect(player.selectionRevision, revision);
      expect(backend.calls, calls);
    },
  );

  test(
    'explicit scheduling keeps the remaining shuffle cycle and history',
    () async {
      player.playMode.value = PlayMode.shuffle;
      await player.playQueue(songs.take(4).toList());
      final visited = {player.currentSong.value!.id};
      await player.next();
      final beforePriority = player.currentSong.value!;
      visited.add(beforePriority.id);
      final requested = songs
          .take(4)
          .firstWhere((song) => !visited.contains(song.id));
      final remaining = songs
          .take(4)
          .singleWhere(
            (song) => !visited.contains(song.id) && song.id != requested.id,
          );
      player.playNext(requested);
      await player.next();
      expect(player.currentSong.value, requested);
      await player.previous();
      expect(player.currentSong.value, beforePriority);
      await player.next();
      expect(player.currentSong.value, requested);
      await player.next();
      expect(player.currentSong.value, remaining);
    },
  );

  test(
    'new forced track does not reset an existing shuffle remainder',
    () async {
      player.playMode.value = PlayMode.shuffle;
      await player.playQueue(songs.take(3).toList());
      await player.next();
      final visited = backend.loadedUris.toSet();
      final remaining = songs
          .take(3)
          .singleWhere((song) => !visited.contains(song.uri));
      player.playNext(songs[4]);
      await player.next();
      expect(player.currentSong.value, songs[4]);
      await player.next();
      expect(player.currentSong.value, remaining);
    },
  );

  test('manual selection consumes its own request', () async {
    player.playMode.value = PlayMode.repeatOne;
    await player.playQueue(songs.take(3).toList());
    player.playNext(songs[2]);
    await player.playAt(player.queue.indexOf(songs[2]));
    await player.playAt(player.queue.indexOf(songs[0]));
    await completeTrack();
    expect(player.currentSong.value, songs[0]);
    expect(backend.loadedUris, [
      songs[0].uri,
      songs[2].uri,
      songs[0].uri,
      songs[0].uri,
    ]);
  });

  test(
    'priority survives a mode change but is consumed after playback',
    () async {
      await player.playQueue(songs.take(3).toList());
      player.playNext(songs[2]);
      player.playMode.value = PlayMode.repeatOne;
      await completeTrack();
      expect(player.currentSong.value, songs[2]);
      await completeTrack();
      expect(backend.loadedUris, [songs[0].uri, songs[2].uri, songs[2].uri]);
    },
  );

  for (final operation in ['delete', 'clear', 'replace', 'restore']) {
    test('$operation clears stale priority intent', () async {
      player.playMode.value = PlayMode.repeatOne;
      await player.playQueue(songs.take(3).toList());
      player.playNext(songs[2]);
      switch (operation) {
        case 'delete':
          await player.removeFromQueue(songs[2].id);
          player.addToQueue([songs[2]]);
        case 'clear':
          await player.clearQueue();
          player.addToQueue(songs.take(3).toList());
          await player.togglePlayback();
        case 'replace':
          await player.playQueue(songs.take(3).toList());
        case 'restore':
          final reordered = player.queue.toList();
          await player.restoreQueue(
            reordered,
            currentId: songs[0].id,
            mode: PlayMode.repeatOne,
          );
          expect(player.queue, reordered);
          await player.togglePlayback();
      }
      await completeTrack();
      expect(player.currentSong.value, songs[0]);
    });
  }

  test(
    'bad priority is attempted once before remaining priority in shuffle',
    () async {
      player.playMode.value = PlayMode.shuffle;
      await player.playQueue(songs.take(4).toList());
      player.playNext(songs[2]);
      player.playNext(songs[3]);
      backend.badUris.add(songs[3].uri);
      await completeTrack();
      expect(backend.loadedUris, [songs[0].uri, songs[3].uri, songs[2].uri]);
      expect(player.currentSong.value, songs[2]);
      await completeTrack();
      await completeTrack();
      expect(
        backend.loadedUris.where((uri) => uri == songs[3].uri),
        hasLength(1),
      );
      expect(player.isPlaying.value, isTrue);
    },
  );

  test(
    'disabled error skipping stops after a failed priority request',
    () async {
      player.skipOnError.value = false;
      await player.playQueue(songs.take(3).toList());
      player.playNext(songs[2]);
      backend.badUris.add(songs[2].uri);
      await completeTrack();
      expect(backend.loadedUris, [songs[0].uri, songs[2].uri]);
      expect(player.isPlaying.value, isFalse);
      await completeTrack();
      expect(backend.loadedUris, [songs[0].uri, songs[2].uri]);
    },
  );

  test(
    'missing and disposed requests are unavailable without mutations',
    () async {
      await player.playQueue(songs.take(2).toList());
      final missing = Song(
        uri: songs[2].uri,
        fileName: songs[2].fileName,
        isMissing: true,
      );
      final calls = backend.calls.toList();
      expect(player.playNext(missing), QueueAddResult.unavailable);
      expect(player.queue, songs.take(2).toList());
      expect(backend.calls, calls);
      await player.shutdown();
      expect(player.playNext(songs[2]), QueueAddResult.unavailable);
      expect(player.queue, songs.take(2).toList());
    },
  );

  test(
    'queued next preserves end-of-track sleep and survives until manual next',
    () async {
      final timer = TimerService(onExpired: player.pauseForSleepTimer);
      final coordinator = SleepTimerCoordinator(player: player, timer: timer);
      addTearDown(() {
        coordinator.dispose();
        timer.onClose();
      });
      player.playMode.value = PlayMode.repeatOne;
      await player.playQueue(songs.take(3).toList());
      timer.startEndOfTrack(songs[0].id);
      player.playNext(songs[2]);
      expect(timer.mode.value, SleepTimerMode.endOfTrack);
      await completeTrack();
      expect(player.currentSong.value, songs[0]);
      expect(player.isPlaying.value, isFalse);
      expect(backend.loadedUris, [songs[0].uri]);
      expect(timer.isActive, isFalse);
      await player.next();
      expect(player.currentSong.value, songs[2]);
    },
  );

  test('expired countdown wins over forced selection', () async {
    var now = DateTime.utc(2026, 10, 29);
    final timer = TimerService(
      onExpired: player.pauseForSleepTimer,
      now: () => now,
    );
    final coordinator = SleepTimerCoordinator(player: player, timer: timer);
    addTearDown(() {
      coordinator.dispose();
      timer.onClose();
    });
    await player.playQueue(songs.take(3).toList());
    timer.start(const Duration(minutes: 1));
    player.playNext(songs[2]);
    now = now.add(const Duration(minutes: 1));
    await completeTrack();
    expect(player.currentSong.value, songs[0]);
    expect(player.isPlaying.value, isFalse);
    expect(backend.loadedUris, [songs[0].uri]);
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

class _SelectiveFailureBackend extends FakeAudioBackend {
  final badUris = <Uri>{};

  @override
  Future<Duration?> load(Uri uri) async {
    if (badUris.contains(uri)) {
      calls.add('load');
      loadedUris.add(uri);
      throw StateError('Damaged fixture: $uri');
    }
    return super.load(uri);
  }
}
