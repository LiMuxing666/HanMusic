#ifndef RUNNER_MUSIC_CAPTURE_BRIDGE_H_
#define RUNNER_MUSIC_CAPTURE_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <memory>

// Capture starts only through the explicit Dart capture method. Results belong
// to the window thread; each worker owns its COM/audio resources independently.
class MusicCaptureBridge {
 public:
  MusicCaptureBridge(HWND window, flutter::BinaryMessenger* messenger);
  ~MusicCaptureBridge();
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                     LRESULT* result) noexcept;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_MUSIC_CAPTURE_BRIDGE_H_
