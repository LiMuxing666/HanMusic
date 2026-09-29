import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/sources/windows_power_events.dart';
import 'package:han_music/app/services/timer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('hanmusic/power');

  Future<void> send(String method) async {
    final data = channel.codec.encodeMethodCall(MethodCall(method));
    ByteData? response;
    await messenger.handlePlatformMessage(
      channel.name,
      data,
      (result) => response = result,
    );
    if (response != null) channel.codec.decodeEnvelope(response!);
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'native resume checks an overdue timer once without window focus',
    () async {
      var now = DateTime.utc(2026, 9, 29);
      var expirations = 0;
      final timer = TimerService(
        now: () => now,
        onExpired: () async => expirations++,
      );
      final events = WindowsPowerEvents(onResume: timer.checkDeadline)..start();
      addTearDown(() {
        events.dispose();
        timer.onClose();
      });
      timer.start(const Duration(minutes: 1));
      now = now.add(const Duration(hours: 1));
      await send('resume');
      await send('resume');
      expect(expirations, 1);
      expect(timer.remaining.value, isNull);
    },
  );

  test(
    'early resume updates the countdown, unrelated events and disposal do nothing',
    () async {
      var now = DateTime.utc(2026, 9, 29);
      var expirations = 0;
      final timer = TimerService(
        now: () => now,
        onExpired: () async => expirations++,
      );
      final events = WindowsPowerEvents(onResume: timer.checkDeadline)..start();
      addTearDown(() {
        events.dispose();
        timer.onClose();
      });
      timer.start(const Duration(minutes: 10));
      now = now.add(const Duration(minutes: 3));
      await send('unrelated');
      expect(timer.remaining.value, const Duration(minutes: 10));
      await send('resume');
      expect(timer.remaining.value, const Duration(minutes: 7));
      expect(expirations, 0);
      events.dispose();
      now = now.add(const Duration(minutes: 1));
      await send('resume');
      expect(timer.remaining.value, const Duration(minutes: 7));
      expect(expirations, 0);
    },
  );
}
