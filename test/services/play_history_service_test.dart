import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/play_history_entry.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/services/play_history_service.dart';
import 'package:han_music/app/services/player_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  late FakeAudioBackend backend;
  late PlayerService player;
  late PlayHistoryService history;
  late Duration tick;
  late DateTime now;
  final a = _song('a');
  final b = _song('b');

  void advance(Duration elapsed, {Duration? position}) {
    tick += elapsed;
    now = now.add(elapsed);
    backend.emitPosition(position ?? player.position.value + elapsed);
  }

  void seconds(int value, {int? position}) => advance(
    Duration(seconds: value),
    position: position == null ? null : Duration(seconds: position),
  );

  PlayHistoryEntry entry(Song song, {int count = 1, DateTime? at}) =>
      PlayHistoryEntry(song: song, lastPlayedAt: at ?? now, playCount: count);

  setUp(() {
    backend = FakeAudioBackend();
    player = PlayerService(backend)..skipOnError.value = false;
    tick = Duration.zero;
    now = DateTime.utc(2026, 10, 29);
    history = PlayHistoryService(
      player,
      monotonicNow: () => tick,
      now: () => now,
    )..start();
  });
  tearDown(() async {
    history.onClose();
    await player.shutdown();
  });

  test(
    'records exactly at ten observed seconds, once per selection and start is idempotent',
    () async {
      history.start();
      await player.open(a);
      seconds(9);
      expect(history.entries, isEmpty);
      advance(const Duration(milliseconds: 999));
      expect(history.entries, isEmpty);
      advance(const Duration(milliseconds: 1));
      expect(history.entries.single.song.id, a.id);
      expect(history.entries.single.playCount, 1);
      expect(history.entries.single.lastPlayedAt, now);
      seconds(30);
      expect(history.entries.single.playCount, 1);
    },
  );

  test(
    'duplicate native states and metadata updates do not discard listening intervals',
    () async {
      await player.open(a);
      for (var second = 0; second < 10; second++) {
        tick += const Duration(milliseconds: 500);
        now = now.add(const Duration(milliseconds: 500));
        backend.emitState(playing: true);
        player.updateSongs([a.copyWith(trackTitle: '标题 $second')]);
        advance(
          const Duration(milliseconds: 500),
          position: Duration(seconds: second + 1),
        );
      }
      expect(history.entries.single.playCount, 1);
      expect(history.entries.single.song.title, '标题 9');
    },
  );

  test(
    'time without forward audio progress and a backwards clock do not count',
    () async {
      await player.open(a);
      seconds(60, position: 0);
      expect(history.entries, isEmpty);
      seconds(9);
      expect(history.entries, isEmpty);
      tick -= const Duration(seconds: 30);
      backend.emitPosition(const Duration(seconds: 10));
      expect(history.entries, isEmpty);
      seconds(1);
      expect(history.entries.single.song.id, a.id);
    },
  );

  test(
    'paused time and paused position updates cannot complete the threshold',
    () async {
      await player.open(a);
      seconds(5);
      await player.pause();
      seconds(60, position: 45);
      expect(history.entries, isEmpty);
      await player.togglePlayback();
      seconds(4);
      expect(history.entries, isEmpty);
      seconds(1);
      expect(history.entries.single.song.id, a.id);
    },
  );

  test(
    'native buffering does not count even when the backend reports playing',
    () async {
      await player.open(a);
      seconds(4);
      backend.emitState(playing: true, loading: true);
      seconds(20, position: 24);
      expect(history.entries, isEmpty);
      backend.emitState(playing: true);
      seconds(5);
      expect(history.entries, isEmpty);
      seconds(1);
      expect(history.entries.single.song.id, a.id);
    },
  );

  test(
    'explicit seek and unannounced forward/backward discontinuities do not add time',
    () async {
      await player.open(a);
      seconds(6);
      await player.seek(const Duration(seconds: 100));
      seconds(1, position: 170);
      seconds(1, position: 20);
      seconds(3);
      expect(history.entries, isEmpty);
      seconds(1);
      expect(history.entries.single.song.id, a.id);
    },
  );

  test(
    'overlapping seeks retain the newer pending marker until it settles',
    () async {
      await player.open(a);
      seconds(5);
      final olderGate = Completer<void>();
      final newerGate = Completer<void>();
      backend.seekCompleter = olderGate;
      final older = player.seek(const Duration(seconds: 20));
      backend.seekCompleter = newerGate;
      final newer = player.seek(const Duration(seconds: 40));
      expect(player.canObservePlaybackPosition, isFalse);
      olderGate.complete();
      await older;
      expect(player.canObservePlaybackPosition, isFalse);
      seconds(20, position: 40);
      expect(history.entries, isEmpty);
      newerGate.complete();
      await newer;
      expect(player.canObservePlaybackPosition, isTrue);
      seconds(4);
      expect(history.entries, isEmpty);
      seconds(1);
      expect(history.entries.single.playCount, 1);
    },
  );

  test(
    'restored positions and native loading cannot count as playback',
    () async {
      await player.restoreQueue(
        [a],
        currentId: a.id,
        position: const Duration(seconds: 80),
      );
      seconds(60, position: 100);
      expect(history.entries, isEmpty);
      backend.loadCompleter = Completer<Duration?>();
      final loading = player.togglePlayback();
      await Future<void>.delayed(Duration.zero);
      seconds(60, position: 150);
      expect(history.entries, isEmpty);
      backend.loadCompleter!.complete(const Duration(minutes: 3));
      await loading;
      seconds(9);
      expect(history.entries, isEmpty);
      seconds(1);
      expect(history.entries.single.song.id, a.id);
    },
  );

  test(
    'completion position synthesis and decoder failure never finish a short listen',
    () async {
      await player.open(a);
      seconds(9);
      backend.emitState(playing: false, completed: true);
      expect(player.position.value, const Duration(minutes: 3));
      expect(history.entries, isEmpty);
      await player.playQueue([b]);
      seconds(5);
      backend.emitError(StateError('corrupt stream'));
      seconds(60, position: 120);
      expect(history.entries, isEmpty);
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'switching resets partial time and selecting a song again increments its count',
    () async {
      await player.playQueue([a, b]);
      seconds(9);
      await player.playAt(1);
      seconds(9);
      expect(history.entries, isEmpty);
      seconds(1);
      expect(history.entries.single.song.id, b.id);
      await player.playAt(0);
      seconds(10);
      expect(history.entries.map((e) => e.song.id), [a.id, b.id]);
      await player.playAt(1);
      seconds(10);
      expect(history.entries.map((e) => e.song.id), [b.id, a.id]);
      expect(history.entries.first.playCount, 2);
      expect(history.entries.first.lastPlayedAt, now);
    },
  );

  test(
    'same-selection EOF restart does not record a selection twice',
    () async {
      await player.open(a);
      seconds(10);
      backend.emitState(playing: false, completed: true);
      await Future<void>.delayed(Duration.zero);
      await player.togglePlayback();
      seconds(10);
      expect(history.entries.single.playCount, 1);
    },
  );

  test(
    'clear and removing current song suppress its remaining playback until reselection',
    () async {
      await player.open(a);
      seconds(5);
      history.clear();
      seconds(20);
      expect(history.entries, isEmpty);
      await player.playQueue([a]);
      seconds(10);
      history.remove(a.id);
      seconds(20);
      expect(history.entries, isEmpty);
      await player.playQueue([a]);
      seconds(10);
      expect(history.entries.single.playCount, 1);
      history.clear();
      seconds(20);
      expect(history.entries, isEmpty);
    },
  );

  test(
    'restore sorts, deduplicates and caps history; new recordings keep only 200',
    () async {
      final older = now.subtract(const Duration(days: 1));
      history.restore([
        for (var i = 0; i < 205; i++)
          entry(_song('$i'), at: older.add(Duration(seconds: i))),
        entry(_song('204'), count: 7, at: now),
      ]);
      expect(history.entries, hasLength(200));
      expect(history.entries.first.song.id, _song('204').id);
      expect(history.entries.first.playCount, 7);
      expect(history.entries.last.song.id, _song('5').id);
      await player.open(a);
      seconds(10);
      expect(history.entries, hasLength(200));
      expect(history.entries.first.song.id, a.id);
      expect(history.entries.last.song.id, _song('6').id);
    },
  );

  test(
    'recording and metadata updates use current snapshots without changing count or time',
    () async {
      await player.open(a);
      seconds(9);
      player.updateSongs([a.copyWith(trackTitle: '新标题')]);
      seconds(1);
      expect(history.entries.single.song.title, '新标题');
      final saved = history.entries.single;
      history.updateSongs([a.copyWith(artist: '新歌手', isMissing: true)]);
      expect(history.entries.single.song.artist, '新歌手');
      expect(history.entries.single.song.isMissing, isTrue);
      expect(history.entries.single.lastPlayedAt, saved.lastPlayedAt);
      expect(history.entries.single.playCount, saved.playCount);
      history.updateSongs([]);
      expect(history.entries, hasLength(1));
    },
  );

  test(
    'online entries retain stable identities without persisting the resolved URL',
    () async {
      history.onClose();
      await player.shutdown();
      backend = FakeAudioBackend();
      player = PlayerService(
        backend,
        resolver: (_) async =>
            Uri.parse('https://example.invalid/audio?secret=token'),
      );
      history = PlayHistoryService(
        player,
        monotonicNow: () => tick,
        now: () => now,
      )..start();
      final online = Song.online(
        sourceId: 'source',
        trackId: 'track',
        title: '在线',
      );
      await player.open(online);
      seconds(10);
      final saved = history.entries.single;
      expect(saved.song.id, online.id);
      expect(saved.toJson().toString(), isNot(contains('secret')));
    },
  );

  test(
    'closing cancels observation and all later mutations are no-ops',
    () async {
      await player.open(a);
      seconds(9);
      history.onClose();
      seconds(10);
      history.start();
      history.restore([entry(b)]);
      history.clear();
      history.remove(b.id);
      history.updateSongs([a]);
      await history.refreshMissing([]);
      expect(history.entries, isEmpty);
    },
  );

  test(
    'missing refresh checks history-only files and preserves online records and ordering',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hanmusic-history-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final existing = await File(
        '${directory.path}/exists.mp3',
      ).writeAsBytes([1]);
      final absent = File('${directory.path}/absent.mp3');
      final live = Song(
        uri: existing.uri,
        fileName: 'exists.mp3',
        isMissing: true,
      );
      final missing = Song(uri: absent.uri, fileName: 'absent.mp3');
      final online = Song.online(sourceId: 's', trackId: 't', title: '在线');
      history.restore([entry(live), entry(missing), entry(online), entry(a)]);
      await history.refreshMissing([a.copyWith(isMissing: true)]);
      expect(history.entries.map((e) => e.song.id), [
        live.id,
        missing.id,
        online.id,
        a.id,
      ]);
      expect(history.entries.map((e) => e.song.isMissing), [
        false,
        true,
        false,
        true,
      ]);
      expect(
        history.entries.every((e) => e.lastPlayedAt == now && e.playCount == 1),
        isTrue,
      );
      expect(await existing.exists(), isTrue);
    },
  );

  test(
    'metadata refresh does not cancel independent file checks or overwrite newer indexed status',
    () async {
      history.onClose();
      final gate = Completer<bool>();
      history = PlayHistoryService(player, fileExists: (_) => gate.future);
      history.restore([entry(a), entry(b)]);
      final refreshing = history.refreshMissing([b.copyWith(isMissing: true)]);
      history.updateSongs([b.copyWith(trackTitle: '最新', isMissing: false)]);
      gate.complete(false);
      await refreshing;
      expect(history.entries.first.song.isMissing, isTrue);
      expect(history.entries.last.song.title, '最新');
      expect(history.entries.last.song.isMissing, isFalse);
    },
  );

  test(
    'file-check failure marks missing, and close or restore discards late results',
    () async {
      history.onClose();
      history = PlayHistoryService(
        player,
        fileExists: (_) async => throw const FileSystemException('denied'),
      );
      history.restore([entry(a)]);
      await history.refreshMissing([]);
      expect(history.entries.single.song.isMissing, isTrue);
      history.onClose();
      final gate = Completer<bool>();
      history = PlayHistoryService(player, fileExists: (_) => gate.future);
      history.restore([entry(a)]);
      final old = history.refreshMissing([]);
      history.restore([entry(b)]);
      history.onClose();
      gate.complete(false);
      await old;
      expect(history.entries.single.song.id, b.id);
      expect(history.entries.single.song.isMissing, isFalse);
    },
  );
}

Song _song(String id) =>
    Song(uri: Uri.file('D:/music/$id.mp3', windows: true), fileName: '$id.mp3');
