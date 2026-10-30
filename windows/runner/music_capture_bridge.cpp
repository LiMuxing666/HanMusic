#include "music_capture_bridge.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <process.h>
#include <wrl/client.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <optional>
#include <utility>
#include <vector>

namespace {
constexpr UINT kCaptureComplete = WM_APP + 74;
constexpr size_t kMaxWavBytes = 8U * 1024U * 1024U;
constexpr size_t kWavHeaderBytes = 44;
constexpr int64_t kMaxDurationMs = 12000;
constexpr GUID kPcmSubtype = {
    WAVE_FORMAT_PCM, 0, 0x0010, {0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71}};
constexpr GUID kFloatSubtype = {
    WAVE_FORMAT_IEEE_FLOAT, 0, 0x0010, {0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71}};
std::atomic<LONG_PTR> next_capture_generation{0};

enum class CaptureError {
  none, cancelled, no_device, permission_denied, no_audio,
  unsupported_format, capture_failed,
};

const char* ErrorCode(CaptureError error) noexcept {
  switch (error) {
    case CaptureError::cancelled: return "cancelled";
    case CaptureError::no_device: return "no_device";
    case CaptureError::permission_denied: return "permission_denied";
    case CaptureError::no_audio: return "no_audio";
    case CaptureError::unsupported_format: return "unsupported_format";
    default: return "capture_failed";
  }
}

const char* ErrorMessage(CaptureError error) noexcept {
  switch (error) {
    case CaptureError::cancelled: return "采样已取消。";
    case CaptureError::no_device: return "未找到可用的音频设备。";
    case CaptureError::permission_denied:
      return "无法访问音频设备，请检查系统权限。";
    case CaptureError::no_audio: return "未采集到声音，请检查音源与音量。";
    case CaptureError::unsupported_format: return "音频设备格式暂不支持。";
    default: return "音频采样失败，请重试。";
  }
}

void Check(HRESULT status) {
  if (SUCCEEDED(status)) return;
  if (status == E_ACCESSDENIED ||
      status == HRESULT_FROM_WIN32(ERROR_PRIVILEGE_NOT_HELD)) {
    throw CaptureError::permission_denied;
  }
  if (status == HRESULT_FROM_WIN32(ERROR_NOT_FOUND) ||
      status == AUDCLNT_E_DEVICE_INVALIDATED ||
      status == AUDCLNT_E_SERVICE_NOT_RUNNING) {
    throw CaptureError::no_device;
  }
  if (status == AUDCLNT_E_UNSUPPORTED_FORMAT) {
    throw CaptureError::unsupported_format;
  }
  throw CaptureError::capture_failed;
}

struct CaptureOutcome {
  CaptureError error = CaptureError::none;
  std::vector<uint8_t> wav;
};

struct CaptureJob {
  ~CaptureJob() {
    if (cancel_event) CloseHandle(cancel_event);
  }
  HWND window = nullptr;
  LONG_PTR generation = 0;
  bool loopback = false;
  int64_t duration_ms = kMaxDurationMs;
  HANDLE cancel_event = nullptr;
  std::mutex mutex;
  // Protected by mutex: destructor disables delivery before releasing the HWND.
  bool delivery_enabled = true;
  std::optional<CaptureOutcome> outcome;
};

void CheckCancelled(const CaptureJob& job) {
  if (WaitForSingleObject(job.cancel_event, 0) == WAIT_OBJECT_0) {
    throw CaptureError::cancelled;
  }
}

struct ComApartment {
  ComApartment() { Check(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)); }
  ~ComApartment() { CoUninitialize(); }
};

struct MixFormat {
  ~MixFormat() { CoTaskMemFree(value); }
  WAVEFORMATEX* value = nullptr;
};

struct StopAudio {
  ~StopAudio() { if (started) client->Stop(); }
  IAudioClient* client;
  bool started = false;
};

struct ReleasePacket {
  ~ReleasePacket() { if (frames != 0) client->ReleaseBuffer(frames); }
  void Release() {
    const auto count = frames;
    frames = 0;
    Check(client->ReleaseBuffer(count));
  }
  IAudioCaptureClient* client;
  UINT32 frames;
};

struct SampleFormat {
  bool floating_point;
  WORD bytes_per_sample;
  WORD channels;
  WORD frame_bytes;
  DWORD sample_rate;
};

SampleFormat ValidateFormat(const WAVEFORMATEX& format) {
  WORD tag = format.wFormatTag;
  if (tag == WAVE_FORMAT_EXTENSIBLE) {
    if (format.cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
      throw CaptureError::unsupported_format;
    }
    const auto& extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE&>(format);
    if (IsEqualGUID(extended.SubFormat, kPcmSubtype)) tag = WAVE_FORMAT_PCM;
    else if (IsEqualGUID(extended.SubFormat, kFloatSubtype)) tag = WAVE_FORMAT_IEEE_FLOAT;
    else throw CaptureError::unsupported_format;
    if (extended.Samples.wValidBitsPerSample == 0 ||
        extended.Samples.wValidBitsPerSample > format.wBitsPerSample ||
        (tag == WAVE_FORMAT_IEEE_FLOAT &&
         extended.Samples.wValidBitsPerSample != format.wBitsPerSample)) {
      throw CaptureError::unsupported_format;
    }
  }
  const bool floating = tag == WAVE_FORMAT_IEEE_FLOAT;
  const bool valid_bits = floating
      ? (format.wBitsPerSample == 32 || format.wBitsPerSample == 64)
      : (tag == WAVE_FORMAT_PCM &&
         (format.wBitsPerSample == 8 || format.wBitsPerSample == 16 ||
          format.wBitsPerSample == 24 || format.wBitsPerSample == 32));
  if (!valid_bits || format.nChannels == 0 || format.nChannels > 8 ||
      format.nSamplesPerSec < 8000 || format.nSamplesPerSec > 384000 ||
      format.nBlockAlign != format.nChannels * (format.wBitsPerSample / 8)) {
    throw CaptureError::unsupported_format;
  }
  return {floating, static_cast<WORD>(format.wBitsPerSample / 8),
          format.nChannels, format.nBlockAlign, format.nSamplesPerSec};
}

double ReadSample(const uint8_t* data, const SampleFormat& format) noexcept {
  if (format.floating_point) {
    double sample;
    if (format.bytes_per_sample == 4) {
      float value;
      std::memcpy(&value, data, sizeof(value));
      sample = value;
    } else {
      std::memcpy(&sample, data, sizeof(sample));
    }
    return std::isfinite(sample) ? std::clamp(sample, -1.0, 1.0) : 0.0;
  }
  switch (format.bytes_per_sample) {
    case 1: return (static_cast<int>(data[0]) - 128) / 128.0;
    case 2: {
      int16_t value;
      std::memcpy(&value, data, sizeof(value));
      return value / 32768.0;
    }
    case 3: {
      const uint32_t packed = static_cast<uint32_t>(data[0]) |
          (static_cast<uint32_t>(data[1]) << 8) |
          (static_cast<uint32_t>(data[2]) << 16);
      const int32_t value = (packed & 0x800000U) != 0
          ? static_cast<int32_t>(packed) - 0x1000000
          : static_cast<int32_t>(packed);
      return value / 8388608.0;
    }
    default: {
      int32_t value;
      std::memcpy(&value, data, sizeof(value));
      // Extensible PCM valid bits are left-aligned in their sample container.
      return value / 2147483648.0;
    }
  }
}

int16_t ToPcm16(double value) noexcept {
  if (value <= -1.0) return -32768;
  if (value >= 1.0) return 32767;
  return static_cast<int16_t>(std::lround(value * 32767.0));
}

void Write16(std::vector<uint8_t>& bytes, size_t offset, uint16_t value) {
  bytes[offset] = static_cast<uint8_t>(value & 0xffU);
  bytes[offset + 1] = static_cast<uint8_t>(value >> 8);
}

void Write32(std::vector<uint8_t>& bytes, size_t offset, uint32_t value) {
  for (size_t index = 0; index < 4; ++index) {
    bytes[offset + index] = static_cast<uint8_t>((value >> (index * 8)) & 0xffU);
  }
}

void WriteWavHeader(std::vector<uint8_t>& wav, DWORD sample_rate) {
  std::memcpy(wav.data(), "RIFF", 4);
  Write32(wav, 4, static_cast<uint32_t>(wav.size() - 8));
  std::memcpy(wav.data() + 8, "WAVEfmt ", 8);
  Write32(wav, 16, 16);
  Write16(wav, 20, WAVE_FORMAT_PCM);
  Write16(wav, 22, 1);  // Downmixed mono, with the original sample rate.
  Write32(wav, 24, sample_rate);
  Write32(wav, 28, sample_rate * 2);
  Write16(wav, 32, 2);
  Write16(wav, 34, 16);
  std::memcpy(wav.data() + 36, "data", 4);
  Write32(wav, 40, static_cast<uint32_t>(wav.size() - kWavHeaderBytes));
}

std::vector<uint8_t> Capture(const CaptureJob& job) {
  CheckCancelled(job);
  ComApartment apartment;
  Microsoft::WRL::ComPtr<IMMDeviceEnumerator> enumerator;
  Check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                         IID_PPV_ARGS(enumerator.GetAddressOf())));
  CheckCancelled(job);
  Microsoft::WRL::ComPtr<IMMDevice> device;
  Check(enumerator->GetDefaultAudioEndpoint(
      job.loopback ? eRender : eCapture, eConsole, device.GetAddressOf()));
  Microsoft::WRL::ComPtr<IAudioClient> audio;
  Check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(audio.GetAddressOf())));
  MixFormat mix;
  Check(audio->GetMixFormat(&mix.value));
  const auto format = ValidateFormat(*mix.value);
  const auto target_frames = static_cast<size_t>(
      (static_cast<uint64_t>(format.sample_rate) *
       static_cast<uint64_t>(job.duration_ms)) / 1000U);
  if (target_frames == 0 || target_frames > (kMaxWavBytes - kWavHeaderBytes) / 2) {
    throw CaptureError::unsupported_format;
  }
  std::vector<uint8_t> wav(kWavHeaderBytes + target_frames * 2, 0);
  CheckCancelled(job);
  // A short shared buffer and interruptible waits also support loopback on
  // older Windows versions that do not signal capture events for loopback.
  Check(audio->Initialize(AUDCLNT_SHAREMODE_SHARED,
      job.loopback ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0, 1000000, 0,
      mix.value, nullptr));
  Microsoft::WRL::ComPtr<IAudioCaptureClient> capture;
  Check(audio->GetService(IID_PPV_ARGS(capture.GetAddressOf())));
  StopAudio stop{audio.Get()};
  CheckCancelled(job);
  Check(audio->Start());
  stop.started = true;
  const auto deadline = std::chrono::steady_clock::now() +
      std::chrono::milliseconds(job.duration_ms);
  size_t written_frames = 0;
  std::optional<UINT64> next_device_frame;
  bool audible = false;
  while (written_frames < target_frames &&
         std::chrono::steady_clock::now() < deadline) {
    CheckCancelled(job);
    UINT32 packet_frames = 0;
    Check(capture->GetNextPacketSize(&packet_frames));
    while (packet_frames != 0 && written_frames < target_frames) {
      CheckCancelled(job);
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      UINT64 device_frame = 0;
      Check(capture->GetBuffer(&data, &frames, &flags, &device_frame, nullptr));
      ReleasePacket packet{capture.Get(), frames};
      if (frames == 0) break;
      // WASAPI explicitly marks unreliable device positions. Do not turn an
      // invalid timestamp into a large silence gap or truncate the recording.
      if ((flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) == 0) {
        if (next_device_frame && device_frame > *next_device_frame) {
          const auto gap = std::min<UINT64>(device_frame - *next_device_frame,
              static_cast<UINT64>(target_frames - written_frames));
          written_frames += static_cast<size_t>(gap);
        }
        next_device_frame = device_frame + frames;
      } else {
        next_device_frame.reset();
      }
      const auto count = std::min<size_t>(frames, target_frames - written_frames);
      const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
      if (!silent && data == nullptr) throw CaptureError::capture_failed;
      for (size_t frame = 0; frame < count; ++frame) {
        if ((frame & 255U) == 0) CheckCancelled(job);
        double sample = 0;
        if (!silent) {
          for (WORD channel = 0; channel < format.channels; ++channel) {
            sample += ReadSample(data + frame * format.frame_bytes +
                static_cast<size_t>(channel) * format.bytes_per_sample, format);
          }
          sample /= format.channels;
        }
        const auto pcm = ToPcm16(sample);
        audible = audible || pcm != 0;
        Write16(wav, kWavHeaderBytes + (written_frames + frame) * 2,
                static_cast<uint16_t>(pcm));
      }
      written_frames += count;
      // Consume the complete packet even when its tail exceeds the duration.
      packet.Release();
      if (std::chrono::steady_clock::now() >= deadline) break;
      Check(capture->GetNextPacketSize(&packet_frames));
    }
    if (written_frames < target_frames) {
      const auto waited = WaitForSingleObject(job.cancel_event, 10);
      if (waited == WAIT_OBJECT_0) throw CaptureError::cancelled;
      if (waited == WAIT_FAILED) throw CaptureError::capture_failed;
    }
  }
  CheckCancelled(job);
  if (!audible) throw CaptureError::no_audio;
  // Unreceived trailing frames remain silence, keeping the requested duration.
  WriteWavHeader(wav, format.sample_rate);
  return wav;
}

unsigned __stdcall CaptureWorker(void* context) noexcept {
  const std::unique_ptr<std::shared_ptr<CaptureJob>> holder(
      static_cast<std::shared_ptr<CaptureJob>*>(context));
  const auto job = *holder;
  CaptureOutcome outcome;
  try {
    outcome.wav = Capture(*job);
  } catch (CaptureError error) {
    outcome.error = error;
  } catch (...) {
    outcome.error = CaptureError::capture_failed;
  }
  // Capture has already stopped/released audio and uninitialized COM. No
  // Flutter objects or bridge pointers ever cross the worker boundary.
  try {
    std::lock_guard<std::mutex> lock(job->mutex);
    if (job->delivery_enabled) {
      job->outcome = std::move(outcome);
      PostMessageW(job->window, kCaptureComplete, 0, job->generation);
    }
  } catch (...) {}
  return 0;
}
}  // namespace

class MusicCaptureBridge::Impl {
 public:
  Impl(HWND window, flutter::BinaryMessenger* messenger)
      : window_(window), channel_(messenger, "hanmusic/music_capture",
          &flutter::StandardMethodCodec::GetInstance()) {
    channel_.SetMethodCallHandler([this](const auto& call, auto result) {
      try {
        if (call.method_name() == "capture") {
          BeginCapture(call.arguments(), std::move(result));
        } else if (call.method_name() == "cancel") {
          if (!job_) {
            result->Success();
          } else {
            cancel_results_.push_back(std::move(result));
            CancelCapture();
          }
        } else {
          result->NotImplemented();
        }
      } catch (...) {
        if (result) result->Error("capture_failed", "音频采样失败，请重试。");
      }
    });
  }

  ~Impl() {
    channel_.SetMethodCallHandler(nullptr);
    if (job_) {
      std::lock_guard<std::mutex> lock(job_->mutex);
      job_->delivery_enabled = false;
      SetEvent(job_->cancel_event);
    }
    CancelCapture();
    for (auto& result : cancel_results_) result->Success();
    // No UI-thread join: the worker keeps its event/state alive and releases
    // its own COM objects even if the audio driver is slow during shutdown.
    job_.reset();
  }

  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                     LRESULT* result) noexcept {
    if (message == kCaptureComplete) {
      if (job_ && job_->generation == lparam) Complete();
      *result = 0;
      return true;
    }
    if (message == WM_CLOSE ||
        (message == WM_POWERBROADCAST && wparam == PBT_APMSUSPEND) ||
        (message == WM_ENDSESSION && wparam != 0)) {
      CancelCapture();
    }
    return false;
  }

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  void BeginCapture(const flutter::EncodableValue* arguments,
                    std::unique_ptr<Result> result) {
    if (job_) {
      result->Error("capture_failed", "正在采样，请先取消或等待完成。");
      return;
    }
    const auto* values = arguments ? std::get_if<flutter::EncodableMap>(arguments) : nullptr;
    bool loopback = false;
    int64_t duration = kMaxDurationMs;
    if (!values) {
      result->Error("capture_failed", "采样参数无效。");
      return;
    }
    const auto source = values->find(flutter::EncodableValue("source"));
    const auto* source_name = source == values->end() ? nullptr : std::get_if<std::string>(&source->second);
    if (!source_name || (*source_name != "microphone" && *source_name != "loopback")) {
      result->Error("capture_failed", "采样来源无效。");
      return;
    }
    loopback = *source_name == "loopback";
    const auto duration_value = values->find(flutter::EncodableValue("durationMs"));
    if (duration_value != values->end()) {
      if (const auto* value32 = std::get_if<int32_t>(&duration_value->second)) duration = *value32;
      else if (const auto* value64 = std::get_if<int64_t>(&duration_value->second)) duration = *value64;
      else duration = 0;
    }
    if (duration < 1 || duration > kMaxDurationMs) {
      result->Error("capture_failed", "采样时长无效。");
      return;
    }
    try {
      auto job = std::make_shared<CaptureJob>();
      job->window = window_;
      job->generation = ++next_capture_generation;
      job->loopback = loopback;
      job->duration_ms = duration;
      job->cancel_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
      if (!job->cancel_event) throw CaptureError::capture_failed;
      auto context = std::make_unique<std::shared_ptr<CaptureJob>>(job);
      // The CRT worker adopts context only when _beginthreadex succeeds.
      const auto thread = _beginthreadex(nullptr, 0, CaptureWorker, context.get(), 0, nullptr);
      if (thread == 0) throw CaptureError::capture_failed;
      context.release();
      CloseHandle(reinterpret_cast<HANDLE>(thread));
      job_ = std::move(job);
      capture_result_ = std::move(result);
    } catch (...) {
      result->Error("capture_failed", "无法开始音频采样，请重试。");
    }
  }

  void CancelCapture() noexcept {
    if (job_) SetEvent(job_->cancel_event);
    if (capture_result_) {
      auto result = std::move(capture_result_);
      try { result->Error("cancelled", "采样已取消。"); } catch (...) {}
    }
  }

  void Complete() noexcept {
    try {
      std::optional<CaptureOutcome> outcome;
      {
        std::lock_guard<std::mutex> lock(job_->mutex);
        outcome = std::move(job_->outcome);
        job_->delivery_enabled = false;
      }
      if (!outcome) return;
      job_.reset();
      auto capture_result = std::move(capture_result_);
      auto cancel_results = std::move(cancel_results_);
      if (capture_result) {
        if (outcome->error == CaptureError::none) {
          capture_result->Success(flutter::EncodableValue(std::move(outcome->wav)));
        } else {
          capture_result->Error(ErrorCode(outcome->error), ErrorMessage(outcome->error));
        }
      }
      for (auto& result : cancel_results) result->Success();
    } catch (...) {
      CancelCapture();
    }
  }

  HWND window_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
  std::shared_ptr<CaptureJob> job_;
  std::unique_ptr<Result> capture_result_;
  std::vector<std::unique_ptr<Result>> cancel_results_;
};

MusicCaptureBridge::MusicCaptureBridge(HWND window, flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>(window, messenger)) {}
MusicCaptureBridge::~MusicCaptureBridge() = default;
bool MusicCaptureBridge::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                                       LRESULT* result) noexcept {
  return impl_->HandleMessage(message, wparam, lparam, result);
}
