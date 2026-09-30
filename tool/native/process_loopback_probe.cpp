// Diagnostic-only process loopback. No endpoint/microphone fallback, PCM files,
// device selection, or system-volume changes. Windows SDK APIs only.
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <locale>
#include <memory>
#include <mutex>
#include <new>
#include <sstream>
#include <string>
#include <thread>

using Microsoft::WRL::ComPtr;

namespace {
constexpr uint64_t kClockUnits = 10000000;
constexpr uint32_t kRate = 48000;
constexpr uint16_t kChannels = 2;
// Detection threshold: +/-1 LSB can be conversion noise. The exported historic
// 'nonzero' field names count only signed 16-bit samples whose abs value > 1.
constexpr int kThreshold = 1;
constexpr DWORD kStartWaitMs = 9000;
constexpr DWORD kActivationWaitMs = 8000;
constexpr DWORD kStopWaitMs = 3000;

int64_t Qpc100ns() {
  LARGE_INTEGER ticks{}, frequency{};
  if (!QueryPerformanceCounter(&ticks) || !QueryPerformanceFrequency(&frequency)
      || frequency.QuadPart <= 0) return 0;
  // Split the quotient so normal machine uptimes cannot overflow ticks * 1e7.
  return (ticks.QuadPart / frequency.QuadPart) * kClockUnits +
      (ticks.QuadPart % frequency.QuadPart) * kClockUnits / frequency.QuadPart;
}

struct Event {
  explicit Event(bool manual = true)
      : value(CreateEventW(nullptr, manual, FALSE, nullptr)) {}
  ~Event() { if (value) CloseHandle(value); }
  Event(const Event&) = delete;
  HANDLE value;
};

struct WindowStats {
  int64_t arm = 0;
  uint64_t generation = 0;
  int64_t first = 0;
  int64_t last_frame_end = 0;  // Exclusive end of the last valid post-arm frame.
  uint64_t packets = 0, frames = 0, nonzero = 0;
  uint64_t discontinuities = 0, timestamp_errors = 0;
  double peak = 0;
};

struct Capture {
  Event stop, ready, done, activated;
  const DWORD pid = GetCurrentProcessId();
  std::mutex mutex;
  WindowStats window;
  bool running = false;
  bool format_ready = false;
  HRESULT error = S_OK;
  HRESULT start_result = E_PENDING;
  HRESULT activation_result = E_PENDING;
  ComPtr<IAudioClient> activated_client;
};

std::mutex g_current_mutex;
std::timed_mutex g_lifecycle;
std::shared_ptr<Capture> g_current;

std::shared_ptr<Capture> Current() {
  std::lock_guard<std::mutex> lock(g_current_mutex);
  return g_current;
}

void RecordError(const std::shared_ptr<Capture>& state, HRESULT hr) {
  if (SUCCEEDED(hr)) return;
  std::lock_guard<std::mutex> lock(state->mutex);
  if (SUCCEEDED(state->error)) state->error = hr;
}

void Ready(const std::shared_ptr<Capture>& state, HRESULT hr) {
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->start_result == E_PENDING) state->start_result = hr;
    if (FAILED(hr) && SUCCEEDED(state->error)) state->error = hr;
  }
  SetEvent(state->ready.value);
}

// The callback owns its state, has an explicit self-reference until completion,
// and is agile. A late OS callback cannot touch a destroyed worker stack.
class Activation final : public IActivateAudioInterfaceCompletionHandler,
                         public IAgileObject {
 public:
  explicit Activation(std::shared_ptr<Capture> state) : state_(std::move(state)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (iid == __uuidof(IUnknown) ||
        iid == __uuidof(IActivateAudioInterfaceCompletionHandler))
      *out = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
    else if (iid == __uuidof(IAgileObject))
      *out = static_cast<IAgileObject*>(this);
    else return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const auto remaining = --refs_;
    if (!remaining) delete this;
    return remaining;
  }
  HRESULT STDMETHODCALLTYPE ActivateCompleted(
      IActivateAudioInterfaceAsyncOperation* operation) override {
    HRESULT activation = E_UNEXPECTED;
    ComPtr<IUnknown> unknown;
    HRESULT hr = operation ? operation->GetActivateResult(&activation, &unknown)
                           : E_POINTER;
    if (SUCCEEDED(hr)) hr = activation;
    ComPtr<IAudioClient> client;
    if (SUCCEEDED(hr)) hr = unknown ? unknown.As(&client) : E_POINTER;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      state_->activation_result = hr;
      if (WaitForSingleObject(state_->stop.value, 0) != WAIT_OBJECT_0)
        state_->activated_client = client;
    }
    SetEvent(state_->activated.value);
    Release();  // The explicit callback-lifetime reference.
    return S_OK;
  }
 private:
  std::atomic<ULONG> refs_{1};
  std::shared_ptr<Capture> state_;
};

// All PCM inspection stays in memory. Statistics are committed only when no
// arm() happened while this packet was being inspected.
void ObservePacket(const std::shared_ptr<Capture>& state, const BYTE* bytes,
                   UINT32 count, DWORD flags, uint64_t packet_qpc) {
  WindowStats baseline;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    baseline = state->window;
  }
  if (baseline.arm <= 0 || !count) return;
  WindowStats delta;
  const bool bad_time = (flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) ||
      packet_qpc == 0 || packet_qpc > static_cast<uint64_t>(INT64_MAX) -
          uint64_t(count) * kClockUnits / kRate;
  if (bad_time) {
    // Its age cannot be established: do not count it as post-arm PCM. Invalidate
    // this whole timing window rather than calling a later packet the first.
    delta.timestamp_errors = 1;
  } else {
    const auto* samples = reinterpret_cast<const int16_t*>(bytes);
    const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
    for (UINT32 frame = 0; frame < count; ++frame) {
      const uint64_t when = packet_qpc + uint64_t(frame) * kClockUnits / kRate;
      if (when < static_cast<uint64_t>(baseline.arm)) continue;
      ++delta.frames;
      delta.last_frame_end = static_cast<int64_t>(
          packet_qpc + uint64_t(frame + 1) * kClockUnits / kRate);
      if (silent) continue;  // SILENT may legally supply a null data pointer.
      for (uint16_t channel = 0; channel < kChannels; ++channel) {
        const int sample = samples[uint64_t(frame) * kChannels + channel];
        const int magnitude = sample < 0 ? -sample : sample;
        delta.peak = std::max(delta.peak, magnitude / 32768.0);
        if (magnitude > kThreshold) {
          ++delta.nonzero;
          if (!delta.first) delta.first = static_cast<int64_t>(when);
        }
      }
    }
    delta.packets = delta.frames ? 1 : 0;
  }
  if (delta.frames || bad_time)
    delta.discontinuities = (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) ? 1 : 0;
  std::lock_guard<std::mutex> lock(state->mutex);
  auto& stats = state->window;
  if (stats.generation != baseline.generation) return;
  stats.packets += delta.packets;
  stats.frames += delta.frames;
  stats.last_frame_end = std::max(stats.last_frame_end, delta.last_frame_end);
  stats.nonzero += delta.nonzero;
  stats.peak = std::max(stats.peak, delta.peak);
  stats.discontinuities += delta.discontinuities;
  stats.timestamp_errors += delta.timestamp_errors;
  if (stats.timestamp_errors) stats.first = 0;
  else if (!stats.first && delta.first) stats.first = delta.first;
}

HRESULT CaptureLoop(const std::shared_ptr<Capture>& state) {
  AUDIOCLIENT_ACTIVATION_PARAMS parameters{};
  parameters.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  parameters.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
  parameters.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
  PROPVARIANT value{};
  value.vt = VT_BLOB;
  value.blob.cbSize = sizeof(parameters);
  value.blob.pBlobData = reinterpret_cast<BYTE*>(&parameters);
  auto* callback = new (std::nothrow) Activation(state);
  if (!callback) return E_OUTOFMEMORY;
  callback->AddRef();  // Released by the callback, even after our timeout.
  ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
  HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
      __uuidof(IAudioClient), &value, callback, &operation);
  if (FAILED(hr)) callback->Release();
  callback->Release();  // Drop the caller's construction reference.
  if (FAILED(hr)) return hr;
  HANDLE activation_events[] = {state->stop.value, state->activated.value};
  const DWORD activation_wait = WaitForMultipleObjects(2, activation_events,
      FALSE, kActivationWaitMs);
  if (activation_wait == WAIT_OBJECT_0) return HRESULT_FROM_WIN32(ERROR_CANCELLED);
  if (activation_wait == WAIT_TIMEOUT) return HRESULT_FROM_WIN32(WAIT_TIMEOUT);
  if (activation_wait != WAIT_OBJECT_0 + 1) return HRESULT_FROM_WIN32(GetLastError());

  ComPtr<IAudioClient> client;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    hr = state->activation_result;
    client = std::move(state->activated_client);
  }
  if (FAILED(hr)) return hr;
  if (!client) return E_POINTER;
  WAVEFORMATEX format{};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = kChannels;
  format.nSamplesPerSec = kRate;
  format.wBitsPerSample = 16;
  format.nBlockAlign = kChannels * sizeof(int16_t);
  format.nAvgBytesPerSec = kRate * format.nBlockAlign;
  hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
      AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, 0, 0, &format, nullptr);
  if (FAILED(hr)) return hr;  // No retry with a different capture source/format.
  Event audio_ready(false);
  if (!audio_ready.value) return HRESULT_FROM_WIN32(GetLastError());
  ComPtr<IAudioCaptureClient> capture;
  hr = client->GetService(IID_PPV_ARGS(&capture));
  if (FAILED(hr)) return hr;
  hr = client->SetEventHandle(audio_ready.value);
  if (FAILED(hr)) return hr;
  if (WaitForSingleObject(state->stop.value, 0) == WAIT_OBJECT_0)
    return HRESULT_FROM_WIN32(ERROR_CANCELLED);
  hr = client->Start();
  if (FAILED(hr)) return hr;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->format_ready = true;
    state->running = true;
  }
  Ready(state, S_OK);
  HANDLE events[] = {state->stop.value, audio_ready.value};
  bool stop = false;
  while (!stop && SUCCEEDED(hr)) {
    const DWORD wait = WaitForMultipleObjects(2, events, FALSE, 100);
    if (wait == WAIT_OBJECT_0) break;
    if (wait != WAIT_OBJECT_0 + 1 && wait != WAIT_TIMEOUT) {
      hr = HRESULT_FROM_WIN32(GetLastError());
      break;
    }
    // Polling on a 100ms timeout also detects device errors if no event arrives.
    while (SUCCEEDED(hr)) {
      if (WaitForSingleObject(state->stop.value, 0) == WAIT_OBJECT_0) {
        stop = true;
        break;
      }
      UINT32 available = 0;
      hr = capture->GetNextPacketSize(&available);
      if (FAILED(hr) || available == 0) break;
      BYTE* bytes = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      UINT64 device = 0, qpc = 0;
      hr = capture->GetBuffer(&bytes, &frames, &flags, &device, &qpc);
      if (hr == AUDCLNT_S_BUFFER_EMPTY) { hr = S_OK; break; }
      if (FAILED(hr)) break;
      if (frames && !bytes && !(flags & AUDCLNT_BUFFERFLAGS_SILENT)) hr = E_POINTER;
      if (SUCCEEDED(hr)) ObservePacket(state, bytes, frames, flags, qpc);
      // GetBuffer/ReleaseBuffer always run on this worker, including failure.
      const HRESULT release = capture->ReleaseBuffer(frames);
      if (SUCCEEDED(hr) && FAILED(release)) hr = release;
    }
  }
  RecordError(state, hr);
  const HRESULT stopped = client->Stop();
  RecordError(state, stopped);
  if (SUCCEEDED(hr)) hr = stopped;
  return hr;
}

void Worker(std::shared_ptr<Capture> state) noexcept {
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  HRESULT hr = com;
  if (SUCCEEDED(com)) {
    try { hr = CaptureLoop(state); }
    catch (...) { hr = E_UNEXPECTED; }
    CoUninitialize();
  }
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->running = false;
  }
  RecordError(state, hr);
  Ready(state, hr);
  SetEvent(state->done.value);
}

std::string Snapshot() {
  auto state = Current();
  WindowStats stats;
  bool running = false, format_ready = false;
  HRESULT error = S_OK;
  if (state) {
    std::lock_guard<std::mutex> lock(state->mutex);
    stats = state->window;
    running = state->running;
    format_ready = state->format_ready;
    error = state->error;
  }
  std::ostringstream out;
  out.imbue(std::locale::classic());
  out << std::setprecision(10) << "{\"schemaVersion\":1,\"targetProcessId\":"
      << GetCurrentProcessId() << ",\"mode\":\"include-current-process-tree\",";
  out << "\"running\":" << (running ? "true" : "false")
      << ",\"armQpc100ns\":" << stats.arm << ",\"firstNonzeroQpc100ns\":";
  if (stats.first) out << stats.first; else out << "null";
  out << ",\"capturedThroughQpc100ns\":";
  if (stats.last_frame_end) out << stats.last_frame_end; else out << "null";
  out << ",\"observedQpc100ns\":" << Qpc100ns()
      << ",\"packets\":" << stats.packets << ",\"frames\":" << stats.frames
      << ",\"nonzeroSamples\":" << stats.nonzero << ",\"peakAbs\":" << stats.peak
      << ",\"discontinuities\":" << stats.discontinuities
      << ",\"timestampErrors\":" << stats.timestamp_errors
      << ",\"errorHresult\":" << static_cast<int32_t>(error)
      << ",\"captureFormat\":{\"sampleRateHz\":" << (format_ready ? kRate : 0)
      << ",\"channels\":" << (format_ready ? kChannels : 0)
      << ",\"bitsPerSample\":" << (format_ready ? 16 : 0) << "}"
      << ",\"detectionThresholdS16AbsExclusive\":" << kThreshold << "}";
  return out.str();
}
}  // namespace

extern "C" __declspec(dllexport) int32_t hm_capture_start() noexcept {
  try {
    std::unique_lock<std::timed_mutex> lifecycle(g_lifecycle, std::defer_lock);
    if (!lifecycle.try_lock_for(std::chrono::milliseconds(100)))
      return HRESULT_FROM_WIN32(ERROR_BUSY);
    auto old = Current();
    if (old && WaitForSingleObject(old->done.value, 0) != WAIT_OBJECT_0) {
      std::lock_guard<std::mutex> lock(old->mutex);
      return old->running ? S_OK : HRESULT_FROM_WIN32(ERROR_BUSY);
    }
    // Diagnostic DLL deliberately remains loaded until process termination.
    // If an OS COM call never returns, bounded exports must not unload code
    // beneath its worker/callback. Nothing attempts TerminateThread.
    HMODULE pinned = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
        GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&hm_capture_start), &pinned))
      return HRESULT_FROM_WIN32(GetLastError());
    auto state = std::make_shared<Capture>();
    if (!state->stop.value || !state->ready.value || !state->done.value || !state->activated.value)
      return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_MEMORY);
    {
      std::lock_guard<std::mutex> lock(g_current_mutex);
      g_current = state;
    }
    try { std::thread(Worker, state).detach(); }
    catch (...) {
      Ready(state, E_UNEXPECTED);
      SetEvent(state->done.value);
      return E_UNEXPECTED;
    }
    const DWORD wait = WaitForSingleObject(state->ready.value, kStartWaitMs);
    if (wait != WAIT_OBJECT_0) {
      const HRESULT hr = HRESULT_FROM_WIN32(wait == WAIT_TIMEOUT ? WAIT_TIMEOUT : GetLastError());
      RecordError(state, hr);
      SetEvent(state->stop.value);
      return hr;
    }
    std::lock_guard<std::mutex> lock(state->mutex);
    return state->start_result;
  } catch (...) { return E_UNEXPECTED; }
}

extern "C" __declspec(dllexport) int64_t hm_capture_arm() noexcept {
  try {
    auto state = Current();
    if (!state) return 0;
    std::lock_guard<std::mutex> lock(state->mutex);
    if (!state->running || FAILED(state->error)) return 0;
    const uint64_t generation = state->window.generation + 1;
    state->window = WindowStats{};
    state->window.generation = generation;
    state->window.arm = Qpc100ns();
    return state->window.arm;
  } catch (...) { return 0; }
}

extern "C" __declspec(dllexport) const char* hm_capture_snapshot() noexcept {
  thread_local std::string copy;
  try { copy = Snapshot(); return copy.c_str(); }
  catch (...) { return "{\"schemaVersion\":1,\"errorHresult\":-2147418113}"; }
}

extern "C" __declspec(dllexport) void hm_capture_stop() noexcept {
  try {
    auto state = Current();
    if (!state) return;
    SetEvent(state->stop.value);
    const DWORD wait = WaitForSingleObject(state->done.value, kStopWaitMs);
    if (wait != WAIT_OBJECT_0)
      RecordError(state, HRESULT_FROM_WIN32(wait == WAIT_TIMEOUT ? WAIT_TIMEOUT : GetLastError()));
  } catch (...) {}
}

#ifdef HM_CAPTURE_SELF_TEST
// No rendering is performed. The actual DLL, not these executable exports, is
// loaded below. The synthetic packet checks only exercise in-memory arithmetic.
bool PacketChecks() {
  auto state = std::make_shared<Capture>();
  state->window.arm = 1000100;
  int16_t samples[] = {20, 20, 1, -1, 5, -8, 0, 0};
  ObservePacket(state, reinterpret_cast<BYTE*>(samples), 4, 0, 1000000);
  if (state->window.frames != 3 || state->window.nonzero != 2 ||
      state->window.first != 1000416 ||
      state->window.last_frame_end != 1000833) return false;
  // A wholly pre-arm packet must not add frames or move the coverage boundary.
  ObservePacket(state, reinterpret_cast<BYTE*>(samples), 4, 0, 999000);
  if (state->window.frames != 3 || state->window.last_frame_end != 1000833)
    return false;
  ObservePacket(state, nullptr, 4, AUDCLNT_BUFFERFLAGS_SILENT, 1001000);
  if (state->window.nonzero != 2 || state->window.last_frame_end != 1001833)
    return false;
  ObservePacket(state, reinterpret_cast<BYTE*>(samples), 4,
      AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR, 0);
  if (state->window.last_frame_end != 1001833) return false;
  ObservePacket(state, reinterpret_cast<BYTE*>(samples), 4, 0, 1002000);
  return state->window.timestamp_errors == 1 && state->window.first == 0;
}

int wmain(int argc, wchar_t** argv) {
  if (argc != 2 || !PacketChecks()) return 2;
  const HMODULE dll = LoadLibraryW(argv[1]);
  if (!dll) return 3;
  const auto start = reinterpret_cast<int32_t(*)()>(GetProcAddress(dll, "hm_capture_start"));
  const auto arm = reinterpret_cast<int64_t(*)()>(GetProcAddress(dll, "hm_capture_arm"));
  const auto snapshot = reinterpret_cast<const char*(*)()>(GetProcAddress(dll, "hm_capture_snapshot"));
  const auto stop = reinterpret_cast<void(*)()>(GetProcAddress(dll, "hm_capture_stop"));
  if (!start || !arm || !snapshot || !stop) return 4;
  const auto start_at = GetTickCount64();
  const int32_t hr = start();
  const auto start_ms = GetTickCount64() - start_at;
  const int64_t armed = hr == 0 ? arm() : 0;
  Sleep(300);  // Capture only this test process; it never opens a render stream.
  const std::string before = snapshot();
  const auto stop_at = GetTickCount64();
  stop();
  const auto stop_ms = GetTickCount64() - stop_at;
  const std::string after = snapshot();
  const bool passed = hr == 0 && armed > 0 && start_ms <= 10000 && stop_ms <= 3500 &&
      before.find("\"running\":true") != std::string::npos &&
      before.find("\"nonzeroSamples\":0,") != std::string::npos &&
      before.find("\"firstNonzeroQpc100ns\":null") != std::string::npos &&
      before.find("\"capturedThroughQpc100ns\":null") == std::string::npos &&
      before.find("\"frames\":0,") == std::string::npos &&
      after.find("\"running\":false") != std::string::npos &&
      after.find("\"errorHresult\":0,") != std::string::npos;
  std::cout << "{\"passed\":" << (passed ? "true" : "false")
      << ",\"inMemoryPacketChecks\":true,\"audioRendered\":false,\"startHresult\":" << hr
      << ",\"startMs\":" << start_ms << ",\"stopMs\":" << stop_ms
      << ",\"beforeStop\":" << before << ",\"afterStop\":" << after << "}\n";
  FreeLibrary(dll);  // Pinned deliberately: late callbacks remain safe.
  return passed ? 0 : 1;
}
#endif
