import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/play_mode.dart';
import 'package:han_music/app/data/models/queue_add_result.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/sleep_timer_coordinator.dart';
import 'package:han_music/app/services/timer_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  late _SelectiveFailureBackend backend;
  late PlayerService player;
  final songs = List.generate(
    4,
    (index) => Song(
      uri: Uri.file('D:/music/track-$index.mp3', windows: true),
      fileName: 'track-$index.mp3',
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

  test('empty queue and invalid operations remain safe', () async {
    await player.playQueue([]);
    await player.next();
    await player.previous();
    await player.playAt(-1);
    await player.playAt(0);
    await player.removeFromQueue('absent');
    await player.clearQueue();
    player.reorderQueue(0, 1);
    await player.restoreQueue([]);
    await player.togglePlayback();
    expect(player.queue, isEmpty);
    expect(player.currentIndex, -1);
    expect(player.currentSong.value, isNull);
    expect(player.canPlay, isFalse);
    expect(backend.loadedUris, isEmpty);
    expect(player.addToQueue([]), QueueAddResult.unchanged);
    await player.shutdown();
    await player.clearQueue();
    expect(player.addToQueue(songs), QueueAddResult.unavailable);
    expect(player.queue, isEmpty);
  });

  for (final mode in PlayMode.values) {
    test('single track completion obeys ${mode.name}', () async {
      player.playMode.value = mode;
      await player.playQueue([songs.first]);
      await completeTrack();
      final repeats = mode != PlayMode.sequential;
      expect(backend.loadedUris, hasLength(repeats ? 2 : 1));
      expect(backend.playCalls, repeats ? 2 : 1);
      expect(player.isPlaying.value, repeats);
      expect(player.currentIndex, 0);
    });
  }

  test(
    'sequential completion loads the next source and stops at the end',
    () async {
      await player.playQueue(songs.take(3).toList());
      await completeTrack();
      expect(player.currentSong.value?.id, songs[1].id);
      expect(player.isPlaying.value, isTrue);
      await completeTrack();
      expect(player.currentSong.value?.id, songs[2].id);
      await completeTrack();
      expect(player.isPlaying.value, isFalse);
      expect(backend.loadedUris, songs.take(3).map((song) => song.uri));
      expect(backend.playCalls, 3);
      await player.next();
      expect(player.currentSong.value?.id, songs[0].id);
      await player.previous();
      expect(player.currentSong.value?.id, songs[2].id);
    },
  );

  test('repeat-all completion wraps to the first source', () async {
    player.playMode.value = PlayMode.repeatAll;
    await player.playQueue(songs.take(2).toList());
    await completeTrack();
    await completeTrack();
    expect(backend.loadedUris, [songs[0].uri, songs[1].uri, songs[0].uri]);
    expect(player.isPlaying.value, isTrue);
  });

  test('sequential automatic skipping stops at a damaged queue tail', () async {
    backend.badUris.add(songs[1].uri);
    await player.playQueue(songs.take(2).toList());
    await completeTrack();
    await _settle();
    expect(backend.loadedUris, [songs[0].uri, songs[1].uri]);
    expect(backend.playCalls, 1);
    expect(player.isPlaying.value, isFalse);
    expect(player.canPlay, isFalse);
  });

  test(
    'sequential runtime error at the tail does not wrap automatically',
    () async {
      await player.playQueue(songs.take(2).toList(), startIndex: 1);
      backend.emitError(StateError('Last source failed'));
      await _settle();
      expect(backend.loadedUris, [songs[1].uri]);
      expect(player.isPlaying.value, isFalse);
      await player.next();
      expect(backend.loadedUris, [songs[1].uri, songs[0].uri]);
    },
  );

  test('repeat-one repeats on completion but manual next advances', () async {
    player.playMode.value = PlayMode.repeatOne;
    await player.playQueue(songs.take(2).toList());
    await completeTrack();
    expect(backend.loadedUris, [songs[0].uri, songs[0].uri]);
    await player.next();
    expect(player.currentSong.value?.id, songs[1].id);
  });

  test('duplicate completed events advance only once', () async {
    await player.playQueue(songs);
    backend.emitState(playing: true, completed: true);
    backend.emitState(playing: true, completed: true);
    await _settle();
    expect(backend.loadedUris, [songs[0].uri, songs[1].uri]);
  });

  test(
    'shuffle visits every track before repeats and previous follows history',
    () async {
      player.playMode.value = PlayMode.shuffle;
      await player.playQueue(songs);
      final visited = [player.currentSong.value!.id];
      for (var index = 1; index < songs.length; index++) {
        await completeTrack();
        visited.add(player.currentSong.value!.id);
      }
      expect(visited.toSet(), songs.map((song) => song.id).toSet());
      final latest = visited.last;
      await player.previous();
      expect(player.currentSong.value?.id, visited[visited.length - 2]);
      await player.next();
      expect(player.currentSong.value?.id, latest);
      await completeTrack();
      expect(player.currentSong.value?.id, isNot(latest));
    },
  );

  test('adding songs deduplicates IDs without interrupting playback', () async {
    await player.playQueue([songs[0], songs[1], songs[0]]);
    expect(
      player.addToQueue([songs[1], songs[2], songs[2]]),
      QueueAddResult.added,
    );
    expect(
      player.queue.map((song) => song.id),
      songs.take(3).map((song) => song.id),
    );
    expect(backend.loadedUris, [songs[0].uri]);
    expect(player.isPlaying.value, isTrue);
  });

  test(
    'duplicate queue additions preserve the remaining shuffle track without notifications',
    () async {
      player.playMode.value = PlayMode.shuffle;
      await player.playQueue(songs);
      final visited = {player.currentSong.value!.id};
      for (var index = 1; index < songs.length - 1; index++) {
        await completeTrack();
        visited.add(player.currentSong.value!.id);
      }
      final remaining = songs.singleWhere((song) => !visited.contains(song.id));
      final selectedId = player.currentSong.value!.id;
      final callsBeforeAdding = backend.calls.toList();
      var queueNotifications = 0;
      final subscription = player.queue.listen((_) => queueNotifications++);
      addTearDown(subscription.cancel);

      expect(player.addToQueue(songs), QueueAddResult.unchanged);
      expect(player.addToQueue([songs.first]), QueueAddResult.unchanged);
      expect(player.addToQueue([]), QueueAddResult.unchanged);
      await _settle();
      expect(queueNotifications, 0);
      expect(player.currentSong.value?.id, selectedId);
      expect(backend.calls, callsBeforeAdding);
      expect(player.isPlaying.value, isTrue);

      await completeTrack();
      expect(player.currentSong.value?.id, remaining.id);
      expect(backend.loadedUris.toSet(), songs.map((song) => song.uri).toSet());
    },
  );

  test('adding to an empty queue selects a paused lazy-load track', () async {
    expect(player.addToQueue([songs[0]]), QueueAddResult.added);
    expect(player.canPlay, isTrue);
    expect(player.isPlaying.value, isFalse);
    expect(backend.loadedUris, isEmpty);
    await player.togglePlayback();
    expect(backend.loadedUris, [songs[0].uri]);
  });

  test(
    'clearing a playing queue resets selection and preserves paused requeue and timer policy',
    () async {
      final timer = TimerService(
        onExpired: player.pauseForSleepTimer,
        now: () => DateTime.utc(2026, 10, 2),
      );
      final coordinator = SleepTimerCoordinator(player: player, timer: timer);
      addTearDown(() {
        coordinator.dispose();
        timer.onClose();
      });
      await player.playQueue(songs);
      backend.emitPosition(const Duration(seconds: 37));
      timer.startEndOfTrack(songs.first.id);
      final pauses = backend.pauseCalls;

      final clearing = player.clearQueue();
      expect(player.queue, isEmpty);
      expect(player.currentSong.value, isNull);
      expect(player.currentIndex, -1);
      expect(player.position.value, Duration.zero);
      expect(player.duration.value, Duration.zero);
      expect(player.isPlaying.value, isFalse);
      expect(player.canPlay, isFalse);
      expect(timer.isActive, isFalse);
      await clearing;
      expect(backend.pauseCalls, pauses + 1);
      expect(backend.playCalls, 1);

      expect(player.addToQueue([songs[1]]), QueueAddResult.added);
      expect(player.currentSong.value?.id, songs[1].id);
      expect(player.isPlaying.value, isFalse);
      expect(player.canPlay, isTrue);
      expect(backend.loadedUris, [songs.first.uri]);
      expect(backend.playCalls, 1);

      timer.start(const Duration(minutes: 15));
      final deadline = timer.deadline.value;
      await player.clearQueue();
      expect(timer.isActive, isTrue);
      expect(timer.deadline.value, deadline);
      expect(player.queue, isEmpty);
      expect(player.isPlaying.value, isFalse);
    },
  );

  test('clearing during native load prevents late autoplay', () async {
    final gate = backend.loadCompleter = Completer<Duration?>();
    final opening = player.playQueue(songs);
    await _settle();
    expect(backend.loadedUris, [songs.first.uri]);

    final clearing = player.clearQueue();
    expect(player.queue, isEmpty);
    expect(player.currentSong.value, isNull);
    gate.complete(const Duration(minutes: 3));
    await Future.wait([opening, clearing]);
    expect(backend.playCalls, 0);
    expect(player.isPlaying.value, isFalse);
    expect(player.isLoading.value, isFalse);
    expect(player.canPlay, isFalse);
    expect(player.position.value, Duration.zero);
    expect(player.duration.value, Duration.zero);
  });

  test(
    'reorder and removing a different item preserve the playing identity',
    () async {
      await player.playQueue(songs.take(3).toList(), startIndex: 1);
      player.reorderQueue(0, 3);
      expect(player.queue.map((song) => song.id), [
        songs[1].id,
        songs[2].id,
        songs[0].id,
      ]);
      expect(player.currentIndex, 0);
      expect(backend.loadedUris, [songs[1].uri]);
      await player.removeFromQueue(songs[0].id);
      expect(player.currentSong.value?.id, songs[1].id);
      expect(backend.loadedUris, [songs[1].uri]);
      await completeTrack();
      expect(player.currentSong.value?.id, songs[2].id);
    },
  );

  test(
    'removing the current track selects its successor and removing last clears',
    () async {
      await player.playQueue(songs.take(3).toList(), startIndex: 1);
      await player.removeFromQueue(songs[1].id);
      expect(player.currentSong.value?.id, songs[2].id);
      expect(player.isPlaying.value, isTrue);
      await player.removeFromQueue(songs[2].id);
      expect(player.currentSong.value?.id, songs[0].id);
      await player.removeFromQueue(songs[0].id);
      expect(player.queue, isEmpty);
      expect(player.currentSong.value, isNull);
      expect(player.canPlay, isFalse);
      expect(player.isPlaying.value, isFalse);
    },
  );

  test('removing a paused current track keeps the successor paused', () async {
    await player.playQueue(songs.take(2).toList());
    await player.pause();
    final playCalls = backend.playCalls;
    await player.removeFromQueue(songs[0].id);
    expect(player.currentSong.value?.id, songs[1].id);
    expect(player.canPlay, isTrue);
    expect(player.isPlaying.value, isFalse);
    expect(backend.playCalls, playCalls);
  });

  test('missing and damaged tracks are skipped to a working source', () async {
    backend.badUris.add(songs[1].uri);
    await player.playQueue([
      songs[0].copyWith(isMissing: true),
      songs[1],
      songs[2],
    ]);
    expect(backend.loadedUris, [songs[1].uri, songs[2].uri]);
    expect(player.currentSong.value?.id, songs[2].id);
    expect(player.isPlaying.value, isTrue);
    expect(player.errorMessage.value, isNull);
  });

  test('disabling skip-on-error stops at the first damaged source', () async {
    player.skipOnError.value = false;
    backend.badUris.add(songs[0].uri);
    await player.playQueue(songs.take(2).toList());
    expect(backend.loadedUris, [songs[0].uri]);
    expect(player.canPlay, isFalse);
    expect(player.isPlaying.value, isFalse);
    expect(player.errorMessage.value, isNotEmpty);
  });

  for (final mode in PlayMode.values) {
    test(
      'all damaged tracks terminate without looping in ${mode.name}',
      () async {
        player.playMode.value = mode;
        backend.badUris.addAll(songs.map((song) => song.uri));
        await player.playQueue(songs);
        await _settle();
        expect(
          backend.loadedUris.toSet(),
          songs.map((song) => song.uri).toSet(),
        );
        expect(backend.loadedUris, hasLength(songs.length));
        expect(backend.playCalls, 0);
        expect(player.isLoading.value, isFalse);
        expect(player.canPlay, isFalse);
        expect(player.errorMessage.value, isNotEmpty);
      },
    );
  }

  test('runtime failures skip once per source and eventually stop', () async {
    player.playMode.value = PlayMode.repeatAll;
    await player.playQueue(songs.take(3).toList());
    for (var index = 0; index < 3; index++) {
      backend.emitError(StateError('Native source $index failed'));
      await _settle();
    }
    expect(backend.loadedUris, songs.take(3).map((song) => song.uri));
    expect(player.isPlaying.value, isFalse);
    expect(player.canPlay, isFalse);
    expect(backend.pauseCalls, greaterThanOrEqualTo(6));
  });

  test('stream failure during loading skips to the next source', () async {
    final gate = Completer<Duration?>();
    backend.loadCompleter = gate;
    final opening = player.playQueue(songs.take(2).toList());
    await _settle();
    backend.emitError(StateError('Loading source emitted an error'));
    backend.loadCompleter = null;
    gate.complete(const Duration(minutes: 3));
    await opening;
    expect(backend.loadedUris, [songs[0].uri, songs[1].uri]);
    expect(player.currentSong.value?.id, songs[1].id);
    expect(backend.playCalls, 1);
  });

  test(
    'runtime error with skipping disabled really pauses without advancing',
    () async {
      player.skipOnError.value = false;
      await player.playQueue(songs);
      backend.emitError(StateError('Native playback failed'));
      await _settle();
      expect(backend.loadedUris, [songs[0].uri]);
      expect(backend.pauseCalls, 2);
      expect(player.canPlay, isFalse);
    },
  );

  test(
    'library updates change queued metadata but do not insert or remove',
    () async {
      await player.playQueue(songs.take(2).toList());
      final updated = songs[0].copyWith(
        trackTitle: 'Updated title',
        isMissing: true,
      );
      player.updateSongs([updated, songs[2]]);
      expect(player.queue, hasLength(2));
      expect(player.currentSong.value?.title, 'Updated title');
      expect(player.queue.first.isMissing, isTrue);
      expect(backend.loadedUris, [songs[0].uri]);
    },
  );

  test(
    'restore remains paused then loads and seeks only on explicit play',
    () async {
      await player.restoreQueue(
        songs,
        currentId: songs[1].id,
        position: const Duration(seconds: 42),
        mode: PlayMode.repeatAll,
        volume: 0.23,
        skipOnError: false,
      );
      expect(backend.loadedUris, isEmpty);
      expect(backend.playCalls, 0);
      expect(player.currentIndex, 1);
      expect(player.position.value, const Duration(seconds: 42));
      expect(player.playMode.value, PlayMode.repeatAll);
      expect(player.volume.value, 0.23);
      expect(player.skipOnError.value, isFalse);
      expect(player.canPlay, isTrue);
      expect(player.isPlaying.value, isFalse);
      await player.togglePlayback();
      expect(backend.loadedUris, [songs[1].uri]);
      expect(backend.seekPositions, [const Duration(seconds: 42)]);
      expect(backend.volumes, [0.23]);
      expect(backend.playCalls, 1);
    },
  );

  test(
    'restored position can be edited and clamps to known duration',
    () async {
      await player.restoreQueue(
        [songs[0]],
        position: const Duration(seconds: -5),
        volume: 9,
      );
      expect(player.position.value, Duration.zero);
      expect(player.volume.value, 1);
      await player.seek(const Duration(hours: 1));
      expect(player.position.value, const Duration(minutes: 3));
      expect(backend.seekPositions, isEmpty);
      await player.togglePlayback();
      expect(backend.seekPositions, [const Duration(minutes: 3)]);
    },
  );

  test(
    'unknown restored ID falls back to the first track at the start',
    () async {
      await player.restoreQueue(
        songs,
        currentId: 'removed-track',
        position: const Duration(seconds: 55),
      );
      expect(player.currentSong.value?.id, songs[0].id);
      expect(player.position.value, Duration.zero);
      expect(player.isPlaying.value, isFalse);
    },
  );

  test(
    'restore can skip a missing selected file without reusing its position',
    () async {
      await player.restoreQueue(
        [songs[0].copyWith(isMissing: true), songs[1]],
        currentId: songs[0].id,
        position: const Duration(seconds: 45),
      );
      expect(player.canPlay, isTrue);
      await player.togglePlayback();
      expect(backend.loadedUris, [songs[1].uri]);
      expect(backend.seekPositions, isEmpty);
      expect(player.currentIndex, 1);
    },
  );

  for (final completionFirst in [false, true]) {
    test(
      'timer and completion in one turn never resume audio (completionFirst=$completionFirst)',
      () async {
        await player.playQueue(songs.take(2).toList());
        var now = DateTime.utc(2026, 9, 29);
        final timer = TimerService(onExpired: player.pause, now: () => now);
        addTearDown(timer.onClose);
        timer.start(const Duration(seconds: 1));
        now = now.add(const Duration(seconds: 1));
        if (completionFirst) backend.emitState(playing: true, completed: true);
        timer.checkDeadline();
        if (!completionFirst) backend.emitState(playing: true, completed: true);
        await _settle();
        expect(backend.playCalls, 1);
        expect(player.isPlaying.value, isFalse);
        expect(timer.remaining.value, isNull);
      },
    );
  }

  test(
    'timer while automatic next is loading prevents late autoplay',
    () async {
      await player.playQueue(songs.take(2).toList());
      final gate = Completer<Duration?>();
      backend.loadCompleter = gate;
      await completeTrack();
      expect(player.isLoading.value, isTrue);
      expect(backend.loadedUris, [songs[0].uri, songs[1].uri]);
      await player.pause();
      gate.complete(const Duration(minutes: 3));
      await _settle();
      expect(player.currentIndex, 1);
      expect(player.canPlay, isTrue);
      expect(player.isPlaying.value, isFalse);
      expect(backend.playCalls, 1);
    },
  );

  test('removing a loading current source cancels its late play', () async {
    await player.playQueue(songs.take(3).toList());
    final gate = Completer<Duration?>();
    backend.loadCompleter = gate;
    final selecting = player.playAt(1);
    await _settle();
    final removing = player.removeFromQueue(songs[1].id);
    backend.loadCompleter = null;
    gate.complete(const Duration(minutes: 3));
    await Future.wait([selecting, removing]);
    expect(player.currentSong.value?.id, songs[2].id);
    expect(backend.loadedUris, [songs[0].uri, songs[1].uri, songs[2].uri]);
    expect(backend.playCalls, 2);
  });

  test(
    'reordering a loading source retains its identity and corrected index',
    () async {
      await player.playQueue(songs.take(3).toList());
      final gate = Completer<Duration?>();
      backend.loadCompleter = gate;
      final selecting = player.playAt(1);
      await _settle();
      player.reorderQueue(1, 3);
      gate.complete(const Duration(minutes: 3));
      await selecting;
      expect(player.currentSong.value?.id, songs[1].id);
      expect(player.currentIndex, 2);
      expect(backend.playCalls, 2);
    },
  );

  test(
    'queued selection changes load only the latest requested source',
    () async {
      await player.playQueue(songs.take(3).toList());
      final gate = Completer<Duration?>();
      backend.loadCompleter = gate;
      final first = player.playAt(1);
      await _settle();
      final superseded = player.playAt(2);
      final latest = player.playAt(0);
      backend.loadCompleter = null;
      gate.complete(const Duration(minutes: 3));
      await Future.wait([first, superseded, latest]);
      expect(player.currentSong.value?.id, songs[0].id);
      expect(backend.loadedUris, [songs[0].uri, songs[1].uri, songs[0].uri]);
      expect(backend.playCalls, 2);
    },
  );

  test(
    'completion received after pause cannot trigger automatic next',
    () async {
      await player.playQueue(songs);
      await player.pause();
      await completeTrack();
      expect(backend.loadedUris, [songs[0].uri]);
      expect(backend.playCalls, 1);
    },
  );

  test(
    'restoring during load cancels old autoplay and defers the restored source',
    () async {
      final gate = Completer<Duration?>();
      backend.loadCompleter = gate;
      final opening = player.playQueue(songs);
      await _settle();
      final restoring = player.restoreQueue(songs, currentId: songs[2].id);
      gate.complete(const Duration(minutes: 3));
      await Future.wait([opening, restoring]);
      expect(player.currentSong.value?.id, songs[2].id);
      expect(player.isPlaying.value, isFalse);
      expect(player.canPlay, isTrue);
      expect(backend.loadedUris, [songs[0].uri]);
      expect(backend.playCalls, 0);
    },
  );
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
