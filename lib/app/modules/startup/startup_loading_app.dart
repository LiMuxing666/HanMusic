import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The first frame is independent of disk, audio, and GetX initialization.
class StartupLoadingApp extends StatelessWidget {
  const StartupLoadingApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HanMusic',
    debugShowCheckedModeBanner: false,
    theme: HanMusicTheme.light,
    home: const Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.graphic_eq_rounded, size: 48),
                SizedBox(height: 20),
                Text(
                  '正在打开 HanMusic…',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 16),
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('正在检查曲库与播放状态，请稍候。', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
