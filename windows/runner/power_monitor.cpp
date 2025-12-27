#include "power_monitor.h"

#include <flutter/flutter_engine.h>
#include <flutter/standard_method_codec.h>

PowerMonitor::PowerMonitor(flutter::FlutterEngine* engine) {
  // Create method channel for power events
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "com.ghostcopy.app/power",
      &flutter::StandardMethodCodec::GetInstance());

  // Handle method calls from Flutter
  channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "startListening") {
          // No-op on Windows - we automatically listen via message pump
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

PowerMonitor::~PowerMonitor() {
  // Cleanup is automatic - channel will be destroyed
}

void PowerMonitor::HandlePowerBroadcast(WPARAM wparam) {
  switch (wparam) {
    case PBT_APMSUSPEND:
      // System is suspending operation
      SendEvent("systemSuspend");
      break;

    case PBT_APMRESUMEAUTOMATIC:
    case PBT_APMRESUMESUSPEND:
      // System has resumed from suspend
      SendEvent("systemResume");
      break;

    default:
      // Ignore other power broadcast messages
      break;
  }
}

void PowerMonitor::HandleSessionChange(WPARAM wparam) {
  switch (wparam) {
    case WTS_SESSION_LOCK:
      // Session has been locked
      SendEvent("sessionLock");
      break;

    case WTS_SESSION_UNLOCK:
      // Session has been unlocked
      SendEvent("sessionUnlock");
      break;

    default:
      // Ignore other session change messages
      break;
  }
}

void PowerMonitor::SendEvent(const std::string& event_name) {
  if (channel_) {
    channel_->InvokeMethod(event_name, nullptr);
  }
}
