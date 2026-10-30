import 'package:get/get.dart';

import '../../data/repositories/local_song_picker.dart';
import '../../services/player_service.dart';
import '../../services/desktop_media_service.dart';
import '../../services/playlist_service.dart';
import '../../services/play_history_service.dart';
import '../../services/library_service.dart';
import '../../services/timer_service.dart';
import '../../services/online_music_service.dart';
import '../../services/app_settings_service.dart';
import 'controller.dart';

class PlayerBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut(
      () => PlayerController(
        player: Get.find<PlayerService>(),
        timer: Get.find<TimerService>(),
        picker: LocalSongPicker(),
        library: Get.find<LibraryService>(),
        libraryPicker: LocalLibraryPicker(),
        online: Get.find<OnlineMusicService>(),
        desktopMedia: Get.isRegistered<DesktopMediaService>()
            ? Get.find<DesktopMediaService>()
            : null,
        playlists: Get.isRegistered<PlaylistService>()
            ? Get.find<PlaylistService>()
            : null,
        history: Get.isRegistered<PlayHistoryService>()
            ? Get.find<PlayHistoryService>()
            : null,
        settings: Get.isRegistered<AppSettingsService>()
            ? Get.find<AppSettingsService>()
            : null,
      ),
    );
  }
}
