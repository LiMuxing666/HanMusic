#ifndef RUNNER_DESKTOP_MEDIA_BRIDGE_H_
#define RUNNER_DESKTOP_MEDIA_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <memory>

// Owns the HWND-bound SMTC session and notification-area icon. All channel and
// shell work runs on the window thread; WinRT events only post window messages.
class DesktopMediaBridge {
 public:
  DesktopMediaBridge(HWND window, flutter::BinaryMessenger* messenger);
  ~DesktopMediaBridge();
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                     LRESULT* result) noexcept;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_DESKTOP_MEDIA_BRIDGE_H_
