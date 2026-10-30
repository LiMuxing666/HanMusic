import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/services/desktop_media_service.dart';
import 'package:han_music/app/services/player_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('hanmusic/desktop_media');
  late FakeAudioBackend backend;
  late PlayerService player;
  late DesktopMediaService service;
  final calls = <MethodCall>[];
  final songs = List.generate(
    3,
    (index) => Song(
      uri: Uri.file('D:/music/desktop-$index.mp3', windows: true),
      fileName: 'desktop-$index.mp3',
      trackTitle: ' 曲目 $index ',
      artist: ' 歌手 $index ',
      album: ' 专辑 $index ',
    ),
  );

  Future<Object?> native(MethodCall call) async {
    calls.add(call);
    if (call.method == 'initialize') {
      return {'tray': true, 'mediaControls': true};
    }
    return true;
  }

  Future<void> send(String action) async {
    ByteData? response;
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('action', action)),
      (result) => response = result,
    );
    if (response != null) channel.codec.decodeEnvelope(response!);
    await _settle();
  }

  Map<Object?, Object?> state() =>
      calls.lastWhere((call) => call.method == 'updateState').arguments
          as Map<Object?, Object?>;

  setUp(() {
    calls.clear();
    backend = FakeAudioBackend();
    player = PlayerService(backend);
    service = DesktopMediaService(player, channel: channel, enabled: true);
    messenger.setMockMethodCallHandler(channel, native);
  });
  tearDown(() async {
    await service.close();
    messenger.setMockMethodCallHandler(channel, null);
    await player.shutdown();
  });

  test(
    'publishes initial and changed metadata and state without position polling',
    () async {
      await service.start();
      await service.start();
      expect(calls.where((call) => call.method == 'initialize'), hasLength(1));
      expect(service.trayAvailable.value, isTrue);
      expect(service.mediaControlsAvailable.value, isTrue);
      expect(state()['hasTrack'], isFalse);
      await player.playQueue(songs);
      await _settle();
      expect(state(), containsPair('title', '曲目 0'));
      expect(state(), containsPair('artist', '歌手 0'));
      expect(state(), containsPair('album', '专辑 0'));
      expect(state()['playing'], isTrue);
      expect(state()['canNavigate'], isTrue);
      final count = calls.length;
      backend.emitPosition(const Duration(seconds: 30));
      await player.setVolume(0.3);
      await _settle();
      expect(calls, hasLength(count));
      await player.clearQueue();
      await _settle();
      expect(state()['title'], isEmpty);
      expect(state()['hasTrack'], isFalse);
      expect(state()['canNavigate'], isFalse);
    },
  );

  test(
    'system play pause navigation and tray toggle route to the player',
    () async {
      await player.restoreQueue(songs);
      await service.start();
      await send('play');
      expect(player.isPlaying.value, isTrue);
      final playCalls = backend.playCalls;
      await send('play');
      expect(backend.playCalls, playCalls);
      await send('pause');
      expect(player.isPlaying.value, isFalse);
      await send('next');
      expect(player.currentSong.value, songs[1]);
      await send('previous');
      expect(player.currentSong.value, songs[0]);
      await send('toggle');
      expect(player.isPlaying.value, isFalse);
      await send('toggle');
      expect(player.isPlaying.value, isTrue);
      final beforeUnknown = backend.calls.toList();
      await send('unknown');
      expect(backend.calls, beforeUnknown);
    },
  );

  test(
    'native pause cancels autoplay while loading and other transport waits',
    () async {
      await service.start();
      final gate = backend.loadCompleter = Completer<Duration?>();
      final loading = player.playQueue(songs);
      try {
        await _settle();
        expect(state()['canPlay'], isFalse);
        expect(state()['canPause'], isTrue);
        expect(state()['canNavigate'], isFalse);
        await send('next');
        await send('previous');
        await send('toggle');
        await send('play');
        expect(backend.loadedUris, [songs[0].uri]);
        await send('pause');
      } finally {
        gate.complete(const Duration(minutes: 3));
        await loading;
        backend.loadCompleter = null;
      }
      expect(player.isPlaying.value, isFalse);
      expect(backend.playCalls, 0);
    },
  );

  test('failed song can be retried and exit blocks native commands', () async {
    player.skipOnError.value = false;
    backend.loadFailure = StateError('Temporary failure');
    await player.playQueue(songs);
    await service.start();
    expect(state()['canPlay'], isTrue);
    backend.loadFailure = null;
    await send('play');
    expect(player.isPlaying.value, isTrue);
    service.beginExit();
    await _settle();
    expect(state()['enabled'], isFalse);
    expect(state()['canPlay'], isFalse);
    expect(state()['canPause'], isFalse);
    expect(state()['canNavigate'], isFalse);
    final beforeExit = backend.calls.toList();
    await send('toggle');
    await send('next');
    expect(await service.hideToTray(), isFalse);
    expect(backend.calls, beforeExit);
    service.cancelExit();
    await send('pause');
    expect(player.isPlaying.value, isFalse);
    expect(await service.hideToTray(), isTrue);
  });

  test(
    'unsupported hosts and missing native implementation degrade without errors',
    () async {
      await service.close();
      service = DesktopMediaService(player, channel: channel, enabled: false);
      await service.start();
      expect(calls, isEmpty);
      expect(await service.hideToTray(), isFalse);
      await service.close();
      service = DesktopMediaService(player, channel: channel, enabled: true);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw MissingPluginException(),
      );
      await service.start();
      expect(service.trayAvailable.value, isFalse);
      expect(service.mediaControlsAvailable.value, isFalse);
      expect(await service.hideToTray(), isFalse);
      await player.playQueue(songs);
      await send('pause');
      expect(player.isPlaying.value, isTrue);
    },
  );

  test(
    'state and hide failures are contained and later state changes retry',
    () async {
      var failUpdates = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if ((call.method == 'updateState' && failUpdates) ||
            call.method == 'hideToTray') {
          throw PlatformException(code: 'unavailable');
        }
        return native(call);
      });
      await service.start();
      expect(await service.hideToTray(), isFalse);
      failUpdates = false;
      await player.playQueue(songs);
      await _settle();
      expect(state()['title'], '曲目 0');
      expect(state()['playing'], isTrue);
    },
  );

  test(
    'close unregisters listeners and is safe while initialize is pending',
    () async {
      final initialized = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'initialize' ? initialized.future : null;
      });
      final starting = service.start();
      await _settle();
      await service.close();
      initialized.complete({'tray': true, 'mediaControls': true});
      await starting;
      expect(service.trayAvailable.value, isFalse);
      expect(service.mediaControlsAvailable.value, isFalse);
      await player.playQueue(songs);
      await _settle();
      await send('pause');
      expect(player.isPlaying.value, isTrue);
      expect(calls.map((call) => call.method), ['initialize', 'dispose']);
      await service.close();
      expect(calls, hasLength(2));
    },
  );

  test('slow update sends the newest pending state in order', () async {
    await service.start();
    final gate = Completer<Object?>();
    var hold = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'updateState' && hold) {
        hold = false;
        return gate.future;
      }
      return true;
    });
    await player.playQueue(songs);
    await _settle();
    await player.next();
    await player.pause();
    await _settle();
    gate.complete(true);
    await _settle();
    expect(state()['title'], '曲目 1');
    expect(state()['playing'], isFalse);
    final count = calls.length;
    await service.close();
    await player.next();
    await _settle();
    expect(calls, hasLength(count + 1));
    expect(calls.last.method, 'dispose');
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);
