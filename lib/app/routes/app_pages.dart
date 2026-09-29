import 'package:get/get.dart';

import '../modules/player/bindings.dart';
import '../modules/player/controller.dart';
import '../modules/player/view.dart';

class AppPages {
  AppPages._();

  static const player = '/player';
  static final pages = [
    GetPage(
      name: player,
      page: () => PlayerPage(controller: Get.find<PlayerController>()),
      binding: PlayerBinding(),
    ),
  ];
}
