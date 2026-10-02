import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, AppExitType;

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
import 'app/modules/player/controller.dart';
import 'app/modules/startup/startup_failure_app.dart';
import 'app/modules/startup/startup_loading_app.dart';
import 'app/modules/startup/unsaved_exit_dialog.dart';
import 'app/services/app_persistence_service.dart';
import 'app/services/app_shutdown_coordinator.dart';
import 'app/services/data_directory_lock.dart';
import 'app/services/library_service.dart';
import 'app/services/online_music_service.dart';
import 'app/services/player_service.dart';
import 'app/services/sleep_timer_coordinator.dart';
import 'app/services/timer_service.dart';

// Keep the OS handle alive until the process exits. A timed-out async writer
// must not race a new process after an early explicit unlock.
DataDirectoryLock? _processDataLock;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Directory? dataDirectory;
  try {
    runApp(const StartupLoadingApp());
    // The Windows runner shows its window after Flutter's first frame. Do not
    // wait indefinitely when frames are disabled (for example, screen off).
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(milliseconds: 500),
      onTimeout: () {},
    );
    final configured = Platform.environment['HANMUSIC_DATA_DIR'];
    dataDirectory = configured != null && path.isAbsolute(configured)
        ? Directory(configured)
        : await getApplicationSupportDirectory();
    if (Platform.isWindows) {
      _processDataLock = await DataDirectoryLock.acquire(dataDirectory);
      dataDirectory = _processDataLock!.canonicalDirectory;
    }
    await _startHanMusic(dataDirectory);
  } catch (error) {
    // Startup has not presented player controls. Keep any acquired lock until
    // process termination, including while partially initialized writers drain.
    runApp(
      StartupFailureApp(
        message: error is DataDirectoryLockException
            ? error.message
            : '初始化未完成。请关闭应用，检查数据目录和运行依赖后重新启动。',
        dataDirectory: dataDirectory?.path,
        onExit: () {
          unawaited(
            WidgetsBinding.instance.exitApplication(AppExitType.required),
          );
        },
      ),
    );
  }
}

Future<void> _startHanMusic(Directory dataDirectory) async {
  initializeAudioBackend();
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
  late final AppShutdownCoordinator _shutdownCoordinator;
  bool _closing = false;
  bool _confirming = false;
  WindowsPowerEvents? _powerEvents;
  Future<bool>? _sourceSaveOnExit;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) {
      _powerEvents = WindowsPowerEvents(
        onResume: Get.find<TimerService>().checkDeadline,
      )..start();
    }
    _shutdownCoordinator = AppShutdownCoordinator(
      cancelImport: () {
        // Capture before awaiting pause: a source write may fail during pause.
        // Each canceled exit gets a fresh checkpoint on its next attempt.
        _sourceSaveOnExit = Get.find<OnlineMusicService>().beginExit();
        Get.find<LibraryService>().cancelImport();
        if (Get.isRegistered<PlayerController>()) {
          Get.find<PlayerController>().beginExit();
        }
      },
      pause: Get.find<PlayerService>().pause,
      flush: () async {
        final saved = await Future.wait([
          Get.find<AppPersistenceService>().flush(),
          _sourceSaveOnExit ??
              Get.find<OnlineMusicService>().flushPendingMutations(),
        ]);
        return saved.every((success) => success);
      },
      confirmExitWithoutSaving: () async {
        final context = Get.key.currentContext;
        if (!mounted || context == null) return false;
        setState(() => _confirming = true);
        try {
          return await confirmUnsavedExit(context);
        } finally {
          if (mounted) setState(() => _confirming = false);
        }
      },
      disposePowerEvents: () => _powerEvents?.dispose(),
      closeTimers: () {
        try {
          Get.find<SleepTimerCoordinator>().onClose();
        } finally {
          Get.find<TimerService>().onClose();
        }
      },
      closePersistence: () =>
          Get.find<AppPersistenceService>().close(flush: false),
      closePlayer: Get.find<PlayerService>().shutdown,
      closeOnline: Get.find<OnlineMusicService>().close,
      closeLibrary: Get.find<LibraryService>().onClose,
    );
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (mounted && !_closing) setState(() => _closing = true);
    final allowExit = await _shutdownCoordinator.shutdown();
    if (!allowExit) {
      Get.find<OnlineMusicService>().cancelExit();
      if (Get.isRegistered<PlayerController>()) {
        Get.find<PlayerController>().cancelExit();
      }
      if (mounted) setState(() => _closing = false);
    }
    return allowExit ? AppExitResponse.exit : AppExitResponse.cancel;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_shutdownCoordinator.shutdown(force: true));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GetMaterialApp(
    title: 'HanMusic',
    debugShowCheckedModeBanner: false,
    theme: HanMusicTheme.light,
    initialRoute: AppPages.player,
    getPages: AppPages.pages,
    builder: (context, child) {
      final busy = _closing && !_confirming;
      return Stack(
        children: [
          ExcludeFocus(
            excluding: busy,
            child: AbsorbPointer(absorbing: busy, child: child),
          ),
          if (busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x66000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      );
    },
  );
}
