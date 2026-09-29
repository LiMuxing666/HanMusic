import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A standalone startup screen: no stores or player services are opened here.
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({
    super.key,
    required this.message,
    required this.onExit,
    this.dataDirectory,
  });

  final String message;
  final VoidCallback onExit;
  final String? dataDirectory;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HanMusic',
    debugShowCheckedModeBanner: false,
    theme: HanMusicTheme.light,
    home: Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 40),
                  const SizedBox(height: 16),
                  const Text(
                    '暂时无法打开 HanMusic',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  Text(message),
                  if (dataDirectory case final directory?) ...[
                    const SizedBox(height: 16),
                    const Text('数据目录'),
                    const SizedBox(height: 4),
                    SelectableText(directory),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(onPressed: onExit, child: const Text('退出')),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
