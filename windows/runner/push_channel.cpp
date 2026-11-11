#include "push_channel.h"

#include <flutter/standard_method_codec.h>

#include <mutex>
#include <string>
#include <thread>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.PushNotifications.h>

#include "package_context.h"

namespace {

using winrt::Windows::Networking::PushNotifications::PushNotificationChannel;
using winrt::Windows::Networking::PushNotifications::
    PushNotificationChannelManager;
using winrt::Windows::Networking::PushNotifications::
    PushNotificationReceivedEventArgs;
using winrt::Windows::Networking::PushNotifications::PushNotificationType;

}  // namespace

// Shared with the worker thread and the WinRT event handler, either of which
// can outlive the window: both check |alive| before posting to it.
struct PushChannel::State {
  std::mutex mutex;
  bool alive = true;
  HWND window = nullptr;
  UINT channel_ready_message = 0;
  UINT received_message = 0;

  // The channel and its event registration. Held so the handler stays
  // subscribed; replaced when a new channel is requested.
  PushNotificationChannel channel{nullptr};
  winrt::event_token received_token{};

  // The outcome of the last request, read on the platform thread.
  bool succeeded = false;
  std::string uri;
  std::string error;

  void Post(UINT message) {
    std::lock_guard<std::mutex> lock(mutex);
    if (alive) ::PostMessage(window, message, 0, 0);
  }

  // Stop listening on the current channel, if any. Call with |mutex| held.
  void Unsubscribe() {
    if (!channel) return;
    try {
      channel.PushNotificationReceived(received_token);
    } catch (const winrt::hresult_error&) {
    }
  }
};

PushChannel::PushChannel(flutter::BinaryMessenger* messenger, HWND window,
                         UINT channel_ready_message, UINT received_message)
    : state_(std::make_shared<State>()) {
  state_->window = window;
  state_->channel_ready_message = channel_ready_message;
  state_->received_message = received_message;

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.ghostcopy.app/push",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "createChannel") {
          CreateChannel(std::move(result));
        } else {
          result->NotImplemented();
        }
      });
}

PushChannel::~PushChannel() {
  std::lock_guard<std::mutex> lock(state_->mutex);
  state_->alive = false;
  state_->Unsubscribe();
}

void PushChannel::CreateChannel(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!ghostcopy::IsPackaged()) {
    // WNS needs package identity; the unpackaged build stays on realtime.
    result->Error("unpackaged", "WNS needs a packaged app");
    return;
  }
  if (pending_result_) {
    // One request at a time; the caller retries on its own schedule.
    result->Error("busy", "A channel request is already running");
    return;
  }
  pending_result_ = std::move(result);

  // Detached: the request can retry internally for minutes on a bad network,
  // and shutting the app down must not wait for it. |state| keeps what it
  // writes alive past the window.
  std::thread([state = state_] {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (const winrt::hresult_error&) {
    }
    bool succeeded = false;
    std::string uri;
    std::string error;
    PushNotificationChannel channel{nullptr};
    try {
      channel = PushNotificationChannelManager::
                    CreatePushNotificationChannelForApplicationAsync()
                        .get();
      uri = winrt::to_string(channel.Uri());
      succeeded = true;
    } catch (const winrt::hresult_error& e) {
      error = winrt::to_string(e.message());
      if (error.empty()) error = "hresult " + std::to_string(e.code().value);
    }

    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (succeeded) {
        state->Unsubscribe();
        state->channel = channel;
        std::weak_ptr<State> weak = state;
        state->received_token = channel.PushNotificationReceived(
            [weak](const PushNotificationChannel&,
                   const PushNotificationReceivedEventArgs& args) {
              if (args.NotificationType() != PushNotificationType::Raw) return;
              // Handled here: nothing for Windows to show or route on.
              args.Cancel(true);
              if (auto shared = weak.lock()) {
                shared->Post(shared->received_message);
              }
            });
      }
      state->succeeded = succeeded;
      state->uri = std::move(uri);
      state->error = std::move(error);
    }
    state->Post(state->channel_ready_message);
    winrt::uninit_apartment();
  }).detach();
}

void PushChannel::OnChannelReady() {
  if (!pending_result_) return;
  auto result = std::move(pending_result_);
  std::lock_guard<std::mutex> lock(state_->mutex);
  if (!state_->succeeded) {
    result->Error("channel_failed", state_->error);
    return;
  }
  flutter::EncodableMap map;
  map[flutter::EncodableValue("uri")] = flutter::EncodableValue(state_->uri);
  result->Success(flutter::EncodableValue(map));
}

void PushChannel::OnReceived() {
  channel_->InvokeMethod("received", nullptr);
}
