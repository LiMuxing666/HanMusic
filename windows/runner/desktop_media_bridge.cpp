#include "desktop_media_bridge.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <windowsx.h>

#include <atomic>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "resource.h"

namespace {
constexpr UINT kMediaAction = WM_APP + 71;
constexpr UINT kTrayMessage = WM_APP + 72;
constexpr UINT kRevealResult = WM_APP + 73;
constexpr UINT kTrayId = 1;
constexpr UINT kMenuOwnerPositionFlags =
    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER;
enum class Action : WPARAM { play = 1, pause, next, previous, toggle };
enum MenuCommand : UINT { kShow = 1, kToggle, kPrevious, kNext, kExit };
std::atomic<LONG_PTR> next_generation{0};

struct CallbackState {
  std::atomic<bool> active{true};
  HWND window;
  LONG_PTR generation;
  // Accessed only on the window thread, including nested menu dispatch.
  bool menu_open = false;
  bool menu_owner_promoted = false;
  std::mutex reveal_mutex;
  std::vector<std::pair<uint64_t, HRESULT>> reveal_results;
};

void RestoreMenuOwner(const std::shared_ptr<CallbackState>& state) noexcept {
  if (!state || !state->menu_owner_promoted) return;
  // Clear first: SetWindowPos can synchronously dispatch window messages.
  state->menu_owner_promoted = false;
  if (IsWindow(state->window)) {
    SetWindowPos(state->window, HWND_NOTOPMOST, 0, 0, 0, 0,
                 kMenuOwnerPositionFlags);
  }
}

bool ReadBool(const flutter::EncodableMap& values, const char* key) {
  const auto found = values.find(flutter::EncodableValue(key));
  return found != values.end() && std::holds_alternative<bool>(found->second) &&
         std::get<bool>(found->second);
}

std::wstring ReadText(const flutter::EncodableMap& values, const char* key) {
  const auto found = values.find(flutter::EncodableValue(key));
  if (found == values.end()) return {};
  const auto* text = std::get_if<std::string>(&found->second);
  return text ? std::wstring(winrt::to_hstring(*text)) : std::wstring{};
}
}  // namespace

class DesktopMediaBridge::Impl {
 public:
  Impl(HWND window, flutter::BinaryMessenger* messenger)
      : window_(window),
        taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")),
        channel_(messenger, "hanmusic/desktop_media",
                 &flutter::StandardMethodCodec::GetInstance()) {
    channel_.SetMethodCallHandler(
        [this](const auto& call, auto result) {
          try {
            if (call.method_name() == "initialize") {
              Initialize();
              result->Success(flutter::EncodableValue(flutter::EncodableMap{
                  {flutter::EncodableValue("mediaControls"),
                   flutter::EncodableValue(static_cast<bool>(controls_))},
                  {flutter::EncodableValue("tray"),
                   flutter::EncodableValue(tray_added_)}}));
            } else if (call.method_name() == "updateState") {
              const auto* values = call.arguments()
                  ? std::get_if<flutter::EncodableMap>(call.arguments())
                  : nullptr;
              if (!values || !started_) {
                result->Success(flutter::EncodableValue(false));
                return;
              }
              Update(*values);
              result->Success(flutter::EncodableValue(true));
            } else if (call.method_name() == "hideToTray") {
              if (!started_ || (!tray_added_ && !AddTray())) {
                result->Success(flutter::EncodableValue(false));
                return;
              }
              ShowWindow(window_, SW_HIDE);
              result->Success(flutter::EncodableValue(!IsWindowVisible(window_)));
            } else if (call.method_name() == "showWindow") {
              ShowWindowAndFocus();
              result->Success(flutter::EncodableValue(true));
            } else if (call.method_name() == "revealFile") {
              const auto* path = call.arguments()
                  ? std::get_if<std::string>(call.arguments()) : nullptr;
              if (!path || path->empty() || path->find('\0') != std::string::npos ||
                  !started_ || !callbacks_) {
                result->Error("reveal_failed", "File selection is unavailable.");
                return;
              }
              const auto wide_path = std::wstring(winrt::to_hstring(*path));
              RevealFile(wide_path, std::move(result));
            } else if (call.method_name() == "dispose") {
              Dispose();
              result->Success();
            } else {
              result->NotImplemented();
            }
          } catch (...) {
            result->Error("desktop_media", "Windows media integration failed.");
          }
        });
  }

  ~Impl() {
    channel_.SetMethodCallHandler(nullptr);
    Dispose();
  }

  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                     LRESULT* result) noexcept {
    try {
      if (message == kRevealResult) {
        if (callbacks_ && lparam == callbacks_->generation) {
          std::vector<std::pair<uint64_t, HRESULT>> completed;
          {
            std::lock_guard<std::mutex> lock(callbacks_->reveal_mutex);
            completed.swap(callbacks_->reveal_results);
          }
          for (const auto& entry : completed) {
            const auto found = pending_reveals_.find(entry.first);
            if (found == pending_reveals_.end()) continue;
            const auto reply = found->second;
            pending_reveals_.erase(found);
            if (SUCCEEDED(entry.second)) reply->Success(flutter::EncodableValue(true));
            else reply->Error("reveal_failed", "Unable to select the file in Explorer.");
          }
        }
        *result = 0;
        return true;
      }
      if (message == kMediaAction) {
        if (started_ && callbacks_ && lparam == callbacks_->generation) {
          SendAction(static_cast<Action>(wparam));
        }
        *result = 0;
        return true;
      }
      if (message == kTrayMessage) {
        if (started_) {
          const auto event = tray_version_4_ ? LOWORD(lparam)
                                            : static_cast<UINT>(lparam);
          if (event == WM_LBUTTONDBLCLK || event == NIN_KEYSELECT ||
              event == NIN_SELECT) {
            ShowWindowAndFocus();
          } else if (event == WM_CONTEXTMENU || event == WM_RBUTTONUP) {
            ShowMenu(event, wparam);
          }
        }
        *result = 0;
        return true;
      }
      if (taskbar_created_ != 0 && message == taskbar_created_ && started_) {
        tray_added_ = false;
        if (!AddTray() && !IsWindowVisible(window_)) ShowWindowAndFocus();
      }
    } catch (...) {
      // Exceptions must never unwind through Win32's window procedure.
    }
    return false;
  }

 private:
  void Initialize() {
    if (started_) return;
    started_ = true;
    callbacks_ = std::make_shared<CallbackState>();
    callbacks_->window = window_;
    callbacks_->generation = ++next_generation;
    try {
      winrt::init_apartment(winrt::apartment_type::single_threaded);
      apartment_initialized_ = true;
      auto factory = winrt::get_activation_factory<
          winrt::Windows::Media::SystemMediaTransportControls,
          ISystemMediaTransportControlsInterop>();
      winrt::check_hresult(factory->GetForWindow(
          window_, winrt::guid_of<winrt::Windows::Media::SystemMediaTransportControls>(),
          winrt::put_abi(controls_)));
      controls_.IsEnabled(false);
      const auto state = callbacks_;
      button_token_ = controls_.ButtonPressed(
          [state](const auto&, const auto& args) noexcept {
            try {
              if (!state->active.load()) return;
              Action action;
              using Button = winrt::Windows::Media::SystemMediaTransportControlsButton;
              switch (args.Button()) {
                case Button::Play: action = Action::play; break;
                case Button::Pause:
                case Button::Stop: action = Action::pause; break;
                case Button::Next: action = Action::next; break;
                case Button::Previous: action = Action::previous; break;
                default: return;
              }
              PostMessageW(state->window, kMediaAction,
                           static_cast<WPARAM>(action), state->generation);
            } catch (...) {}
          });
      button_registered_ = true;
    } catch (...) {
      controls_ = nullptr;
    }
    AddTray();
  }

  void Dispose() noexcept {
    started_ = false;
    if (callbacks_) {
      callbacks_->active.store(false);
      RestoreMenuOwner(callbacks_);
    }
    for (const auto& pending : pending_reveals_) {
      pending.second->Error("reveal_cancelled", "The player is closing.");
    }
    pending_reveals_.clear();
    if (controls_) {
      try {
        if (button_registered_) controls_.ButtonPressed(button_token_);
        controls_.IsEnabled(false);
        controls_.DisplayUpdater().ClearAll();
        controls_.DisplayUpdater().Update();
      } catch (...) {}
      controls_ = nullptr;
    }
    button_registered_ = false;
    callbacks_.reset();
    if (tray_added_) {
      Shell_NotifyIconW(NIM_DELETE, &tray_);
      tray_added_ = false;
    }
    tray_version_4_ = false;
    if (apartment_initialized_) {
      winrt::uninit_apartment();
      apartment_initialized_ = false;
    }
  }

  bool AddTray() {
    if (tray_added_) return true;
    tray_version_4_ = false;
    tray_ = {};
    tray_.cbSize = sizeof(tray_);
    tray_.hWnd = window_;
    tray_.uID = kTrayId;
    tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    tray_.uCallbackMessage = kTrayMessage;
    tray_.hIcon = static_cast<HICON>(LoadImageW(
        GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED));
    CopyTooltip();
    tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
    if (tray_added_) {
      tray_.uVersion = NOTIFYICON_VERSION_4;
      tray_version_4_ = Shell_NotifyIconW(NIM_SETVERSION, &tray_) != FALSE;
    }
    return tray_added_;
  }

  void RevealFile(
      const std::wstring& path,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto reply = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
    const auto id = ++next_reveal_id_;
    try {
      pending_reveals_[id] = reply;
      const auto state = callbacks_;
      std::thread([state, id, path]() {
        HRESULT status = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        if (SUCCEEDED(status)) {
          PIDLIST_ABSOLUTE item = nullptr;
          const DWORD attributes = GetFileAttributesW(path.c_str());
          if (!state->active.load()) {
            status = HRESULT_FROM_WIN32(ERROR_CANCELLED);
          } else if (attributes == INVALID_FILE_ATTRIBUTES) {
            status = HRESULT_FROM_WIN32(GetLastError());
          } else if ((attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
            status = HRESULT_FROM_WIN32(ERROR_DIRECTORY);
          } else {
            status = SHParseDisplayName(path.c_str(), nullptr, &item, 0, nullptr);
            if (SUCCEEDED(status) && state->active.load()) {
              // With cidl=0 this is a complete file PIDL: Explorer opens its
              // parent and selects the file, not merely the containing folder.
              status = SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
            }
          }
          CoTaskMemFree(item);
          CoUninitialize();
        }
        std::lock_guard<std::mutex> lock(state->reveal_mutex);
        if (!state->active.load()) return;
        state->reveal_results.emplace_back(id, status);
        PostMessageW(state->window, kRevealResult, 0, state->generation);
      }).detach();
    } catch (...) {
      pending_reveals_.erase(id);
      reply->Error("reveal_failed", "Unable to start file selection.");
    }
  }

  void CopyTooltip() {
    auto tip = title_.empty() ? std::wstring(L"HanMusic")
                             : title_ + (artist_.empty() ? L"" : L" — " + artist_);
    if (tip.size() > 127) tip.resize(127);
    if (!tip.empty() && tip.back() >= 0xD800 && tip.back() <= 0xDBFF) tip.pop_back();
    wcsncpy_s(tray_.szTip, tip.c_str(), _TRUNCATE);
  }

  void Update(const flutter::EncodableMap& values) {
    title_ = ReadText(values, "title");
    artist_ = ReadText(values, "artist");
    const auto album = ReadText(values, "album");
    const auto has_track = ReadBool(values, "hasTrack");
    playing_ = ReadBool(values, "playing");
    can_play_ = ReadBool(values, "canPlay");
    can_pause_ = ReadBool(values, "canPause");
    can_navigate_ = ReadBool(values, "canNavigate");
    if (tray_added_) {
      CopyTooltip();
      Shell_NotifyIconW(NIM_MODIFY, &tray_);
    }
    if (!controls_) return;
    using namespace winrt::Windows::Media;
    controls_.IsEnabled(has_track && ReadBool(values, "enabled"));
    controls_.IsPlayEnabled(can_play_);
    controls_.IsPauseEnabled(can_pause_);
    controls_.IsStopEnabled(can_pause_);
    controls_.IsNextEnabled(can_navigate_);
    controls_.IsPreviousEnabled(can_navigate_);
    controls_.PlaybackStatus(!has_track ? MediaPlaybackStatus::Closed
        : playing_ ? MediaPlaybackStatus::Playing : MediaPlaybackStatus::Paused);
    auto display = controls_.DisplayUpdater();
    if (has_track) {
      display.Type(MediaPlaybackType::Music);
      display.MusicProperties().Title(title_);
      display.MusicProperties().Artist(artist_);
      display.MusicProperties().AlbumTitle(album);
    } else {
      display.ClearAll();
    }
    display.Update();
  }

  void ShowWindowAndFocus() {
    ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(window_);
  }

  void SendAction(Action action) {
    if (!started_) return;
    const char* name = nullptr;
    switch (action) {
      case Action::play: name = "play"; break;
      case Action::pause: name = "pause"; break;
      case Action::next: name = "next"; break;
      case Action::previous: name = "previous"; break;
      case Action::toggle: name = "toggle"; break;
    }
    if (name) channel_.InvokeMethod("action", std::make_unique<flutter::EncodableValue>(name));
  }

  void ShowMenu(UINT event, WPARAM anchor) {
    // TrackPopupMenu pumps messages, including a possible window destruction.
    // Keep only independent state across that nested loop and check it before
    // touching this object again.
    const auto state = callbacks_;
    const auto window = window_;
    if (!state || !state->active.load() || state->menu_open) return;
    HMENU menu = CreatePopupMenu();
    if (!menu) return;
    AppendMenuW(menu, MF_STRING, kShow, L"显示 HanMusic");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING | (can_play_ || (playing_ && can_pause_) ? 0 : MF_GRAYED),
                kToggle, playing_ ? L"暂停" : L"播放");
    const UINT navigate_flags = MF_STRING | (can_navigate_ ? 0 : MF_GRAYED);
    AppendMenuW(menu, navigate_flags, kPrevious, L"上一首");
    AppendMenuW(menu, navigate_flags, kNext, L"下一首");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kExit, L"退出");
    POINT point{};
    GetCursorPos(&point);
    if (tray_version_4_ && event == WM_RBUTTONUP) {
      point = {GET_X_LPARAM(anchor), GET_Y_LPARAM(anchor)};
    } else if (tray_version_4_ && event == WM_CONTEXTMENU) {
      // Unlike mouse notifications, WM_CONTEXTMENU has no documented wParam
      // anchor. Use the icon's screen rectangle for keyboard invocation, while
      // retaining a mouse position that is already inside the icon.
      NOTIFYICONIDENTIFIER identifier{};
      identifier.cbSize = sizeof(identifier);
      identifier.hWnd = window;
      identifier.uID = kTrayId;
      RECT bounds{};
      if (SUCCEEDED(Shell_NotifyIconGetRect(&identifier, &bounds)) &&
          !PtInRect(&bounds, point)) {
        point = {bounds.left + (bounds.right - bounds.left) / 2,
                 bounds.top + (bounds.bottom - bounds.top) / 2};
      }
    }
    state->menu_open = true;
    SetForegroundWindow(window);
    if (state->active.load() &&
        (GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TOPMOST) == 0) {
      // A topmost owner gives its menu the same Z-order band as the Shell's
      // overflow flyout. Do not show, move, resize, or activate the hidden owner.
      state->menu_owner_promoted = true;
      // SetWindowPos dispatches messages synchronously. Dispose may restore and
      // clear the marker before this outer promotion completes, so record the
      // final result again for the inactive cleanup path below.
      state->menu_owner_promoted =
          SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                       kMenuOwnerPositionFlags) != FALSE;
    }
    if (!state->active.load()) {
      DestroyMenu(menu);
      RestoreMenuOwner(state);
      state->menu_open = false;
      return;
    }
    const auto command = TrackPopupMenu(
        menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, window, nullptr);
    DestroyMenu(menu);
    RestoreMenuOwner(state);
    state->menu_open = false;
    if (!state->active.load()) return;
    PostMessageW(window, WM_NULL, 0, 0);
    switch (command) {
      case kShow: ShowWindowAndFocus(); break;
      case kToggle: SendAction(Action::toggle); break;
      case kPrevious: SendAction(Action::previous); break;
      case kNext: SendAction(Action::next); break;
      case kExit:
        // Expose save-error confirmation if exit is canceled. Never destroy the
        // window or terminate the process outside Flutter's normal close path.
        ShowWindowAndFocus();
        PostMessageW(window_, WM_CLOSE, 0, 0);
        break;
      default: Shell_NotifyIconW(NIM_SETFOCUS, &tray_); break;
    }
  }

  HWND window_;
  UINT taskbar_created_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
  winrt::Windows::Media::SystemMediaTransportControls controls_{nullptr};
  winrt::event_token button_token_{};
  std::shared_ptr<CallbackState> callbacks_;
  std::map<uint64_t, std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>> pending_reveals_;
  uint64_t next_reveal_id_ = 0;
  NOTIFYICONDATAW tray_{};
  bool started_ = false;
  bool button_registered_ = false;
  bool apartment_initialized_ = false;
  bool tray_added_ = false;
  bool tray_version_4_ = false;
  bool playing_ = false;
  bool can_play_ = false;
  bool can_pause_ = false;
  bool can_navigate_ = false;
  std::wstring title_;
  std::wstring artist_;
};

DesktopMediaBridge::DesktopMediaBridge(HWND window, flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>(window, messenger)) {}
DesktopMediaBridge::~DesktopMediaBridge() = default;
bool DesktopMediaBridge::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                                       LRESULT* result) noexcept {
  return impl_->HandleMessage(message, wparam, lparam, result);
}
