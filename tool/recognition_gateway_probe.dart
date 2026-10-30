// Operator diagnostic: generated tone -> configured gateway -> recognition.
// Usage: dart tool/recognition_gateway_probe.dart <gateway-recognition-url>
// This has no vendor credentials. Running against a live gateway uses its quota.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:han_music/app/data/models/music_recognition.dart';
import 'package:han_music/app/data/repositories/music_recognition_repository.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart tool/recognition_gateway_probe.dart <gateway-url>',
    );
    exitCode = 2;
    return;
  }
  final repository = MusicRecognitionRepository(
    endpoint: Uri.tryParse(arguments.single),
  );
  final audio = _tone();
  try {
    final result = await repository.recognize(
      audio: audio,
      cancellation: RecognitionCancellation(),
    );
    stdout.writeln(
      jsonEncode({
        'gatewayResponded': true,
        'matched': result != null,
        'title': result?.title,
        'artist': result?.artist,
        'audioBytes': audio.length,
        'userAudioUsed': false,
        'clientHasVendorCredentials': false,
      }),
    );
  } on MusicRecognitionException catch (error) {
    stdout.writeln(
      jsonEncode({'gatewayResponded': false, 'message': error.message}),
    );
    exitCode = 1;
  } catch (_) {
    stdout.writeln(jsonEncode({'gatewayResponded': false}));
    exitCode = 1;
  } finally {
    audio.fillRange(0, audio.length, 0);
    repository.close();
  }
}

Uint8List _tone() {
  const rate = 16000;
  final bytes = Uint8List(44 + rate * 2);
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
  data.setUint32(40, rate * 2, Endian.little);
  for (var i = 0; i < rate; i++) {
    data.setInt16(
      44 + i * 2,
      (1000 * math.sin(2 * math.pi * 440 * i / rate)).round(),
      Endian.little,
    );
  }
  return bytes;
}
