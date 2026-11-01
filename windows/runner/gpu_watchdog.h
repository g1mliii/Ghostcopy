#ifndef RUNNER_GPU_WATCHDOG_H_
#define RUNNER_GPU_WATCHDOG_H_

#include <d3d11_4.h>
#include <windows.h>
#include <wrl/client.h>

// Tells a window when the GPU has been reset underneath the app.
//
// A graphics driver update - or a GPU timeout reset, or Win+Ctrl+Shift+B -
// removes every Direct3D device on the system, the one Flutter's engine draws
// through (via ANGLE) among them. The engine does not recreate it, so every
// Flutter window, the Spotlight and the tray menu alike, is left showing a
// blank white surface that never redraws, and nothing short of a restart
// brings it back.
//
// The engine gives no signal for this, so the watchdog keeps a small device of
// its own as a tripwire: a removal takes it down with the engine's, and
// ID3D11Device4::RegisterDeviceRemovedEvent signals an event when it goes. A
// threadpool wait on that event posts |message| to |window|, so the reaction
// runs on the UI thread with everything else.
//
// Best effort: on a system without ID3D11Device4 (before Windows 10 1703) or
// without a hardware device the watchdog does nothing, which is how the app
// behaved before it existed.
class GpuWatchdog {
 public:
  GpuWatchdog(HWND window, UINT message);
  ~GpuWatchdog();

  GpuWatchdog(const GpuWatchdog&) = delete;
  GpuWatchdog& operator=(const GpuWatchdog&) = delete;

 private:
  static void CALLBACK OnDeviceRemoved(PVOID context, BOOLEAN timed_out);

  HWND window_;
  UINT message_;
  Microsoft::WRL::ComPtr<ID3D11Device4> device_;
  HANDLE removed_event_ = nullptr;
  HANDLE wait_ = nullptr;
  DWORD cookie_ = 0;
  bool registered_ = false;
};

#endif  // RUNNER_GPU_WATCHDOG_H_
