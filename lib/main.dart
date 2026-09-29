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
import 'app/data/repositories/online_music_repository.dart';
import 'app/data/repositories/online_source_store.dart';
import 'app/data/sources/just_audio_backend.dart';
import 'app/data/sources/windows_power_events.dart';
import 'app/routes/app_pages.dart';
import 'app/services/app_persistence_service.dart';
import 'app/services/library_service.dart';
import 'app/services/online_music_service.dart';
import 'app/services/player_service.dart';
import 'app/services/sleep_timer_coordinator.dart';
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
  final online = OnlineMusicService(
    repository: OnlineMusicRepository(),
    store: FileOnlineSourceStore(
      Directory(path.join(dataDirectory.path, 'online')),
    ),
  );
  await online.initialize();
  Get.put(online, permanent: true);
  final player = Get.put(
    PlayerService(JustAudioBackend(), resolver: online.resolveForPlayback),
    permanent: true,
  );
  final indexed = {for (final song in library.songs) song.id: song};
  final restoredQueue = <Song>[];
  for (final song in snapshot.queue) {
    if (song.isOnline) {
      restoredQueue.add(song);
      continue;
    }
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
  final timer = Get.put(
    TimerService(onExpired: player.pauseForSleepTimer),
    permanent: true,
  );
  Get.put(SleepTimerCoordinator(player: player, timer: timer), permanent: true);
  runApp(const HanMusicApp());
}

class HanMusicApp extends StatefulWidget {
  const HanMusicApp({super.key});

  @override
  State<HanMusicApp> createState() => _HanMusicAppState();
}

class _HanMusicAppState extends State<HanMusicApp> with WidgetsBindingObserver {
  Future<void>? _shutdownTask;
  WindowsPowerEvents? _powerEvents;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) {
      _powerEvents = WindowsPowerEvents(
        onResume: Get.find<TimerService>().checkDeadline,
      )..start();
    }
  }

  Future<void> _shutdown() => _shutdownTask ??= _closeServices();

  Future<void> _closeServices() async {
    Get.find<LibraryService>().cancelImport();
    _powerEvents?.dispose();
    Get.find<SleepTimerCoordinator>().onClose();
    Get.find<TimerService>().onClose();
    await Get.find<PlayerService>().pause();
    await Get.find<AppPersistenceService>().close();
    await Get.find<PlayerService>().shutdown();
    await Get.find<OnlineMusicService>().close();
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
