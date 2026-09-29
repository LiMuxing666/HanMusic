import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/data/models/song.dart';
import 'package:han_music/app/services/player_service.dart';
import 'package:han_music/app/services/timer_service.dart';

import '../support/fake_audio_backend.dart';

void main() {
  test(
    'sleep timer never reports successful stopping when native pause fails',
    () async {
      final backend = _PauseFailureBackend();
      final player = PlayerService(backend);
      var now = DateTime.utc(2026, 10, 1);
      final errors = <Object>[];
      final timer = TimerService(
        onExpired: player.pauseForSleepTimer,
        now: () => now,
        onError: (error, _) => errors.add(error),
      );
      addTearDown(() async {
        timer.onClose();
        await player.shutdown();
      });
      final song = Song(
        uri: Uri.file('D:/song.mp3', windows: true),
        fileName: 'song.mp3',
      );
      await player.open(song);
      backend.failPause = true;
      timer.start(const Duration(seconds: 1));
      now = now.add(const Duration(seconds: 1));
      timer.checkDeadline();
      expect(timer.statusMessage.value, '正在暂停播放…');
      await Future<void>.delayed(Duration.zero);
      expect(timer.statusMessage.value, '暂停失败，请关闭应用以停止音频。');
      expect(timer.statusMessage.value, isNot(contains('已停止')));
      expect(errors, hasLength(1));
      expect(player.queue.single.id, song.id);
      expect(player.errorMessage.value, contains('关闭应用'));
      await player
          .pause(); // Ordinary pause remains a handled user-facing error.
    },
  );
}

class _PauseFailureBackend extends FakeAudioBackend {
  bool failPause = false;
  @override
  Future<void> pause() async {
    if (failPause) throw StateError('Native pause failed');
    await super.pause();
  }
}
