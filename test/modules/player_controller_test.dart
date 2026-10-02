import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/models/queue_add_result.dart';
import 'package:han_music/app/data/models/sleep_timer_mode.dart';
import 'package:han_music/app/data/repositories/local_song_picker.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/modules/player/controller.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';
import 'package:han_music/app/services/sleep_timer_coordinator.dart';

import '../support/fake_audio_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAudioBackend backend;
  late PlayerService player;
  late TimerService timer;
  late _FakeSongPicker picker;
  late PlayerController controller;
  late SleepTimerCoordinator coordinator;
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
    coordinator = SleepTimerCoordinator(player: player, timer: timer);
    picker = _FakeSongPicker();
    controller = PlayerController(player: player, timer: timer, picker: picker);
    controller.onStart();
  });

  tearDown(() async {
    controller.onDelete();
    coordinator.dispose();
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

  test('end-of-track timer is only available for a ready valid song', () async {
    expect(controller.canStopAfterCurrentSong, isFalse);
    controller.startSleepTimerAfterCurrentSong();
    expect(timer.mode.value, SleepTimerMode.off);
    await player.open(song);
    expect(controller.canStopAfterCurrentSong, isTrue);
    controller.startSleepTimerAfterCurrentSong();
    expect(timer.currentSongId.value, song.id);
    expect(controller.timerRemaining.value, isNull);
    expect(controller.extendSleepTimer(), isFalse);
    await controller.togglePlayback();
    await controller.seek(const Duration(seconds: 30));
    expect(timer.mode.value, SleepTimerMode.endOfTrack);
    await controller.togglePlayback();
    expect(timer.mode.value, SleepTimerMode.endOfTrack);
    backend.loadFailure = StateError('Corrupt audio');
    await player.open(
      song.copyWith(uri: Uri.file(r'D:\music\损坏.mp3', windows: true)),
    );
    expect(controller.canStopAfterCurrentSong, isFalse);
    controller.startSleepTimerAfterCurrentSong();
    expect(timer.mode.value, SleepTimerMode.off);
  });

  test(
    'extension uses the original deadline and mode replacement clears old state',
    () async {
      await player.open(song);
      controller.startSleepTimer(const Duration(minutes: 90));
      final originalDeadline = timer.deadline.value!;
      now = now.add(const Duration(minutes: 13));
      expect(controller.extendSleepTimer(), isTrue);
      expect(
        timer.deadline.value,
        originalDeadline.add(const Duration(minutes: 10)),
      );
      expect(timer.remaining.value, const Duration(minutes: 87));
      controller.startSleepTimerAfterCurrentSong();
      expect(timer.mode.value, SleepTimerMode.endOfTrack);
      expect(timer.deadline.value, isNull);
      expect(timer.remaining.value, isNull);
      controller.startSleepTimer(const Duration(minutes: 15));
      expect(timer.mode.value, SleepTimerMode.countdown);
      expect(timer.currentSongId.value, isNull);
      now = now.add(const Duration(minutes: 16));
      expect(controller.extendSleepTimer(), isFalse);
      await _flushCallbacks();
      expect(timer.mode.value, SleepTimerMode.off);
      expect(player.isPlaying.value, isFalse);
    },
  );

  test(
    'manual controller track selection cancels an end-of-track task',
    () async {
      final nextSong = song.copyWith(
        uri: Uri.file(r'D:\music\下一首.mp3', windows: true),
      );
      await player.playQueue([song, nextSong]);
      controller.startSleepTimerAfterCurrentSong();
      await controller.next();
      expect(timer.mode.value, SleepTimerMode.off);
      expect(player.currentSong.value!.id, nextSong.id);
      controller.startSleepTimerAfterCurrentSong();
      await controller.removeFromQueue(nextSong.id);
      expect(timer.mode.value, SleepTimerMode.off);
      expect(player.queue, hasLength(1));
    },
  );

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
    expect(controller.canStopAfterCurrentSong, isFalse);
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

  for (final entry in ['single', 'files', 'directory']) {
    test(
      'exit gates $entry picker and ignores its late error after cancel',
      () async {
        final library = _FakeLibrary();
        final libraryPicker = _FakeLibraryPicker();
        final pending = Completer<void>();
        if (entry != 'single') {
          controller.onDelete();
          controller = PlayerController(
            player: player,
            timer: timer,
            picker: picker,
            library: library,
            libraryPicker: libraryPicker,
          )..onStart();
        }
        picker.pickAction = () async {
          await pending.future;
          return song;
        };
        libraryPicker.filesAction = () async {
          await pending.future;
          return [song.path];
        };
        libraryPicker.directoryAction = () async {
          await pending.future;
          return r'D:\music';
        };
        Future<void> import() => entry == 'directory'
            ? controller.importDirectory()
            : controller.importFile();
        int calls() =>
            picker.calls +
            libraryPicker.fileCalls +
            libraryPicker.directoryCalls;
        try {
          controller.beginExit();
          await import();
          expect(calls(), 0);
          controller.cancelExit();
          final importing = import();
          expect(calls(), 1);
          controller.beginExit();
          controller.cancelExit();
          await import();
          expect(calls(), 1);
          expect(controller.isImporting.value, isTrue);
          controller.errorMessage.value = '保留当前退出错误提示';
          pending.completeError(StateError('obsolete picker failure'));
          await importing;
          expect(controller.errorMessage.value, '保留当前退出错误提示');
          expect(controller.isImporting.value, isFalse);
          expect(library.received, isEmpty);
          expect(backend.loadedUris, isEmpty);
        } finally {
          if (!pending.isCompleted) pending.complete();
          library.onClose();
        }
      },
    );
  }

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
  test(
    'cancelled blocked scan releases controller busy for another import',
    () async {
      controller.onDelete();
      final repository = _BlockedScanRepository();
      final library = LibraryService(repository: repository);
      final libraryPicker = _FakeLibraryPicker()..directory = r'D:\music';
      controller = PlayerController(
        player: player,
        timer: timer,
        picker: picker,
        library: library,
        libraryPicker: libraryPicker,
      )..onStart();
      final importing = controller.importDirectory();
      try {
        await repository.started.future;
        expect(controller.libraryBusy, isTrue);
        await controller.importDirectory();
        expect(repository.calls, 1);
        controller.cancelImport();
        controller.cancelImport();
        await importing.timeout(const Duration(seconds: 1));
        expect(controller.isImporting.value, isFalse);
        expect(controller.isScanning.value, isFalse);
        expect(controller.libraryBusy, isFalse);
        expect(controller.libraryStatus.value, contains('已取消导入'));

        await controller.importDirectory();
        expect(repository.calls, 2);
        final status = controller.libraryStatus.value;
        repository.blocked.complete();
        await repository.finished.future;
        await _flushCallbacks();
        expect(controller.libraryBusy, isFalse);
        expect(controller.libraryStatus.value, status);
      } finally {
        if (!repository.blocked.isCompleted) repository.blocked.complete();
        await importing;
        await repository.finished.future;
        library.onClose();
      }
    },
  );

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
      'clearing queue respects exit and preserves library and countdown',
      () async {
        library.replaceAll([song]);
        await controller.playLibrarySong(song);
        controller.startSleepTimerAfterCurrentSong();
        controller.beginExit();
        await controller.clearQueue();
        expect(player.queue, [song]);
        expect(player.isPlaying.value, isTrue);
        expect(timer.mode.value, SleepTimerMode.endOfTrack);

        controller.cancelExit();
        await controller.clearQueue();
        expect(player.queue, isEmpty);
        expect(player.currentSong.value, isNull);
        expect(player.isPlaying.value, isFalse);
        expect(timer.mode.value, SleepTimerMode.off);
        expect(library.songs, [song]);

        await controller.playLibrarySong(song);
        controller.startSleepTimer(const Duration(minutes: 15));
        final deadline = timer.deadline.value;
        await controller.clearQueue();
        expect(timer.mode.value, SleepTimerMode.countdown);
        expect(timer.deadline.value, deadline);
        expect(library.songs, [song]);
      },
    );

    test('queue additions use current availability and stay paused', () {
      library.replaceAll([song.copyWith(isMissing: true)]);
      expect(controller.addToQueue(song), QueueAddResult.unavailable);
      expect(player.queue, isEmpty);

      library.replaceAll([]);
      expect(controller.addToQueue(song), QueueAddResult.unavailable);
      library.replaceAll([song.copyWith(trackTitle: '更新后的曲名')]);
      controller.beginExit();
      expect(controller.addToQueue(song), QueueAddResult.unavailable);
      expect(player.queue, isEmpty);
      controller.cancelExit();

      expect(controller.addToQueue(song), QueueAddResult.added);
      expect(player.queue.single.title, '更新后的曲名');
      expect(controller.addToQueue(song), QueueAddResult.unchanged);
      expect(player.queue, hasLength(1));
      expect(player.isPlaying.value, isFalse);
      expect(backend.loadedUris, isEmpty);
    });

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

class _BlockedScanRepository extends LocalLibraryRepository {
  _BlockedScanRepository()
    : super(
        artworkDirectory: Directory('D:/dev/tmp/unused-blocked-scan-artwork'),
      );

  final started = Completer<void>();
  final blocked = Completer<void>();
  final finished = Completer<void>();
  int calls = 0;

  @override
  Stream<LibraryScanEntry> scan(
    List<String> paths,
    ImportCancellation cancellation,
  ) async* {
    calls++;
    if (calls != 1) return;
    try {
      started.complete();
      await blocked.future;
      yield const LibraryScanEntry.warning('late scan warning');
    } finally {
      finished.complete();
    }
  }
}

class _FakeLibraryPicker implements LibraryPicker {
  List<String> files = [];
  String? directory;
  int fileCalls = 0;
  int directoryCalls = 0;
  Future<List<String>> Function()? filesAction;
  Future<String?> Function()? directoryAction;
  @override
  Future<List<String>> pickFiles() async {
    fileCalls++;
    return filesAction == null ? files : await filesAction!();
  }

  @override
  Future<String?> pickDirectory() async {
    directoryCalls++;
    return directoryAction == null ? directory : await directoryAction!();
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
