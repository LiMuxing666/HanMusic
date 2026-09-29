import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app/core/theme/app_theme.dart';
import 'app/data/models/song.dart';
import 'app/data/repositories/app_state_store.dart';
import 'app/data/repositories/local_library_repository.dart';
import 'app/data/sources/just_audio_backend.dart';
import 'app/routes/app_pages.dart';
import 'app/services/app_persistence_service.dart';
import 'app/services/library_service.dart';
import 'app/services/player_service.dart';
import 'app/services/timer_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeAudioBackend();
  final configured = Platform.environment['HANMUSIC_DATA_DIR'];
  final dataDirectory = configured != null && path.isAbsolute(configured)
      ? Directory(configured)
      : await getApplicationSupportDirectory();
  final store = FileAppStateStore(dataDirectory);
  final snapshot = await store.load();
  final library = Get.put(
    LibraryService(
      repository: LocalLibraryRepository(
        artworkDirectory: Directory(path.join(dataDirectory.path, 'artwork')),
      ),
    ),
    permanent: true,
  );
  library.replaceAll(snapshot.songs);
  await library.refreshMissing();
  final player = Get.put(PlayerService(JustAudioBackend()), permanent: true);
  final indexed = {for (final song in library.songs) song.id: song};
  final restoredQueue = <Song>[];
  for (final song in snapshot.queue) {
    var restored = indexed[song.id];
    if (restored == null) {
      var missing = true;
      try {
        missing = !await File(song.path).exists();
      } on FileSystemException {
        // Inaccessible queue-only files are kept as unavailable entries.
      }
      restored = song.copyWith(isMissing: missing);
    }
    restoredQueue.add(restored);
  }
  await player.restoreQueue(
    restoredQueue,
    currentId: snapshot.currentId,
    position: snapshot.position,
    mode: snapshot.mode,
    volume: snapshot.volume,
    skipOnError: snapshot.skipOnError,
  );
  player.errorMessage.value = store.warning;
  final persistence = Get.put(
    AppPersistenceService(
      store: store,
      library: library,
      player: player,
      onError: (message) => player.errorMessage.value ??= message,
    ),
    permanent: true,
  );
  persistence.start();
  Get.put(TimerService(onExpired: player.pause), permanent: true);
  runApp(const HanMusicApp());
}

class HanMusicApp extends StatefulWidget {
  const HanMusicApp({super.key});

  @override
  State<HanMusicApp> createState() => _HanMusicAppState();
}

class _HanMusicAppState extends State<HanMusicApp> with WidgetsBindingObserver {
  Future<void>? _shutdownTask;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _shutdown() => _shutdownTask ??= _closeServices();

  Future<void> _closeServices() async {
    Get.find<LibraryService>().cancelImport();
    Get.find<TimerService>().cancel();
    await Get.find<PlayerService>().pause();
    await Get.find<AppPersistenceService>().close();
    await Get.find<PlayerService>().shutdown();
    Get.find<LibraryService>().onClose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _shutdown();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GetMaterialApp(
    title: 'HanMusic',
    debugShowCheckedModeBanner: false,
    theme: HanMusicTheme.light,
    initialRoute: AppPages.player,
    getPages: AppPages.pages,
  );
}
