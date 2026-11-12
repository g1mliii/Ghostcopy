#include "gpu_watchdog.h"

GpuWatchdog::GpuWatchdog(HWND window, UINT message)
    : window_(window), message_(message) {
  Microsoft::WRL::ComPtr<ID3D11Device> device;
  // The default adapter, which is the one ANGLE draws on unless told
  // otherwise. No feature level list: any hardware device will do, since it
  // only has to exist.
  if (FAILED(::D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 0, nullptr, 0, D3D11_SDK_VERSION,
                                 device.GetAddressOf(), nullptr, nullptr))) {
    return;
  }
  if (FAILED(device.As(&device_))) {
    return;
  }

  removed_event_ = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (removed_event_ == nullptr) {
    return;
  }
  if (FAILED(device_->RegisterDeviceRemovedEvent(removed_event_, &cookie_))) {
    return;
  }
  registered_ = true;

  // Once: the first removal is the one that matters, and the window restarts
  // the app in response.
  ::RegisterWaitForSingleObject(&wait_, removed_event_, OnDeviceRemoved, this,
                                INFINITE, WT_EXECUTEONLYONCE);
}

GpuWatchdog::~GpuWatchdog() {
  if (wait_ != nullptr) {
    // INVALID_HANDLE_VALUE waits for a callback already running to finish,
    // so it cannot post to a window that is being torn down after this.
    ::UnregisterWaitEx(wait_, INVALID_HANDLE_VALUE);
  }
  if (registered_) {
    device_->UnregisterDeviceRemoved(cookie_);
  }
  if (removed_event_ != nullptr) {
    ::CloseHandle(removed_event_);
  }
}

void CALLBACK GpuWatchdog::OnDeviceRemoved(PVOID context, BOOLEAN timed_out) {
  if (timed_out) {
    return;
  }
  auto* self = static_cast<GpuWatchdog*>(context);
  ::PostMessageW(self->window_, self->message_, 0, 0);
}
