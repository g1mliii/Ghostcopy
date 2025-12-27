#ifndef RUNNER_POWER_MONITOR_H_
#define RUNNER_POWER_MONITOR_H_

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <wtsapi32.h>

#include <memory>

// Monitors system power events and session state changes
// Sends events to Flutter via MethodChannel
class PowerMonitor {
 public:
  explicit PowerMonitor(flutter::FlutterEngine* engine);
  ~PowerMonitor();

  // Handle WM_POWERBROADCAST messages
  void HandlePowerBroadcast(WPARAM wparam);

  // Handle WTS_SESSION_CHANGE messages
  void HandleSessionChange(WPARAM wparam);

 private:
  void SendEvent(const std::string& event_name);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_POWER_MONITOR_H_
