// Uses exactly the same build-time URL validation as the released client.
import 'dart:io';

import 'package:han_music/app/data/repositories/music_recognition_repository.dart';

void main() {
  final repository = MusicRecognitionRepository();
  try {
    if (!repository.isConfigured) {
      stderr.writeln(
        'Recognition endpoint is missing or invalid. Use a public HTTPS /v1/recognize URL.',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln('Recognition endpoint configuration is valid.');
  } finally {
    repository.close();
  }
}
