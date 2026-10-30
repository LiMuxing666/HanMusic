import 'dart:async';
import 'dart:typed_data';

import 'package:get/get.dart';

import '../data/models/music_recognition.dart';
import '../data/repositories/music_recognition_repository.dart';
import '../data/sources/music_capture.dart';

enum RecognitionPhase {
  idle,
  listening,
  recognizing,
  success,
  noMatch,
  error,
  cancelling,
}

class MusicRecognitionService extends GetxService {
  MusicRecognitionService({
    required MusicCapture capture,
    required MusicRecognitionRepository repository,
  }) : _capture = capture,
       _repository = repository;

  static const sampleDuration = Duration(seconds: 12);
  final MusicCapture _capture;
  final MusicRecognitionRepository _repository;
  final phase = RecognitionPhase.idle.obs;
  final source = MusicCaptureSource.loopback.obs;
  final remainingSeconds = sampleDuration.inSeconds.obs;
  final result = Rxn<MusicRecognitionResult>();
  final errorMessage = RxnString();

  int _generation = 0;
  bool _closed = false;
  final _exitPending = false.obs;
  Timer? _countdown;
  RecognitionCancellation? _request;
  Future<void>? _stopping;
  Future<void>? _closing;

  bool get acceptsCommands => !_closed && !_exitPending.value;
  bool get isAvailable => _repository.isConfigured;
  bool get isBusy => switch (phase.value) {
    RecognitionPhase.listening ||
    RecognitionPhase.recognizing ||
    RecognitionPhase.cancelling => true,
    _ => false,
  };

  void setSource(MusicCaptureSource value) {
    if (acceptsCommands && !isBusy) source.value = value;
  }

  bool _current(int generation) => acceptsCommands && generation == _generation;

  Future<void> start() async {
    if (!acceptsCommands || isBusy || _stopping != null) return;
    if (!isAvailable) {
      errorMessage.value = '识曲服务暂未开通，请稍后重试。';
      return;
    }
    final generation = ++_generation;
    final selectedSource = source.value;
    final cancellation = _request = RecognitionCancellation();
    result.value = null;
    errorMessage.value = null;
    remainingSeconds.value = sampleDuration.inSeconds;
    phase.value = RecognitionPhase.listening;
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_current(generation) && remainingSeconds.value > 0) {
        remainingSeconds.value--;
      }
    });
    Uint8List? sample;
    try {
      sample = await _capture.capture(
        source: selectedSource,
        duration: sampleDuration,
      );
      if (!_current(generation)) return;
      _countdown?.cancel();
      remainingSeconds.value = 0;
      phase.value = RecognitionPhase.recognizing;
      final match = await _repository.recognize(
        audio: sample,
        cancellation: cancellation,
      );
      if (!_current(generation)) return;
      result.value = match;
      phase.value = match == null
          ? RecognitionPhase.noMatch
          : RecognitionPhase.success;
    } on MusicRecognitionException catch (error) {
      if (_current(generation)) {
        errorMessage.value = error.message;
        phase.value = RecognitionPhase.error;
      }
    } catch (_) {
      if (_current(generation)) {
        errorMessage.value = '识曲暂时失败，请检查音频设备和网络后重试。';
        phase.value = RecognitionPhase.error;
      }
    } finally {
      // Includes cancellation and late results; no audio is retained in history.
      sample?.fillRange(0, sample.length, 0);
      if (generation == _generation) {
        _countdown?.cancel();
        _countdown = null;
        _request = null;
      }
    }
  }

  Future<void> cancel() {
    if (_stopping != null) return _stopping!;
    if (!isBusy) return Future.value();
    ++_generation;
    _request?.cancel();
    _request = null;
    _countdown?.cancel();
    _countdown = null;
    phase.value = RecognitionPhase.cancelling;
    return _stopping = _stopCapture().whenComplete(() => _stopping = null);
  }

  Future<void> _stopCapture() async {
    try {
      await _capture.cancel();
      if (!_closed) {
        remainingSeconds.value = sampleDuration.inSeconds;
        errorMessage.value = null;
        phase.value = RecognitionPhase.idle;
      }
    } on MusicRecognitionException catch (error) {
      if (!_closed) {
        errorMessage.value = error.message;
        phase.value = RecognitionPhase.error;
      }
    } catch (_) {
      if (!_closed) {
        errorMessage.value = '停止采集未能完成，请关闭应用后重试。';
        phase.value = RecognitionPhase.error;
      }
    }
  }

  Future<void> beginExit() {
    _exitPending.value = true;
    return cancel();
  }

  void cancelExit() {
    if (!_closed) _exitPending.value = false;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    await cancel();
    _repository.close();
  }

  @override
  void onClose() {
    unawaited(close());
    super.onClose();
  }
}
