#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include <wtsapi32.h>

#include "flutter/generated_plugin_registrant.h"
#include "power_monitor.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  feedback_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.ghostcopy/send_file",
          &flutter::StandardMethodCodec::GetInstance());
  feedback_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "showResult") {
          result->NotImplemented();
          return;
        }
        const auto* text = call.arguments()
            ? std::get_if<std::string>(call.arguments()) : nullptr;
        if (!text) {
          result->Error("invalid_message", "Expected a message string");
          return;
        }
        const int length = MultiByteToWideChar(
            CP_UTF8, 0, text->data(), static_cast<int>(text->size()), nullptr, 0);
        std::wstring wide(length, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, text->data(),
                           static_cast<int>(text->size()), wide.data(), length);
        MessageBoxW(nullptr, wide.c_str(), L"GhostCopy",
                    MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND);
        result->Success();
      });

  // The clipboard's change counter, the Windows twin of NSPasteboard's
  // changeCount on macOS (ClipboardChangeCount.swift). One integer, no
  // clipboard read: smart auto-receive uses it to tell when the user last
  // copied something, and auto-send to skip reading an unchanged clipboard.
  // See ClipboardChangeCount() for why it is not the raw sequence number.
  // Unlike macOS it is also pushed: WM_CLIPBOARDUPDATE below sends "changed"
  // whenever it moves, so Dart needs no timer to notice a copy.
  clipboard_change_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.ghostcopy.app/clipboard_change",
          &flutter::StandardMethodCodec::GetInstance());
  clipboard_change_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "changeCount") {
          result->NotImplemented();
          return;
        }
        result->Success(flutter::EncodableValue(ClipboardChangeCount()));
      });

  // Initialize power monitor for system sleep/wake/lock events
  power_monitor_ =
      std::make_unique<PowerMonitor>(flutter_controller_->engine());

  // Register for session change notifications (lock/unlock)
  WTSRegisterSessionNotification(GetHandle(), NOTIFY_FOR_THIS_SESSION);

  // WM_CLIPBOARDUPDATE on every clipboard change; see MessageHandler.
  AddClipboardFormatListener(GetHandle());

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    if (flutter_controller_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

// GetClipboardSequenceNumber also moves when the owner renders a delayed
// format, and GhostCopy's writes go through OleSetClipboard, which renders on
// demand. Pasting a clip GhostCopy wrote into Word therefore bumped the raw
// number, smart auto-receive read that as the user copying, and the next clip
// inside the stale window was only offered. So the counter reported here only
// moves when the clipboard changes hands: a sequence change while the same
// window of this process still owns it is that owner rendering, not new
// content. A new copy in any other app, or a GhostCopy write that takes the
// clipboard over, changes the owner and counts. It is evaluated on every
// WM_CLIPBOARDUPDATE, so each change is judged against the owner of the one
// before it. The cost is that two copies in a row from the same GhostCopy
// window read as one.
int64_t FlutterWindow::ClipboardChangeCount() {
  const DWORD sequence = GetClipboardSequenceNumber();
  if (sequence == last_clipboard_sequence_) return clipboard_change_count_;
  last_clipboard_sequence_ = sequence;

  const HWND owner = GetClipboardOwner();
  DWORD owner_process = 0;
  if (owner) GetWindowThreadProcessId(owner, &owner_process);
  const bool owned_here = owner && owner_process == GetCurrentProcessId();
  if (!(owned_here && owner == last_clipboard_owner_)) {
    ++clipboard_change_count_;
  }
  last_clipboard_owner_ = owner;
  return clipboard_change_count_;
}

void FlutterWindow::OnDestroy() {
  // Unregister from session change notifications
  WTSUnRegisterSessionNotification(GetHandle());
  RemoveClipboardFormatListener(GetHandle());

  // Clean up power monitor
  if (power_monitor_) {
    power_monitor_ = nullptr;
  }

  feedback_channel_ = nullptr;
  clipboard_change_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case WM_POWERBROADCAST:
      // Handle system sleep/wake events
      if (power_monitor_) {
        power_monitor_->HandlePowerBroadcast(wparam);
      }
      break;

    case WM_WTSSESSION_CHANGE:
      // Handle session lock/unlock events
      if (power_monitor_) {
        power_monitor_->HandleSessionChange(wparam);
      }
      break;

    case WM_CLIPBOARDUPDATE: {
      // Dart reads the counter itself when told, and ignores the call while
      // nothing is watching it.
      const int64_t before = clipboard_change_count_;
      if (ClipboardChangeCount() != before && clipboard_change_channel_) {
        clipboard_change_channel_->InvokeMethod("changed", nullptr);
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
