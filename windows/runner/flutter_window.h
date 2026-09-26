#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "power_monitor.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_change_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      packaging_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      memory_channel_;

  // The clipboard change counter answered on clipboard_change_channel_, and
  // the state it is derived from; see ClipboardChangeCount().
  int64_t ClipboardChangeCount();

  // Renders this process's own clipboard data up front, so that a later
  // delayed render cannot be mistaken for the user copying.
  void FlushOwnedClipboard();

  DWORD last_clipboard_sequence_ = 0;

  /// True while a deferred flush is already queued, so a burst of clipboard
  /// updates collapses into one rather than filling the message queue.
  bool flush_posted_ = false;
  int64_t clipboard_change_count_ = 0;

  // Power state monitor for sleep/wake/lock events
  std::unique_ptr<PowerMonitor> power_monitor_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
