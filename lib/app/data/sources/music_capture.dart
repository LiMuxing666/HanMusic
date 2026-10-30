import 'dart:async';

import 'package:flutter/services.dart';

import '../models/music_recognition.dart';

enum MusicCaptureSource { loopback, microphone }

abstract class MusicCapture {
  Future<Uint8List> capture({
    required MusicCaptureSource source,
    required Duration duration,
  });

  Future<void> cancel();
}

/// Captures only after an explicit user action. Samples never become files.
class WindowsMusicCapture implements MusicCapture {
  WindowsMusicCapture({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('hanmusic/music_capture');

  final MethodChannel _channel;
  int _generation = 0;

  @override
  Future<Uint8List> capture({
    required MusicCaptureSource source,
    required Duration duration,
  }) async {
    final generation = ++_generation;
    try {
      final bytes = await _channel
          .invokeMethod<Uint8List>('capture', {
            'source': source.name,
            'durationMs': duration.inMilliseconds,
          })
          .timeout(duration + const Duration(seconds: 8));
      if (bytes == null || bytes.length < 44) {
        throw const MusicRecognitionException('没有采集到可用声音，请播放音乐后重试。');
      }
      // Release-mode platform replies may be backed by read-only engine memory.
      // Own a mutable buffer so the service can erase it after use.
      return Uint8List.fromList(bytes);
    } on TimeoutException {
      if (generation == _generation) await cancel();
      throw const MusicRecognitionException('声音采集超时，请检查音频设备后重试。');
    } on MissingPluginException {
      throw const MusicRecognitionException('当前运行环境不支持声音采集，请使用 Windows 桌面版本。');
    } on PlatformException catch (error) {
      throw MusicRecognitionException(switch (error.code) {
        'cancelled' => '已取消识曲。',
        'no_device' => '没有可用的音频设备，请检查默认扬声器或麦克风。',
        'permission_denied' => '无法使用麦克风，请检查 Windows 麦克风隐私设置和设备权限。',
        'no_audio' => '没有采集到音乐，请确认所选设备有声音后重试。',
        'unsupported_format' => '当前音频设备格式不受支持，请更换默认设备后重试。',
        'busy' => '上一次采集尚未结束，请稍后重试。',
        _ => '声音采集失败，请检查音频设备后重试。',
      });
    }
  }

  @override
  Future<void> cancel() async {
    ++_generation;
    try {
      await _channel
          .invokeMethod<void>('cancel')
          .timeout(const Duration(seconds: 5));
    } on MissingPluginException {
      // Unsupported runners cannot have a native capture to stop.
    } catch (_) {
      throw const MusicRecognitionException('停止采集未能及时完成，请稍后重试或关闭应用。');
    }
  }
}
