#include "flutter_window.h"

#include <optional>
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

  // Initialize power monitor for system sleep/wake/lock events
  power_monitor_ =
      std::make_unique<PowerMonitor>(flutter_controller_->engine());

  // Register for session change notifications (lock/unlock)
  WTSRegisterSessionNotification(GetHandle(), NOTIFY_FOR_THIS_SESSION);

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

void FlutterWindow::OnDestroy() {
  // Unregister from session change notifications
  WTSUnRegisterSessionNotification(GetHandle());

  // Clean up power monitor
  if (power_monitor_) {
    power_monitor_ = nullptr;
  }

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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
