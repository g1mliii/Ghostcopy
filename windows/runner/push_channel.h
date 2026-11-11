#ifndef RUNNER_PUSH_CHANNEL_H_
#define RUNNER_PUSH_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Windows Push Notification Services for the packaged (Store) build.
//
// A WNS raw notification wakes the running app the way FCM wakes a phone,
// so a desktop in the tray need not hold a realtime websocket open to learn
// that a clip arrived. Windows keeps one push connection for every app on
// the machine; this only asks it for a channel URI and listens on it.
//
// Dart side: lib/services/impl/windows_push_service.dart, channel
// "com.ghostcopy.app/push".
//   createChannel -> {"uri": String, "expiresAtMs": int}, or an error. Only a
//                    packaged process has the identity WNS needs.
//   received      <- sent to Dart for every raw notification. The payload is
//                    not forwarded: it carries only a row id, and the app
//                    polls for what is new rather than trusting a push.
//
// WinRT calls happen on worker threads (the platform thread is an STA with a
// message pump, where a blocking wait is not allowed), and their results
// come back to the platform thread as posted window messages, which is the
// only thread a Flutter channel may be used from.
class PushChannel {
 public:
  PushChannel(flutter::BinaryMessenger* messenger, HWND window,
              UINT channel_ready_message, UINT received_message);
  ~PushChannel();

  PushChannel(const PushChannel&) = delete;
  PushChannel& operator=(const PushChannel&) = delete;

  // Call from the window procedure for channel_ready_message.
  void OnChannelReady();

  // Call from the window procedure for received_message.
  void OnReceived();

 private:
  struct State;

  void CreateChannel(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::shared_ptr<State> state_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
      pending_result_;
};

#endif  // RUNNER_PUSH_CHANNEL_H_
