import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/library_sort.dart';
import 'package:han_music/app/data/models/play_mode.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAudioBackend backend;
  late PlayerService player;
  late TimerService timer;
  late LibraryService library;
  late PlayerController controller;

  setUp(() {
    backend = FakeAudioBackend();
    player = PlayerService(backend);
    timer = TimerService(onExpired: player.pause);
    library = LibraryService(
      repository: LocalLibraryRepository(
        artworkDirectory: Directory.systemTemp,
      ),
    );
    controller = PlayerController(
      player: player,
      timer: timer,
      picker: _NoSongPicker(),
      library: library,
    );
    controller.onStart();
  });

  tearDown(() async {
    controller.onDelete();
    library.onClose();
    timer.onClose();
    await player.shutdown();
  });

  test(
    'sorting changes only the view and preserves ties in either direction',
    () async {
      final z = _song('z', title: 'Zulu');
      final a1 = _song('a1', title: ' Alpha ');
      final a2 = _song('a2', title: 'alpha');
      library.replaceAll([z, a1, a2]);
      await player.playQueue([z, a2]);
      await player.seek(const Duration(seconds: 22));
      final revision = player.selectionRevision;
      final calls = backend.calls.toList();

      controller.setLibrarySort(LibrarySort.title);
      expect(controller.visibleSongs, [a1, a2, z]);
      controller.toggleLibrarySortDirection();
      expect(controller.visibleSongs, [z, a1, a2]);
      expect(library.songs, [z, a1, a2]);
      expect(player.queue, [z, a2]);
      expect(player.currentSong.value, z);
      expect(player.position.value, const Duration(seconds: 22));
      expect(player.isPlaying.value, isTrue);
      expect(player.selectionRevision, revision);
      expect(backend.calls, calls);
    },
  );

  for (final sort in [LibrarySort.artist, LibrarySort.album]) {
    test('${sort.name} keeps blank metadata last and equal values stable', () {
      final missing = _song('missing');
      final empty = _song('empty', artist: '  ', album: '  ');
      final z = _song('z', artist: 'Zulu', album: 'Zulu');
      final a1 = _song('a1', artist: ' Alpha ', album: ' Alpha ');
      final a2 = _song('a2', artist: 'alpha', album: 'alpha');
      library.replaceAll([missing, z, empty, a1, a2]);

      controller.setLibrarySort(sort);
      expect(controller.visibleSongs, [a1, a2, z, missing, empty]);
      controller.toggleLibrarySortDirection();
      expect(controller.visibleSongs, [z, a1, a2, missing, empty]);
    });
  }

  test('import order can show recent imports first within search results', () {
    final first = _song('first', album: 'Match');
    final excluded = _song('excluded', album: 'Else');
    final last = _song('last', album: 'Match');
    library.replaceAll([first, excluded, last]);
    controller.setSearchQuery('match');

    expect(controller.visibleSongs, [first, last]);
    controller.toggleLibrarySortDirection();
    expect(controller.visibleSongs, [last, first]);
    controller.setSearchQuery('else');
    expect(controller.visibleSongs, [excluded]);
    expect(library.songs, [first, excluded, last]);
  });

  for (final mode in PlayMode.values) {
    test(
      'play visible songs uses fresh filtered order and preserves $mode',
      () async {
        final z = _song('z', title: 'Zulu', album: 'Match');
        final a = _song('a', title: 'Alpha', album: 'Match');
        final missing = _song('missing', album: 'Match', missing: true);
        final excluded = _song('excluded');
        library.replaceAll([z, missing, excluded, a]);
        await player.playQueue([excluded]);
        player.playMode.value = mode;
        controller.setSearchQuery('match');
        controller.setLibrarySort(LibrarySort.title);

        await controller.playVisibleSongs();

        expect(player.queue, [a, z]);
        expect(player.currentSong.value, a);
        expect(player.isPlaying.value, isTrue);
        expect(player.playMode.value, mode);
        expect(backend.loadedUris, [excluded.uri, a.uri]);
      },
    );
  }

  test(
    'empty and wholly missing results preserve playback and queue',
    () async {
      final current = _song('current');
      final missing = _song('missing', missing: true);
      library.replaceAll([current, missing]);
      await player.playQueue([current]);
      await player.seek(const Duration(seconds: 15));
      final calls = backend.calls.toList();
      final revision = player.selectionRevision;

      controller.setSearchQuery('absent');
      await controller.playVisibleSongs();
      expect(controller.addVisibleSongsToQueue(), (
        added: 0,
        existing: 0,
        unavailable: 0,
      ));
      controller.setSearchQuery('missing');
      await controller.playVisibleSongs();
      expect(controller.addVisibleSongsToQueue(), (
        added: 0,
        existing: 0,
        unavailable: 1,
      ));

      expect(player.queue, [current]);
      expect(player.currentSong.value, current);
      expect(player.isPlaying.value, isTrue);
      expect(player.position.value, const Duration(seconds: 15));
      expect(player.selectionRevision, revision);
      expect(backend.calls, calls);
    },
  );

  test(
    'batch enqueue uses fresh results, counts duplicates and keeps playback',
    () async {
      final current = _song('current');
      final z = _song('z', title: 'Zulu', album: 'Match');
      final a = _song('a', title: 'Alpha', album: 'Match');
      final missing = _song('missing', album: 'Match', missing: true);
      final excluded = _song('excluded');
      library.replaceAll([z, missing, excluded, a]);
      await player.playQueue([current, z]);
      await player.seek(const Duration(seconds: 24));
      player.playMode.value = PlayMode.shuffle;
      final revision = player.selectionRevision;
      final calls = backend.calls.toList();
      controller.setSearchQuery('match');
      controller.setLibrarySort(LibrarySort.title);

      expect(controller.addVisibleSongsToQueue(), (
        added: 1,
        existing: 1,
        unavailable: 1,
      ));
      expect(controller.addVisibleSongsToQueue(), (
        added: 0,
        existing: 2,
        unavailable: 1,
      ));
      expect(player.queue, [current, z, a]);
      expect(player.currentSong.value, current);
      expect(player.isPlaying.value, isTrue);
      expect(player.position.value, const Duration(seconds: 24));
      expect(player.playMode.value, PlayMode.shuffle);
      expect(player.selectionRevision, revision);
      expect(backend.calls, calls);

      controller.setSearchQuery('excluded');
      expect(controller.addVisibleSongsToQueue(), (
        added: 1,
        existing: 0,
        unavailable: 0,
      ));
      expect(player.queue, [current, z, a, excluded]);
    },
  );

  test('batch enqueue to empty queue selects first result without playing', () {
    final z = _song('z', title: 'Zulu');
    final a = _song('a', title: 'Alpha');
    library.replaceAll([z, a]);
    controller.setLibrarySort(LibrarySort.title);

    expect(controller.addVisibleSongsToQueue(), (
      added: 2,
      existing: 0,
      unavailable: 0,
    ));
    expect(player.queue, [a, z]);
    expect(player.currentSong.value, a);
    expect(player.isPlaying.value, isFalse);
    expect(backend.loadedUris, isEmpty);
    expect(backend.playCalls, 0);
  });

  test(
    'play visible songs does not replace a selection while it is loading',
    () async {
      final current = _song('current');
      final other = _song('other');
      library.replaceAll([other]);
      final load = backend.loadCompleter = Completer<Duration?>();
      final opening = player.playQueue([current]);
      await Future<void>.delayed(Duration.zero);
      expect(player.isLoading.value, isTrue);
      final revision = player.selectionRevision;

      await controller.playVisibleSongs();
      expect(player.queue, [current]);
      expect(player.selectionRevision, revision);
      load.complete(const Duration(minutes: 3));
      await opening;
      expect(backend.loadedUris, [current.uri]);
    },
  );

  test(
    'exit and closed controllers reject commands; canceled exit recovers',
    () async {
      final first = _song('first');
      final second = _song('second');
      library.replaceAll([first, second]);
      await player.playQueue([first]);
      final calls = backend.calls.toList();
      expect(controller.acceptsPlaybackCommands, isTrue);

      controller.beginExit();
      expect(controller.acceptsPlaybackCommands, isFalse);
      await controller.playVisibleSongs();
      expect(controller.addVisibleSongsToQueue(), (
        added: 0,
        existing: 0,
        unavailable: 0,
      ));
      expect(player.queue, [first]);
      expect(backend.calls, calls);

      controller.cancelExit();
      expect(controller.acceptsPlaybackCommands, isTrue);
      await controller.playVisibleSongs();
      expect(player.queue, [first, second]);
      final resumedCalls = backend.calls.toList();
      controller.onDelete();
      controller.cancelExit();
      expect(controller.acceptsPlaybackCommands, isFalse);
      await controller.playVisibleSongs();
      expect(controller.addVisibleSongsToQueue(), (
        added: 0,
        existing: 0,
        unavailable: 0,
      ));
      expect(backend.calls, resumedCalls);
    },
  );

  test('unavailable player reports all matching songs unavailable', () async {
    library.replaceAll([_song('available'), _song('missing', missing: true)]);
    await player.shutdown();

    expect(controller.addVisibleSongsToQueue(), (
      added: 0,
      existing: 0,
      unavailable: 2,
    ));
    expect(player.queue, isEmpty);
  });
}

Song _song(
  String name, {
  String? title,
  String? artist,
  String? album,
  bool missing = false,
}) => Song(
  uri: Uri.file('D:/music/$name.mp3', windows: true),
  fileName: '$name.mp3',
  trackTitle: title,
  artist: artist,
  album: album,
  isMissing: missing,
);

class _NoSongPicker implements SongPicker {
  @override
  Future<Song?> pick() async => null;
}
