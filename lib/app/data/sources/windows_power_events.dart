import 'package:flutter/services.dart';

/// Rechecks deadlines on Windows power resume, including background resumes.
/// The composition root enables this only on Windows; it never requests sleep.
class WindowsPowerEvents {
  WindowsPowerEvents({
    required VoidCallback onResume,
    MethodChannel channel = const MethodChannel('hanmusic/power'),
  }) : _onResume = onResume,
       _channel = channel;

  final VoidCallback _onResume;
  final MethodChannel _channel;
  bool _listening = false;

  void start() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (_listening && call.method == 'resume') _onResume();
    });
  }

  void dispose() {
    if (!_listening) return;
    _listening = false;
    _channel.setMethodCallHandler(null);
  }
}
