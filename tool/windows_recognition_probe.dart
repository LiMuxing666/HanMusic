// Offline native capture diagnostic: never uses a microphone or uploads audio.
// Build with -t tool/windows_recognition_probe.dart and
// --dart-define=HANMUSIC_PROBE_DIR=<dedicated output directory>.
// Rebuild the default application entrypoint after running this diagnostic.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:han_music/app/data/sources/just_audio_backend.dart';
import 'package:han_music/app/data/sources/music_capture.dart';

const _channel = MethodChannel('hanmusic/music_capture');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const directory = String.fromEnvironment('HANMUSIC_PROBE_DIR');
  if (directory.isEmpty) exit(2);
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('HanMusic 离线声音采集验收'))),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_run(Directory(directory)));
  });
}

Future<void> _run(Directory output) async {
  await output.create(recursive: true);
  final checks = <Map<String, Object?>>[];
  initializeAudioBackend();
  final player = JustAudioBackend();
  final sample = File('${output.path}/generated-tone.wav');
  try {
    await sample.writeAsBytes(_tone());
    await player.setVolume(0.4);
    await player.load(sample.uri).timeout(const Duration(seconds: 10));
    await player.play();
    await _check(checks, 'loopback_wav_12_seconds', () async {
      final bytes = await WindowsMusicCapture().capture(
        source: MusicCaptureSource.loopback,
        duration: const Duration(seconds: 12),
      );
      if (bytes.length < 44) throw StateError('empty_wav');
      try {
        final header = ByteData.sublistView(bytes);
        if (ascii.decode(bytes.sublist(0, 4)) != 'RIFF' ||
            ascii.decode(bytes.sublist(8, 12)) != 'WAVE' ||
            header.getUint16(20, Endian.little) != 1 ||
            header.getUint16(22, Endian.little) != 1 ||
            header.getUint16(34, Endian.little) != 16) {
          throw StateError('invalid_wav');
        }
        final sampleRate = header.getUint32(24, Endian.little);
        final frames = (bytes.length - 44) ~/ 2;
        final seconds = frames / sampleRate;
        var energy = 0.0;
        for (var index = 44; index + 1 < bytes.length; index += 2) {
          final value = header.getInt16(index, Endian.little) / 32768;
          energy += value * value;
        }
        if (seconds < 10 || seconds > 12.2 || energy <= 0) {
          throw StateError('missing_signal_or_wrong_duration');
        }
        return {
          'sampleRate': sampleRate,
          'seconds': seconds,
          'bytes': bytes.length,
          'signalPresent': true,
        };
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
    });
    await player.seek(Duration.zero);
    await player.play();
    await _check(checks, 'cancel_and_reuse', () async {
      final capture = _channel
          .invokeMethod<Uint8List>('capture', {
            'source': 'loopback',
            'durationMs': 12000,
          })
          .then<String>(
            (bytes) {
              if (bytes != null) {
                final owned = Uint8List.fromList(bytes);
                owned.fillRange(0, owned.length, 0);
              }
              return 'unexpected_success';
            },
            onError: (Object error) =>
                error is PlatformException ? error.code : 'unknown',
          );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final watch = Stopwatch()..start();
      await _channel
          .invokeMethod<void>('cancel')
          .timeout(const Duration(seconds: 3));
      final code = await capture.timeout(const Duration(seconds: 3));
      if (code != 'cancelled') throw StateError('cancel_did_not_abort');
      final elapsed = watch.elapsedMilliseconds;
      final next = await WindowsMusicCapture().capture(
        source: MusicCaptureSource.loopback,
        duration: const Duration(milliseconds: 500),
      );
      if (next.length < 44) throw StateError('reuse_failed');
      next.fillRange(0, next.length, 0);
      return {'cancelMs': elapsed, 'reused': true};
    });
  } catch (error) {
    checks.add({
      'name': 'setup',
      'status': 'failed',
      'errorType': error.runtimeType.toString(),
    });
  } finally {
    await _channel.invokeMethod<void>('cancel').catchError((_) {});
    await player.dispose();
    await File('${output.path}/result.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'checks': checks,
        'microphoneUsed': false,
        'networkRequests': 0,
        'capturedAudioSaved': false,
      }),
    );
    exit(
      checks.length == 2 && checks.every((check) => check['status'] == 'passed')
          ? 0
          : 1,
    );
  }
}

Future<void> _check(
  List<Map<String, Object?>> checks,
  String name,
  Future<Map<String, Object?>> Function() action,
) async {
  try {
    checks.add({'name': name, 'status': 'passed', ...await action()});
  } catch (error) {
    checks.add({
      'name': name,
      'status': 'failed',
      'errorType': error.runtimeType.toString(),
      if (error is PlatformException) 'code': error.code,
    });
  }
}

Uint8List _tone() {
  const rate = 44100;
  const frames = rate * 18;
  final bytes = Uint8List(44 + frames * 2);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, ascii.encode(value));
  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, frames * 2, Endian.little);
  for (var index = 0; index < frames; index++) {
    data.setInt16(
      44 + index * 2,
      (1000 * math.sin(2 * math.pi * 440 * index / rate)).round(),
      Endian.little,
    );
  }
  return bytes;
}
