import 'package:flutter/material.dart';

Future<bool> confirmUnsavedExit(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('更改尚未保存'),
        scrollable: true,
        content: const Text(
          '无法写入本地数据。可以返回播放器，检查磁盘空间和访问权限后再退出。'
          '仍然退出会丢失尚未保存的更改。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('返回播放器'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('仍然退出'),
          ),
        ],
      ),
    ) ??
    false;
