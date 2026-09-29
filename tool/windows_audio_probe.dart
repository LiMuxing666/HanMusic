// Real Windows audio-backend diagnostic. This is not the application entrypoint.
// flutter build windows --release -t tool/windows_audio_probe.dart \
//   --dart-define=HANMUSIC_PROBE_DIR=D:/dev/tmp/hanmusic-audio-probe
// Put optional sample.mp3/sample.flac (generated from sample.wav) in that folder.
// The process writes result.json and exits; generated tones are deliberately quiet.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:han_music/app/data/sources/just_audio_backend.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

const _timeout = Duration(seconds: 12);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const outputPath = String.fromEnvironment('HANMUSIC_PROBE_DIR');
  if (outputPath.isEmpty) {
    stderr.writeln(
      'Set --dart-define=HANMUSIC_PROBE_DIR to an output directory.',
    );
    exit(2);
  }
  final output = Directory(outputPath);
  await output.create(recursive: true);
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('HanMusic Windows audio diagnostic')),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_runProbe(output));
  });
}

Future<void> _runProbe(Directory output) async {
  final started = DateTime.now().toUtc();
  final checks = <Map<String, Object?>>[];
  HttpServer? server;
  String? fatalError;
  try {
    JustAudioMediaKit.ensureInitialized(windows: true, linux: false);
    JustAudioMediaKit.title = 'HanMusic Audio Probe';
    final sample = File('${output.path}/sample.wav');
    await sample.writeAsBytes(_wav());
    final unicode = Directory('${output.path}/中文 音频');
    await unicode.create(recursive: true);
    final unicodeSample = await sample.copy('${unicode.path}/测试 曲目.wav');
    final corrupt = File('${output.path}/corrupt.wav');
    await corrupt.writeAsString('This is deliberately not an audio file.');

    // Each case uses real decoding, observed clock progress and a fresh player.
    await _check(checks, 'wav_playback_controls', () => _playback(sample.uri));
    for (final extension in ['mp3', 'flac']) {
      final file = File('${output.path}/sample.$extension');
      if (await file.exists()) {
        await _check(
          checks,
          '${extension}_playback_controls',
          () => _playback(file.uri),
        );
      } else {
        checks.add({
          'name': '${extension}_playback_controls',
          'status': 'skipped',
          'reason':
              'Provide a generated sample.$extension in the probe directory.',
        });
      }
    }
    await _check(
      checks,
      'unicode_and_spaces_path',
      () => _playback(unicodeSample.uri),
    );
    await _check(
      checks,
      'switch_sources_same_player',
      () => _switchSources([sample.uri, unicodeSample.uri]),
    );

    final bytes = await sample.readAsBytes();
    var httpRequests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      httpRequests++;
      try {
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        var start = 0;
        var end = bytes.length - 1;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final match = range == null
            ? null
            : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        if (match != null) {
          start = int.parse(match.group(1)!);
          if (match.group(2)!.isNotEmpty) end = int.parse(match.group(2)!);
          end = math.min(end, bytes.length - 1);
          if (start > end) {
            request.response.statusCode =
                HttpStatus.requestedRangeNotSatisfiable;
            await request.response.close();
            return;
          }
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${bytes.length}',
          );
        }
        request.response.contentLength = end - start + 1;
        if (request.method != 'HEAD') {
          request.response.add(bytes.sublist(start, end + 1));
        }
        await request.response.close();
      } on SocketException {
        // Seeking/disposal may close the previous HTTP request intentionally.
      } on HttpException {
        // The decoder may cancel a request after it has buffered enough data.
      }
    });
    await _check(checks, 'http_playback_controls', () async {
      final result = await _playback(
        Uri.parse('http://127.0.0.1:${server!.port}/sample.wav'),
      );
      _require(httpRequests > 0, 'The local HTTP server received no request.');
      return {...result, 'httpRequests': httpRequests};
    });
    await _check(
      checks,
      'corrupt_file_controlled_error_and_recovery',
      () => _expectLoadError(corrupt.uri, sample.uri),
    );
    final closedServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closedServer.port;
    await closedServer.close(force: true);
    await _check(
      checks,
      'unreachable_url_controlled_error_and_recovery',
      () => _expectLoadError(
        Uri.parse('http://127.0.0.1:$closedPort/unreachable.wav'),
        sample.uri,
      ),
    );
    await _check(
      checks,
      'dispose_releases_file',
      () => _disposeAndRename(sample),
    );
  } catch (error, stack) {
    fatalError = '$error\n$stack';
  } finally {
    await server?.close(force: true);
    final passed =
        fatalError == null &&
        checks.isNotEmpty &&
        checks.every((check) => check['status'] == 'passed');
    final result = {
      'schemaVersion': 1,
      'startedAt': started.toIso8601String(),
      'finishedAt': DateTime.now().toUtc().toIso8601String(),
      'os': Platform.operatingSystemVersion,
      'dartVersion': Platform.version,
      'passed': passed,
      'fatalError': fatalError,
      'checks': checks,
      'limitations': [
        'Clock/state/decoder verification does not confirm audible speaker output.',
        'Window minimization, device changes, system sleep and clean-machine distribution require separate checks.',
        'Invalid-source checks exercise the production JustAudioBackend adapter. '
            'just_audio_media_kit 2.1.0 publishes native errors without completing '
            'its pending load Future; raw AudioPlayer.setUrl hung in the initial run. '
            'Passing adapter checks does not mean that upstream bridge defect is fixed.',
      ],
    };
    await File('${output.path}/result.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(result),
      flush: true,
    );
    exit(passed ? 0 : 1);
  }
}

Future<void> _check(
  List<Map<String, Object?>> checks,
  String name,
  Future<Map<String, Object?>> Function() action,
) async {
  final watch = Stopwatch()..start();
  try {
    checks.add({
      'name': name,
      'status': 'passed',
      'observations': await action(),
      'elapsedMs': watch.elapsedMilliseconds,
    });
  } catch (error, stack) {
    checks.add({
      'name': name,
      'status': 'failed',
      'error': '$error',
      'stack': '$stack',
      'elapsedMs': watch.elapsedMilliseconds,
    });
  }
}

Future<Map<String, Object?>> _playback(Uri source) async {
  final player = AudioPlayer();
  final errors = <String>[];
  final sub = player.errorStream.listen((error) => errors.add('$error'));
  final states = <String>[];
  final stateSub = player.playerStateStream.listen((state) {
    states.add('${state.processingState.name}:${state.playing}');
  });
  try {
    await player.setVolume(0.03);
    final duration = await player.setUrl(source.toString()).timeout(_timeout);
    _require(
      duration != null && duration > const Duration(seconds: 2),
      'Expected a decoded sample longer than two seconds; received $duration.',
    );
    final total = duration!;
    unawaited(
      player.play().catchError((Object error) {
        errors.add('$error');
      }),
    );
    await _until(() => player.playing && player.position.inMilliseconds >= 250);
    final playedPosition = player.position;
    await player.pause().timeout(_timeout);
    final pauseObservation = await _verifyPaused(player);
    await player.seek(const Duration(seconds: 1)).timeout(_timeout);
    await _until(() => (player.position.inMilliseconds - 1000).abs() < 200);
    final seekPosition = player.position;
    await player.setVolume(0.01).timeout(_timeout);
    _require(
      (player.volume - 0.01).abs() < 0.001,
      'Volume property did not change.',
    );
    await player
        .seek(total - const Duration(milliseconds: 500))
        .timeout(_timeout);
    unawaited(
      player.play().catchError((Object error) {
        errors.add('$error');
      }),
    );
    await _until(() => player.processingState == ProcessingState.completed);
    _require(errors.isEmpty, 'Unexpected player errors: $errors');
    return {
      'durationMs': total.inMilliseconds,
      'playedPositionMs': playedPosition.inMilliseconds,
      ...pauseObservation,
      'seekPositionMs': seekPosition.inMilliseconds,
      'volume': player.volume,
      'completed': player.processingState == ProcessingState.completed,
      'states': states,
    };
  } finally {
    await player.dispose().timeout(_timeout);
    await sub.cancel();
    await stateSub.cancel();
  }
}

Future<Map<String, Object?>> _switchSources(List<Uri> sources) async {
  final player = AudioPlayer();
  final errors = <String>[];
  final sub = player.errorStream.listen((error) => errors.add('$error'));
  final positions = <int>[];
  try {
    await player.setVolume(0.01);
    for (final source in sources) {
      await player.pause().timeout(_timeout);
      await player.setUrl(source.toString()).timeout(_timeout);
      _require(
        player.position.inMilliseconds < 200,
        'Replacing the source did not reset position.',
      );
      unawaited(
        player.play().catchError((Object error) {
          errors.add('$error');
        }),
      );
      await _until(
        () => player.playing && player.position.inMilliseconds >= 250,
      );
      positions.add(player.position.inMilliseconds);
    }
    _require(errors.isEmpty, 'Switching sources produced errors: $errors');
    return {'sourcesPlayed': positions.length, 'positionsMs': positions};
  } finally {
    await player.dispose().timeout(_timeout);
    await sub.cancel();
  }
}

Future<Map<String, Object?>> _verifyPaused(AudioPlayer player) async {
  // just_audio stops extrapolating immediately, while already queued native
  // position events can still replace that estimate. Find a stable baseline,
  // then independently require a further uninterrupted observation interval.
  final watch = Stopwatch()..start();
  var anchor = player.position.inMilliseconds;
  var stableSince = Duration.zero;
  final adjustments = <int>[];
  while (watch.elapsed - stableSince < const Duration(milliseconds: 500)) {
    _require(!player.playing, 'Player resumed while waiting for pause.');
    _require(
      player.processingState != ProcessingState.completed,
      'Track ended before pause could be verified.',
    );
    if (watch.elapsed > const Duration(seconds: 2)) {
      throw StateError('Native playback position did not settle after pause.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final position = player.position.inMilliseconds;
    if ((position - anchor).abs() > 20) {
      adjustments.add(position - anchor);
      anchor = position;
      stableSince = watch.elapsed;
    }
  }
  final settledAfter = watch.elapsedMilliseconds;
  var minimum = player.position.inMilliseconds;
  var maximum = minimum;
  final verification = Stopwatch()..start();
  while (verification.elapsed < const Duration(milliseconds: 700)) {
    await Future<void>.delayed(const Duration(milliseconds: 40));
    _require(!player.playing, 'Player resumed during pause verification.');
    _require(
      player.processingState != ProcessingState.completed,
      'Track reached completion instead of remaining paused.',
    );
    minimum = math.min(minimum, player.position.inMilliseconds);
    maximum = math.max(maximum, player.position.inMilliseconds);
    _require(
      maximum - minimum <= 40,
      'Paused position advanced after settling: ${maximum - minimum}ms.',
    );
  }
  return {
    'pauseSettledAfterMs': settledAfter,
    'pauseNativeAdjustmentsMs': adjustments,
    'pauseVerificationMs': verification.elapsedMilliseconds,
    'pauseDriftMs': maximum - minimum,
  };
}

Future<Map<String, Object?>> _expectLoadError(Uri source, Uri recovery) async {
  final backend = JustAudioBackend();
  final errors = <String>[];
  final sub = backend.errors.listen((error) => errors.add('$error'));
  var playing = false;
  var position = Duration.zero;
  final stateSub = backend.states.listen((state) {
    playing = state.playing;
  });
  final positionSub = backend.positions.listen((value) {
    position = value;
  });
  try {
    await backend.setVolume(0.01);
    Object? loadError;
    final watch = Stopwatch()..start();
    try {
      await backend
          .load(source)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              throw const _ProbeDeadline(
                'Production load did not fail within 20 seconds.',
              );
            },
          );
    } on _ProbeDeadline {
      rethrow; // A harness deadline is never a controlled production failure.
    } catch (error) {
      loadError = error;
    }
    final failureAfterMs = watch.elapsedMilliseconds;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _require(
      loadError != null,
      'Production load returned successfully for an invalid source.',
    );
    final failureEvents = List<String>.of(errors);
    errors.clear();
    // Recovery on the same adapter must work even if the bridge's original
    // Future is still pending. Rebuilding an unrelated adapter would hide that.
    final duration = await backend.load(recovery).timeout(_timeout);
    _require(
      duration != null && duration > const Duration(seconds: 2),
      'A valid source did not load after the controlled failure.',
    );
    await backend.seek(Duration.zero).timeout(_timeout);
    position = Duration.zero;
    await backend.play().timeout(_timeout);
    await _until(() => playing && position.inMilliseconds >= 200);
    _require(errors.isEmpty, 'Native errors leaked into recovery: $errors');
    await backend.pause().timeout(_timeout);
    return {
      'testedLayer': 'production JustAudioBackend',
      'loadError': loadError.toString(),
      'failureKind': loadError is TimeoutException
          ? 'production_timeout_fallback'
          : 'reported_error',
      'failureAfterMs': failureAfterMs,
      'errorEvents': failureEvents,
      'sameAdapterRecoveryDurationMs': duration?.inMilliseconds,
      'sameAdapterRecoveryPositionMs': position.inMilliseconds,
    };
  } finally {
    await backend.dispose().timeout(_timeout);
    await sub.cancel();
    await stateSub.cancel();
    await positionSub.cancel();
  }
}

class _ProbeDeadline implements Exception {
  const _ProbeDeadline(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<Map<String, Object?>> _disposeAndRename(File sample) async {
  final disposable = await sample.copy('${sample.parent.path}/dispose.wav');
  final player = AudioPlayer();
  final errors = <String>[];
  final sub = player.errorStream.listen((error) => errors.add('$error'));
  try {
    await player.setVolume(0.01);
    await player.setFilePath(disposable.path).timeout(_timeout);
    unawaited(
      player.play().catchError((Object error) {
        errors.add('$error');
      }),
    );
    await _until(() => player.position.inMilliseconds >= 200);
  } finally {
    await player.dispose().timeout(_timeout);
    await sub.cancel();
  }
  final renamed = await disposable.rename('${sample.parent.path}/disposed.wav');
  _require(await renamed.exists(), 'Disposed audio file could not be renamed.');
  _require(errors.isEmpty, 'Disposal produced player errors: $errors');
  return {'disposedWhilePlaying': true, 'fileRenamedAfterDispose': true};
}

Future<void> _until(bool Function() predicate) async {
  final stopwatch = Stopwatch()..start();
  while (!predicate()) {
    if (stopwatch.elapsed > _timeout) {
      throw TimeoutException(
        'Timed out waiting for native player state.',
        _timeout,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Uint8List _wav() {
  const sampleRate = 44100;
  const samples = sampleRate * 4;
  final bytes = ByteData(44 + samples * 2);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    bytes.setInt16(
      44 + i * 2,
      (math.sin(i * 2 * math.pi * 440 / sampleRate) * 1600).round(),
      Endian.little,
    );
  }
  return bytes.buffer.asUint8List();
}
