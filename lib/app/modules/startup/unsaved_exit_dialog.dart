import 'package:flutter/material.dart';

Future<bool> confirmUnsavedExit(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('更改尚未保存'),
        scrollable: true,
        content: const Text(
          '部分更改未能保存，或保存仍在等待。请返回播放器查看错误提示，'
          '检查网络连接、磁盘空间和访问权限后重试。'
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
