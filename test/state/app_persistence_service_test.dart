import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/data/repositories/app_state_store.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:han_music/app/services/app_persistence_service.dart';
import 'package:han_music/app/services/library_service.dart';
import 'package:han_music/app/services/player_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibraryService library;
  late PlayerService player;
  late FakeAudioBackend backend;
  late _MemoryStore store;
  late AppPersistenceService persistence;
  late List<String> errors;
  final song = Song(
    uri: Uri.file('D:/test-song.flac', windows: true),
    fileName: 'test-song.flac',
  );

  setUp(() {
    library = LibraryService(
      repository: LocalLibraryRepository(
        artworkDirectory: Directory(
          '${Directory.systemTemp.path}/unused-cover',
        ),
      ),
    );
    backend = FakeAudioBackend();
    player = PlayerService(backend);
    store = _MemoryStore();
    errors = [];
    persistence = AppPersistenceService(
      store: store,
      library: library,
      player: player,
      onError: errors.add,
    )..start();
  });
  tearDown(() async {
    store.gate?.complete();
    store.gate = null;
    await persistence.close();
    library.onClose();
    await player.shutdown();
  });

  test('coalesces a burst of library edits and syncs queue metadata', () async {
    await player.restoreQueue([song]);
    for (var i = 0; i < 100; i++) {
      library.replaceAll([song.copyWith(trackTitle: 'Title $i')]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 850));
    expect(store.saved, hasLength(1));
    expect(store.saved.single.songs.single.title, 'Title 99');
    expect(store.saved.single.queue.single.title, 'Title 99');
  });

  test(
    'closing awaits final persistence and keeps the latest paused position',
    () async {
      library.replaceAll([song]);
      await player.open(song);
      backend.emitPosition(const Duration(seconds: 32));
      await player.pause();
      store.gate = Completer<void>();
      var closed = false;
      final closing = persistence.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(store.saved.single.position, const Duration(seconds: 32));
      store.gate!.complete();
      store.gate = null;
      await closing;
      expect(closed, isTrue);
      player.volume.value = .2;
      await Future<void>.delayed(Duration.zero);
      expect(store.saved, hasLength(1));
    },
  );

  test(
    'save failure is reported without stopping playback and retry succeeds',
    () async {
      await player.open(song);
      store.failure = true;
      await persistence.flush();
      expect(errors.single, contains('保存失败'));
      expect(player.isPlaying.value, isTrue);
      store.failure = false;
      await persistence.flush();
      expect(store.saved.last.currentId, song.id);
      expect(player.isPlaying.value, isTrue);
    },
  );
}

class _MemoryStore implements AppStateStore {
  final saved = <AppSnapshot>[];
  bool failure = false;
  Completer<void>? gate;
  @override
  String? get warning => null;
  @override
  Future<AppSnapshot> load() async => const AppSnapshot();
  @override
  Future<void> save(AppSnapshot snapshot) async {
    if (failure) throw const FileSystemException('Synthetic disk failure');
    saved.add(snapshot);
    if (gate case final pending?) await pending.future;
  }
}
