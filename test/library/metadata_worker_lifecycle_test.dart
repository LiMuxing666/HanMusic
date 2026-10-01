import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/repositories/local_library_repository.dart';
import 'package:path/path.dart' as p;

// This closure captures only a SendPort: parsing, staging, and this gate all
// execute in the repository's real production isolate, not a fake reader.
Future<void> Function(String) _stagingGate(
  SendPort events, {
  Duration nativeDelay = Duration.zero,
}) => (path) async {
  final release = ReceivePort();
  Isolate.current.addOnExitListener(events, response: ['exit']);
  events.send(['staged', path, release.sendPort]);
  try {
    // dart:io sleep occupies this real worker's native thread. It models a
    // synchronous OS operation that can outlive the parent's close grace.
    if (nativeDelay > Duration.zero) sleep(nativeDelay);
    await release.first;
  } finally {
    release.close();
  }
};

class _WorkerObservation {
  _WorkerObservation() {
    _subscription = port.listen((dynamic event) {
      final message = event as List;
      if (message[0] == 'staged') {
        staged.complete(message[1] as String);
        release = message[2] as SendPort;
      } else if (message[0] == 'exit') {
        if (!exited.isCompleted) exited.complete();
      }
    });
  }
  final port = ReceivePort();
  final staged = Completer<String>();
  final exited = Completer<void>();
  late final StreamSubscription<dynamic> _subscription;
  SendPort? release;

  Future<void> dispose() async {
    await _subscription.cancel();
    port.close();
  }
}

void main() {
  late Directory root;
  late Directory artwork;
  late File audio;
  late List<int> originalAudio;
  late File unrelatedTemporary;
  late File existingCover;
  final sessions = <LibraryReadSession>[];
  final observations = <_WorkerObservation>[];

  setUp(() async {
    final base = Directory('D:/dev/tmp/hanmusic-import-lifecycle-tests');
    await base.create(recursive: true);
    root = await base.createTemp('case-');
    artwork = await Directory(p.join(root.path, 'artwork')).create();
    audio = await File(
      'test/library/fixtures/tagged.mp3',
    ).copy(p.join(root.path, 'tagged.mp3'));
    originalAudio = await audio.readAsBytes();
    unrelatedTemporary = await File(
      p.join(artwork.path, 'other-session.tmp'),
    ).writeAsString('not owned by this session');
    existingCover = await File(
      p.join(artwork.path, 'existing.png'),
    ).writeAsString('pre-existing cover');
  });

  tearDown(() async {
    for (final session in sessions) {
      await session.close();
    }
    sessions.clear();
    for (final observation in observations) {
      await observation.dispose();
    }
    observations.clear();
    // Keep isolated files as evidence, including any leaked file on a red run.
    expect(await audio.readAsBytes(), originalAudio);
    expect(
      await unrelatedTemporary.readAsString(),
      'not owned by this session',
    );
    expect(await existingCover.readAsString(), 'pre-existing cover');
  });

  ({LibraryReadSession session, _WorkerObservation worker}) create(
    ImportCancellation cancellation, {
    Duration timeout = const Duration(seconds: 5),
    Duration nativeDelay = Duration.zero,
  }) {
    final worker = _WorkerObservation();
    observations.add(worker);
    final session = LocalLibraryRepository(
      artworkDirectory: artwork,
      metadataTimeout: timeout,
      debugOnArtworkStaged: _stagingGate(
        worker.port.sendPort,
        nativeDelay: nativeDelay,
      ),
    ).openReadSession(cancellation);
    sessions.add(session);
    return (session: session, worker: worker);
  }

  test('real worker cancellation cleans its staged cover after exit', () async {
    final cancellation = ImportCancellation();
    final fixture = create(cancellation);
    final reading = fixture.session.read(audio);
    final cancelled = expectLater(reading, throwsA(isA<ImportCancelled>()));
    final temporaryPath = await fixture.worker.staged.future.timeout(
      const Duration(seconds: 3),
    );
    expect(
      await File(temporaryPath).readAsBytes(),
      await File('test/library/fixtures/cover.png').readAsBytes(),
    );
    cancellation.cancel();
    await cancelled.timeout(const Duration(seconds: 2));
    await fixture.worker.exited.future.timeout(const Duration(seconds: 2));
    expect(
      await File(temporaryPath).exists(),
      isFalse,
      reason: 'Killing a worker must not leave its staged cover behind.',
    );
  });

  test('real worker deadline cleans its staged cover after exit', () async {
    final fixture = create(
      ImportCancellation(),
      timeout: const Duration(milliseconds: 500),
      nativeDelay: const Duration(seconds: 2),
    );
    final reading = fixture.session.read(audio);
    final temporaryPath = await fixture.worker.staged.future.timeout(
      const Duration(seconds: 3),
    );
    final result = await reading.timeout(const Duration(seconds: 2));
    expect(result.warning, isNotNull);
    expect(result.song.artworkPath, isNull);
    expect(fixture.worker.exited.isCompleted, isFalse);
    expect(await File(temporaryPath).exists(), isTrue);

    final next = await File(
      'test/library/fixtures/tagged.wav',
    ).copy(p.join(root.path, 'next.wav'));
    // This session must use a replacement worker, with no old reply/port state.
    final recovered = await fixture.session.read(next);
    expect(recovered.song.title, 'Fixture WAV');
    expect(recovered.warning, isNull);
    await fixture.worker.exited.future.timeout(const Duration(seconds: 3));
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (await File(temporaryPath).exists() &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      await File(temporaryPath).exists(),
      isFalse,
      reason: 'A per-file timeout must not leak a real staged cover.',
    );
    // The old worker's later exit must not stop/complete the new worker.
    expect((await fixture.session.read(next)).song.title, 'Fixture WAV');
  });

  test('close settles an active real read and clears staged files', () async {
    final fixture = create(ImportCancellation());
    final outcome = fixture.session
        .read(audio)
        .then<Object>((result) => result, onError: (Object error) => error);
    final temporaryPath = await fixture.worker.staged.future.timeout(
      const Duration(seconds: 3),
    );
    await fixture.session.close().timeout(const Duration(seconds: 2));
    expect(
      await outcome.timeout(const Duration(seconds: 1)),
      isA<ImportCancelled>(),
    );
    expect(fixture.worker.exited.isCompleted, isTrue);
    expect(await File(temporaryPath).exists(), isFalse);
    await expectLater(fixture.session.read(audio), throwsStateError);
    await fixture.session.close();
  });

  test('close during worker startup prevents a late metadata result', () async {
    final fixture = create(ImportCancellation());
    final outcome = fixture.session
        .read(audio)
        .then<Object>((result) => result, onError: (Object error) => error);
    await fixture.session.close().timeout(const Duration(seconds: 2));
    expect(
      await outcome.timeout(const Duration(seconds: 1)),
      isA<ImportCancelled>(),
    );
    // No real cache write/gate may start after the session has closed.
    expect(fixture.worker.staged.isCompleted, isFalse);
    expect(
      await artwork.list().map((entry) => p.basename(entry.path)).toList(),
      unorderedEquals(['existing.png', 'other-session.tmp']),
    );
  });

  test('slow native worker defers cleanup until confirmed exit', () async {
    final fixture = create(
      ImportCancellation(),
      nativeDelay: const Duration(seconds: 2),
    );
    final outcome = fixture.session
        .read(audio)
        .then<Object>((result) => result, onError: (Object error) => error);
    final temporaryPath = await fixture.worker.staged.future.timeout(
      const Duration(seconds: 3),
    );
    final timer = Stopwatch()..start();
    await fixture.session.close().timeout(const Duration(seconds: 1));
    expect(timer.elapsed, lessThan(const Duration(seconds: 1)));
    expect(await outcome, isA<ImportCancelled>());
    expect(fixture.worker.exited.isCompleted, isFalse);
    expect(
      await File(temporaryPath).exists(),
      isTrue,
      reason: 'Never delete staging while native worker code can still run.',
    );
    await fixture.worker.exited.future.timeout(const Duration(seconds: 3));
    // The independent exit observer can precede the parent's asynchronous
    // deletion. Wait only for that known path, without any global cache sweep.
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (await File(temporaryPath).exists() &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await File(temporaryPath).exists(), isFalse);
  });
}
