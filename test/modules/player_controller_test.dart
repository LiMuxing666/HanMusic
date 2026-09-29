import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/services/library_service.dart';
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
  group('library controller orchestration', () {
    late _FakeLibrary library;
    late _FakeLibraryPicker libraryPicker;

    setUp(() {
      controller.onDelete();
      library = _FakeLibrary();
      libraryPicker = _FakeLibraryPicker();
      controller = PlayerController(
        player: player,
        timer: timer,
        picker: picker,
        library: library,
        libraryPicker: libraryPicker,
      );
      controller.onStart();
    });

    tearDown(() => library.onClose());

    test(
      'multi-file import only indexes music without replacing playback',
      () async {
        await player.open(song);
        final imported = song.copyWith(
          uri: Uri.file(r'D:\music\新歌.flac', windows: true),
          fileName: '新歌.flac',
        );
        libraryPicker.files = [imported.path, r'D:\music\另一首.wav'];
        library.imported = [imported];
        await controller.importFile();
        expect(library.received.single, libraryPicker.files);
        expect(library.songs, [imported]);
        expect(player.currentSong.value!.id, song.id);
        expect(backend.loadedUris, [song.uri]);
        expect(picker.calls, 0);
        expect(controller.libraryBusy, isFalse);
      },
    );

    test(
      'cancelled directory selection does not import or change music',
      () async {
        await player.open(song);
        await controller.importDirectory();
        expect(library.received, isEmpty);
        expect(player.currentSong.value, same(song));
        expect(player.isPlaying.value, isTrue);
        expect(controller.libraryBusy, isFalse);
      },
    );

    test(
      'directory import forwards the root and repeated clicks share one picker',
      () async {
        final picked = Completer<List<String>>();
        libraryPicker.filesAction = () => picked.future;
        final pending = controller.importFile();
        await controller.importFile();
        await controller.importDirectory();
        expect(libraryPicker.fileCalls, 1);
        expect(libraryPicker.directoryCalls, 0);
        picked.complete([]);
        await pending;
        libraryPicker.directory = r'D:\music';
        await controller.importDirectory();
        expect(library.received.single, [r'D:\music']);
      },
    );

    test(
      'library selection queues visible matching songs and excludes missing files',
      () async {
        final first = song.copyWith(trackTitle: '钢琴 一');
        final second = song.copyWith(
          uri: Uri.file(r'D:\music\two.mp3', windows: true),
          trackTitle: '钢琴 二',
        );
        final other = song.copyWith(
          uri: Uri.file(r'D:\music\three.mp3', windows: true),
          trackTitle: '吉他',
        );
        final missing = song.copyWith(
          uri: Uri.file(r'D:\music\missing.mp3', windows: true),
          trackTitle: '钢琴 缺失',
          isMissing: true,
        );
        library.replaceAll([first, second, other, missing]);
        controller.setSearchQuery('钢琴');
        await controller.playLibrarySong(second);
        expect(player.queue.map((song) => song.id), [first.id, second.id]);
        expect(player.currentSong.value!.id, second.id);
        final loads = backend.loadedUris.length;
        await controller.playLibrarySong(missing);
        expect(backend.loadedUris, hasLength(loads));
      },
    );

    test(
      'removing an index removes the queue entry and refresh reconciles flags',
      () async {
        final second = song.copyWith(
          uri: Uri.file(r'D:\music\second.mp3', windows: true),
        );
        library.replaceAll([song, second]);
        await controller.playLibrarySong(song);
        await controller.removeFromLibrary(second);
        expect(library.songs.map((song) => song.id), [song.id]);
        expect(player.queue.map((song) => song.id), [song.id]);
        library.markMissingOnRefresh = true;
        await controller.refreshMissing();
        expect(library.refreshCalls, 1);
        expect(player.queue.single.isMissing, isTrue);
        expect(controller.isRefreshing.value, isFalse);
      },
    );

    test(
      'closing the controller ignores a late library picker result',
      () async {
        final picked = Completer<List<String>>();
        libraryPicker.filesAction = () => picked.future;
        final pending = controller.importFile();
        controller.onDelete();
        picked.complete([song.path]);
        await pending;
        expect(library.received, isEmpty);
      },
    );
  });
}

class _FakeLibrary extends LibraryService {
  _FakeLibrary()
    : super(
        repository: LocalLibraryRepository(
          artworkDirectory: Directory(
            r'D:\dev\tmp\hanmusic-controller-artwork',
          ),
        ),
      );
  final received = <List<String>>[];
  List<Song> imported = [];
  int refreshCalls = 0;
  bool markMissingOnRefresh = false;

  @override
  Future<List<Song>> importPaths(List<String> paths) async {
    received.add(List.of(paths));
    songs.addAll(imported);
    return imported;
  }

  @override
  Future<void> refreshMissing() async {
    refreshCalls++;
    if (markMissingOnRefresh) {
      replaceAll(songs.map((song) => song.copyWith(isMissing: true)).toList());
    }
  }
}

class _FakeLibraryPicker implements LibraryPicker {
  List<String> files = [];
  String? directory;
  int fileCalls = 0;
  int directoryCalls = 0;
  Future<List<String>> Function()? filesAction;
  @override
  Future<List<String>> pickFiles() async {
    fileCalls++;
    return filesAction == null ? files : await filesAction!();
  }

  @override
  Future<String?> pickDirectory() async {
    directoryCalls++;
    return directory;
  }
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
