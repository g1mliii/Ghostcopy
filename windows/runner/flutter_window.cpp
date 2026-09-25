#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include <wtsapi32.h>

#include "flutter/generated_plugin_registrant.h"
#include "package_context.h"
#include "power_monitor.h"

namespace {

// Must match the TaskId of the <uap5:StartupTask> in the package manifest,
// which msix_config's `startup_task` entry in pubspec.yaml generates.
constexpr wchar_t kStartupTaskId[] = L"GhostCopyStartup";

// Posted to this window to run FlushOwnedClipboard outside the message it was
// triggered by. WM_APP is the range reserved for an application's own
// messages, so it cannot collide with anything Windows or Flutter sends.
constexpr UINT kFlushClipboardMessage = WM_APP + 1;

// Sent to Dart as a string rather than an index so that adding a state later
// cannot silently renumber the others. Mirrors StartupState in
// lib/services/impl/windows_package_service.dart.
const char* StartupStateName(ghostcopy::StartupState state) {
  switch (state) {
    case ghostcopy::StartupState::kDisabled:
      return "disabled";
    case ghostcopy::StartupState::kDisabledByUser:
      return "disabledByUser";
    case ghostcopy::StartupState::kDisabledByPolicy:
      return "disabledByPolicy";
    case ghostcopy::StartupState::kEnabled:
      return "enabled";
    case ghostcopy::StartupState::kEnabledByPolicy:
      return "enabledByPolicy";
    case ghostcopy::StartupState::kUnavailable:
      break;
  }
  return "unavailable";
}

}  // namespace

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

  // Everything about running inside an MSIX package that Dart has to know.
  // `isPackaged` decides whether the self-registration in main.dart runs at
  // all, because MSIX virtualizes the HKCU writes it does; the startup calls
  // replace launch_at_startup's Run key with the <uap5:StartupTask> declared
  // in the manifest. See package_context.h.
  packaging_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.ghostcopy.app/packaging",
          &flutter::StandardMethodCodec::GetInstance());
  packaging_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& method = call.method_name();
        if (method == "isPackaged") {
          result->Success(flutter::EncodableValue(ghostcopy::IsPackaged()));
          return;
        }

        ghostcopy::StartupState state;
        if (method == "startupState") {
          state = ghostcopy::GetStartupState(kStartupTaskId);
        } else if (method == "enableStartup") {
          state = ghostcopy::RequestEnableStartup(kStartupTaskId);
        } else if (method == "disableStartup") {
          state = ghostcopy::DisableStartup(kStartupTaskId);
        } else {
          result->NotImplemented();
          return;
        }
        result->Success(flutter::EncodableValue(StartupStateName(state)));
      });

  // Hand the working set back to Windows when the app goes to the tray.
  //
  // Hidden, this process sits at ~107 MB of working set that is mostly mapped
  // modules - the GPU driver and the Flutter engine - which no cache in the
  // app can release. What Windows does allow is trimming: the pages move to
  // the standby list, where the OS can reuse them for something else and
  // hands them back on a soft fault if this app touches them again.
  //
  // Honest about what this is: committed memory does not change, so this is
  // not the app needing less. It is the app not holding physical pages it is
  // not using while it sits in the tray for hours, which is the state it is
  // in almost all of its life.
  memory_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.ghostcopy.app/memory",
          &flutter::StandardMethodCodec::GetInstance());
  memory_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "trimWorkingSet") {
          result->NotImplemented();
          return;
        }
        // (SIZE_T)-1 for both bounds is the documented way to ask for a trim
        // rather than to set a limit; it does not cap future growth.
        const BOOL ok = ::SetProcessWorkingSetSizeEx(
            ::GetCurrentProcess(), static_cast<SIZE_T>(-1),
            static_cast<SIZE_T>(-1), 0);
        result->Success(flutter::EncodableValue(ok != 0));
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

// The clipboard's change counter.
//
// GetClipboardSequenceNumber moves whenever clipboard content changes - which
// includes the owner rendering a delayed format. GhostCopy writes through
// OleSetClipboard, which renders on demand, so pasting a clip GhostCopy wrote
// into Word used to bump the number: smart auto-receive read that as the user
// copying, and only offered the next clip instead of taking it.
//
// That was first filtered by ignoring a bump while the same window of this
// process still owned the clipboard. It worked, and cost the opposite bug: a
// second copy in a row from the Spotlight looks identical from outside, so it
// was ignored too, and auto-send skipped it.
//
// FlushOwnedClipboard below removes the need to guess. Rendering everything up
// front means there is no later delayed render to mistake for a copy, so every
// sequence change is a real one and this can simply count them.
int64_t FlutterWindow::ClipboardChangeCount() {
  const DWORD sequence = GetClipboardSequenceNumber();
  if (sequence == last_clipboard_sequence_) return clipboard_change_count_;
  last_clipboard_sequence_ = sequence;
  ++clipboard_change_count_;
  return clipboard_change_count_;
}

// Render GhostCopy's own clipboard data immediately, instead of on demand.
//
// Called after every clipboard change rather than from the write itself, so no
// Dart write path has to remember to - super_clipboard, Clipboard.setData and
// the smart action buttons all go through the clipboard, and therefore through
// here.
//
// Flushing renders each format and hands ownership back to the system, so the
// clipboard still holds the data and GetClipboardOwner becomes null. That ends
// the recursion this would otherwise have: the flush changes the sequence
// number, which posts one more WM_CLIPBOARDUPDATE, and by then this process no
// longer owns the clipboard so nothing flushes again.
//
// The cost is rendering large formats up front rather than only if something
// asks. Bounded here: a clip is at most 100 KB of text or a 10 MB file
// (ClipboardLimits), so this is milliseconds, and it buys a counter that does
// not have to distinguish a render from a copy.
void FlutterWindow::FlushOwnedClipboard() {
  const HWND owner = GetClipboardOwner();
  if (!owner) return;
  DWORD owner_process = 0;
  GetWindowThreadProcessId(owner, &owner_process);
  if (owner_process != GetCurrentProcessId()) return;
  // Only meaningful for data this process put there with OLE; harmless
  // otherwise, and the owner check above already narrows it to our own.
  ::OleFlushClipboard();
}

void FlutterWindow::OnDestroy() {
  // Unregister from session change notifications
  WTSUnRegisterSessionNotification(GetHandle());
  RemoveClipboardFormatListener(GetHandle());

  // Clean up power monitor
  if (power_monitor_) {
    power_monitor_ = nullptr;
  }

  clipboard_change_channel_ = nullptr;
  packaging_channel_ = nullptr;
  memory_channel_ = nullptr;
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
      // Posted, not called. OleFlushClipboard renders every format and can
      // pump messages while it does, and this is running inside the window
      // procedure that Flutter's controller has already been handed - so a
      // synchronous flush can re-enter HandleTopLevelWindowProc, including
      // with the very WM_CLIPBOARDUPDATE the flush itself raises. Posting
      // lets the current message finish first.
      if (!flush_posted_) {
        flush_posted_ = true;
        ::PostMessage(hwnd, kFlushClipboardMessage, 0, 0);
      }
      break;
    }

    case kFlushClipboardMessage:
      flush_posted_ = false;
      FlushOwnedClipboard();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
