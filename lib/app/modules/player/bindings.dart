import 'package:get/get.dart';

import '../../data/repositories/local_song_picker.dart';
import '../../services/player_service.dart';
import '../../services/library_service.dart';
import '../../services/timer_service.dart';
import '../../services/online_music_service.dart';
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
      ),
    );
  }
}
