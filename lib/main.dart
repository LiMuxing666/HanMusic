import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'app/core/theme/app_theme.dart';
import 'app/data/sources/just_audio_backend.dart';
import 'app/routes/app_pages.dart';
import 'app/services/player_service.dart';
import 'app/services/timer_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  initializeAudioBackend();
  final player = Get.put(PlayerService(JustAudioBackend()), permanent: true);
  Get.put(TimerService(onExpired: player.pause), permanent: true);
  runApp(const HanMusicApp());
}

class HanMusicApp extends StatefulWidget {
  const HanMusicApp({super.key});

  @override
  State<HanMusicApp> createState() => _HanMusicAppState();
}

class _HanMusicAppState extends State<HanMusicApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _shutdown() async {
    Get.find<TimerService>().cancel();
    await Get.find<PlayerService>().shutdown();
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
