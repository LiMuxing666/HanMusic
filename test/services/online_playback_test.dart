import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/playback_source_exception.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/sleep_timer_coordinator.dart';
import 'package:han_music/app/services/timer_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  late _OnlineBackend backend;
  late PlayerService player;
  late int resolves;
  Future<Uri> Function(Song)? resolveAction;
  final a = Song.online(
    sourceId: 'source',
    trackId: 'A',
    title: 'Track A',
    duration: const Duration(minutes: 3),
  );
  final b = Song.online(sourceId: 'source', trackId: 'B', title: 'Track B');
  Uri streamFor(Song song, int attempt) => Uri.parse(
    'https://streams.invalid/${song.trackId}?token=ephemeral-$attempt',
  );

  setUp(() {
    backend = _OnlineBackend();
    resolves = 0;
    resolveAction = null;
    player = PlayerService(
      backend,
      resolver: (song) {
        resolves++;
        return resolveAction?.call(song) ??
            Future.value(streamFor(song, resolves));
      },
    );
  });
  tearDown(() => player.shutdown());

  TimerService bindTimer(DateTime Function() now) {
    final timer = TimerService(onExpired: player.pauseForSleepTimer, now: now);
    final coordinator = SleepTimerCoordinator(player: player, timer: timer);
    addTearDown(() {
      coordinator.dispose();
      timer.onClose();
    });
    return timer;
  }

  test(
    'each real online load resolves freshly without replacing stored identity',
    () async {
      await player.playQueue([a]);
      await player.next();
      expect(resolves, 2);
      expect(backend.loadedUris, [streamFor(a, 1), streamFor(a, 2)]);
      expect(player.currentSong.value?.uri, a.uri);
      final saved = AppSnapshot(
        queue: player.queue.toList(),
        currentId: a.id,
      ).toJson().toString();
      expect(saved, contains('hanmusic://track'));
      expect(saved, isNot(contains('ephemeral')));
      expect(saved, isNot(contains('https://')));
    },
  );

  test(
    'mixed queue restore stays paused and resolves only after explicit play',
    () async {
      final local = Song(
        uri: Uri.file('D:/local.mp3', windows: true),
        fileName: 'local.mp3',
      );
      await player.restoreQueue(
        [local, a],
        currentId: a.id,
        position: const Duration(seconds: 25),
      );
      expect(resolves, 0);
      expect(backend.loadedUris, isEmpty);
      expect(player.isPlaying.value, isFalse);
      await player.togglePlayback();
      expect(resolves, 1);
      expect(backend.seekPositions, [const Duration(seconds: 25)]);
      expect(player.currentSong.value?.id, a.id);
    },
  );

  test('a late resolver result cannot load a superseded song', () async {
    final gate = Completer<Uri>();
    resolveAction = (song) =>
        song.id == a.id ? gate.future : Future.value(streamFor(song, resolves));
    final first = player.playQueue([a, b]);
    await _settle();
    final replacement = player.playAt(1);
    gate.complete(streamFor(a, 1));
    await Future.wait([first, replacement]);
    expect(backend.loadedUris, [streamFor(b, 2)]);
    expect(player.currentSong.value?.id, b.id);
  });

  for (final useLocal in [true, false]) {
    for (final lateFailure in [true, false]) {
      test(
        'pending resolve cannot block ${useLocal ? 'local' : 'online'} selection; '
        'late ${lateFailure ? 'failure' : 'success'} stays obsolete',
        () async {
          final gate = Completer<Uri>();
          final replacementSong = useLocal
              ? Song(
                  uri: Uri.file('D:/replacement.mp3', windows: true),
                  fileName: 'replacement.mp3',
                )
              : b;
          resolveAction = (song) => song.id == a.id
              ? gate.future
              : Future.value(streamFor(song, resolves));
          final first = player.playQueue([a, replacementSong]);
          await _settle();
          final replacement = player.playAt(1);
          await _settle();
          try {
            expect(gate.isCompleted, isFalse);
            expect(player.currentSong.value?.id, replacementSong.id);
            expect(backend.playCalls, 1);
            expect(backend.loadedUris, [
              useLocal ? replacementSong.uri : streamFor(b, 2),
            ]);
          } finally {
            if (lateFailure) {
              gate.completeError(StateError('obsolete signed URL failure'));
            } else {
              gate.complete(streamFor(a, 1));
            }
            await Future.wait([first, replacement]);
          }
          await _settle();
          expect(player.currentSong.value?.id, replacementSong.id);
          expect(player.isPlaying.value, isTrue);
          expect(player.errorMessage.value, isNull);
          expect(backend.loadedUris, hasLength(1));
          expect(backend.playCalls, 1);
        },
      );
    }
  }

  test('shutdown drops a late resolver result', () async {
    final gate = Completer<Uri>();
    resolveAction = (_) => gate.future;
    final opening = player.playQueue([a]);
    await _settle();
    await player.shutdown();
    gate.complete(streamFor(a, 1));
    await opening;
    expect(backend.loadedUris, isEmpty);
    expect(backend.playCalls, 0);
  });

  test('replacing a source still serializes native loads', () async {
    final nativeGate = backend.loadCompleter = Completer<Duration?>();
    final first = player.playQueue([a, b]);
    await _settle();
    final replacement = player.playAt(1);
    await _settle();
    expect(resolves, 1);
    expect(backend.loadedUris, [streamFor(a, 1)]);
    expect(backend.playCalls, 0);
    backend.loadCompleter = null;
    nativeGate.complete(const Duration(minutes: 3));
    await Future.wait([first, replacement]);
    expect(backend.loadedUris, [streamFor(a, 1), streamFor(b, 2)]);
    expect(player.currentSong.value?.id, b.id);
    expect(backend.playCalls, 1);
  });

  test(
    'timer expiry during resolution prevents native loading and playback',
    () async {
      var now = DateTime.utc(2026, 10, 1);
      final timer = bindTimer(() => now);
      final gate = Completer<Uri>();
      resolveAction = (_) => gate.future;
      timer.start(const Duration(seconds: 1));
      final opening = player.playQueue([a, b]);
      await _settle();
      now = now.add(const Duration(seconds: 2));
      gate.complete(streamFor(a, 1));
      await opening;
      await _settle();
      expect(backend.loadedUris, isEmpty);
      expect(backend.playCalls, 0);
      expect(player.currentSong.value?.id, a.id);
      expect(player.queue, hasLength(2));
      expect(player.canPlay, isTrue);
      expect(timer.statusMessage.value, '定时已停止播放');
    },
  );

  test(
    'timer expiry while resolving a restored track retains its saved position',
    () async {
      var now = DateTime.utc(2026, 10, 1);
      final timer = bindTimer(() => now);
      final gate = Completer<Uri>();
      resolveAction = (_) => gate.future;
      await player.restoreQueue(
        [a],
        currentId: a.id,
        position: const Duration(seconds: 42),
      );
      timer.start(const Duration(seconds: 1));
      final starting = player.togglePlayback();
      await _settle();
      now = now.add(const Duration(seconds: 2));
      gate.complete(streamFor(a, 1));
      await starting;
      await _settle();
      expect(player.position.value, const Duration(seconds: 42));
      expect(player.canPlay, isTrue);
      expect(backend.loadedUris, isEmpty);
    },
  );

  test(
    'resolver failure is shown safely and never automatically retried',
    () async {
      resolveAction = (_) async =>
          throw const PlaybackSourceException('音乐源授权失效，请重新配置。');
      await player.open(a);
      expect(resolves, 1);
      expect(backend.loadedUris, isEmpty);
      expect(player.errorMessage.value, '音乐源授权失效，请重新配置。');
      resolveAction = (_) async => throw StateError(
        'https://secret.invalid/?token=private-response-body',
      );
      await player.open(a);
      expect(resolves, 2);
      expect(
        player.errorMessage.value,
        isNot(contains('private-response-body')),
      );
      expect(player.errorMessage.value, isNot(contains('secret.invalid')));
    },
  );

  test(
    'unsupported schemes and URL userinfo never reach the decoder',
    () async {
      for (final value in [
        'file:///D:/audio.mp3',
        'https://user:password@host/audio',
        'data:audio/wav,abc',
        'http:relative',
      ]) {
        resolveAction = (_) async => Uri.parse(value);
        await player.open(a);
        expect(player.canPlay, isFalse);
        expect(player.errorMessage.value, isNot(contains('password')));
      }
      expect(backend.loadedUris, isEmpty);
      expect(resolves, 4);
    },
  );

  test('native load failure re-resolves once and can recover', () async {
    backend.failuresRemaining = 1;
    await player.open(a);
    expect(resolves, 2);
    expect(backend.loadedUris, [streamFor(a, 1), streamFor(a, 2)]);
    expect(player.isPlaying.value, isTrue);
    expect(player.errorMessage.value, isNull);
  });

  test(
    'native error stream during failed load still permits one controlled retry',
    () async {
      backend.failuresRemaining = 1;
      backend.emitFailure = true;
      await player.open(a);
      expect(resolves, 2);
      expect(backend.loadedUris, hasLength(2));
      expect(player.isPlaying.value, isTrue);
      expect(player.errorMessage.value, isNull);
    },
  );

  test(
    'native failures stop at two loads when automatic skipping is disabled',
    () async {
      player.skipOnError.value = false;
      backend.failuresRemaining = 10;
      await player.playQueue([a, b]);
      expect(resolves, 2);
      expect(backend.loadedUris, hasLength(2));
      expect(player.currentSong.value?.id, a.id);
      expect(player.isPlaying.value, isFalse);
      expect(player.errorMessage.value, isNot(contains('ephemeral')));
    },
  );

  test('a failed retry resolution does not trigger a third attempt', () async {
    backend.failuresRemaining = 1;
    resolveAction = (song) async {
      if (resolves == 2) throw const PlaybackSourceException('无法解析新的播放地址。');
      return streamFor(song, resolves);
    };
    await player.open(a);
    expect(resolves, 2);
    expect(backend.loadedUris, hasLength(1));
    expect(player.errorMessage.value, '无法解析新的播放地址。');
  });

  test(
    'an all-failing online queue terminates after at most two loads per song',
    () async {
      backend.failuresRemaining = 100;
      await player.playQueue([a, b]);
      await _settle();
      expect(resolves, 4);
      expect(backend.loadedUris, hasLength(4));
      expect(backend.playCalls, 0);
      expect(player.isLoading.value, isFalse);
      expect(player.canPlay, isFalse);
    },
  );

  test(
    'runtime errors skip to the next song without refreshing the failed song',
    () async {
      await player.playQueue([a, b]);
      backend.emitError(StateError('Native runtime error'));
      await _settle();
      expect(resolves, 2);
      expect(backend.loadedUris, [streamFor(a, 1), streamFor(b, 2)]);
    },
  );

  test(
    'end-of-track stop policy takes priority over native load retry',
    () async {
      final timer = bindTimer(() => DateTime.utc(2026, 10, 1));
      await player.restoreQueue([a, b], currentId: a.id);
      timer.startEndOfTrack(a.id);
      backend.failuresRemaining = 2;
      await player.togglePlayback();
      await _settle();
      expect(resolves, 1);
      expect(backend.loadedUris, hasLength(1));
      expect(backend.playCalls, 0);
      expect(player.currentSong.value?.id, a.id);
      expect(timer.isActive, isFalse);
    },
  );

  test('timer during retry resolution prevents another native load', () async {
    var now = DateTime.utc(2026, 10, 1);
    final timer = bindTimer(() => now);
    final gate = Completer<Uri>();
    backend.failuresRemaining = 1;
    resolveAction = (song) =>
        resolves == 2 ? gate.future : Future.value(streamFor(song, resolves));
    timer.start(const Duration(seconds: 1));
    final opening = player.playQueue([a, b]);
    await _settle();
    expect(resolves, 2);
    now = now.add(const Duration(seconds: 2));
    gate.complete(streamFor(a, 2));
    await opening;
    await _settle();
    expect(backend.loadedUris, hasLength(1));
    expect(backend.playCalls, 0);
    expect(player.currentSong.value?.id, a.id);
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

class _OnlineBackend extends FakeAudioBackend {
  int failuresRemaining = 0;
  bool emitFailure = false;

  @override
  Future<Duration?> load(Uri uri) async {
    if (failuresRemaining > 0) {
      failuresRemaining--;
      calls.add('load');
      loadedUris.add(uri);
      final error = StateError('Native failure: $uri private-response-body');
      if (emitFailure) emitError(error);
      throw error;
    }
    return super.load(uri);
  }
}
