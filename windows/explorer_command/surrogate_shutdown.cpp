#include "surrogate_shutdown.h"

#include <windows.h>

#include <appmodel.h>
#include <wchar.h>

#include <string>

#include "module.h"

namespace ghostcopy {

namespace {

constexpr wchar_t kWindowClass[] = L"GhostCopyShellShutdownListener";

// How long the first activation waits for the listener's window. Creating it
// takes microseconds; this only bounds a thread that is slow to be
// scheduled, so the first right-click cannot visibly stall on it.
constexpr DWORD kWindowWaitMs = 1000;

// How long a close request waits for sends already under way. One activation
// per selected file is quick, but a large selection is a loop of them, and
// cutting it short would send the first files and silently drop the rest.
constexpr ULONGLONG kDrainLimitMs = 10000;

// Only the surrogate is ours to end, and only the one running under the
// package's identity: that is the process an update has to close, and a
// dllhost without it - one shared with other COM servers under a generic
// AppID, say - is not ours to take down. The name check is what keeps an
// in-process registration from taking Explorer down with it.
//
// Stricter than the runner's IsPackaged(), which counts any answer but "no
// package" as packaged: before a TerminateProcess, only the one answer that
// means a package is there will do.
bool IsSurrogateHost() {
  UINT32 length = 0;
  if (::GetCurrentPackageFullName(&length, nullptr) !=
      ERROR_INSUFFICIENT_BUFFER) {
    return false;
  }
  const std::wstring path = ModulePath(nullptr);
  // npos + 1 is 0, so a path without a separator is compared whole.
  return ::_wcsicmp(path.substr(path.find_last_of(L'\\') + 1).c_str(),
                    L"dllhost.exe") == 0;
}

// Sends under way, so a close request lets them finish.
LONG g_invokes = 0;

// Ends the surrogate outright, once any send already under way is done or
// has had its time. Past that it holds nothing worth flushing - every
// command hands its work to ghostcopy.exe and returns - and ExitProcess would
// run every loaded module's detach code with Explorer's calls still in
// flight on other threads. Explorer sees the server disconnect, and the next
// right-click starts a fresh one. Polled rather than signalled: it runs once,
// just before the process ends.
void EndSurrogate() {
  const ULONGLONG deadline = ::GetTickCount64() + kDrainLimitMs;
  while (::InterlockedCompareExchange(&g_invokes, 0, 0) > 0 &&
         ::GetTickCount64() < deadline) {
    ::Sleep(50);
  }
  ::TerminateProcess(::GetCurrentProcess(), 0);
}

// WM_QUERYENDSESSION needs no case: DefWindowProc already agrees to it.
LRESULT CALLBACK ListenerProc(HWND window, UINT message, WPARAM wparam,
                              LPARAM lparam) {
  switch (message) {
    case WM_ENDSESSION:
      // FALSE means another application vetoed: the session goes on.
      if (wparam) EndSurrogate();
      return 0;
    case WM_CLOSE:
      EndSurrogate();
      return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

// The handshake between the first activation and the listener thread. One
// attempt at a time: a retry happens only after an attempt that finished and
// failed, and a wait that timed out is never retried, so a thread is never
// still writing these when the next attempt resets them.
HANDLE g_window_settled = nullptr;
bool g_window_created = false;

HWND CreateListenerWindow(HINSTANCE module) {
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = ListenerProc;
  window_class.hInstance = module;
  window_class.lpszClassName = kWindowClass;
  // Already registered by an earlier attempt whose window then failed.
  if (!::RegisterClassExW(&window_class) &&
      ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return nullptr;
  }

  // Top-level, never shown, and kept off the taskbar and Alt+Tab. Not
  // HWND_MESSAGE: end-session messages are not sent to a message-only window.
  return ::CreateWindowExW(WS_EX_TOOLWINDOW, kWindowClass, L"", WS_POPUP, 0,
                           0, 0, 0, nullptr, nullptr, module, nullptr);
}

DWORD WINAPI ListenerThread(void* module) {
  const HWND window = CreateListenerWindow(static_cast<HINSTANCE>(module));
  g_window_created = window != nullptr;
  ::SetEvent(g_window_settled);
  if (!window) return 0;

  MSG message;
  while (::GetMessageW(&message, nullptr, 0, 0) > 0) {
    ::DispatchMessageW(&message);
  }
  return 0;
}

// FALSE on a failure, which leaves the INIT_ONCE unset so the next
// activation tries again: one transient failure must not leave a surrogate
// Explorer keeps alive for days unable to hear an update.
BOOL CALLBACK StartOnce(PINIT_ONCE, void*, void**) {
  if (!IsSurrogateHost()) return TRUE;

  // Pinned, because the listener thread runs this module's code for as long
  // as the process lives, and COM unloads a DLL whose DllCanUnloadNow says
  // it may. The surrogate still exits when Explorer lets go of the last
  // command: that follows COM's object count, not whether the module stays.
  HMODULE module = nullptr;
  if (!::GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                GET_MODULE_HANDLE_EX_FLAG_PIN,
                            reinterpret_cast<LPCWSTR>(&ListenerProc),
                            &module)) {
    return FALSE;
  }

  if (!g_window_settled) {
    g_window_settled = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_window_settled) return FALSE;
  }
  ::ResetEvent(g_window_settled);

  const HANDLE thread =
      ::CreateThread(nullptr, 0, ListenerThread, module, 0, nullptr);
  if (!thread) return FALSE;
  ::CloseHandle(thread);

  // Not returned to COM until the window exists: until then the surrogate
  // is as windowless as before, and an update that asks it to close in that
  // gap would wait out the full timeout this is here to remove. A timeout
  // counts as started - the thread is alive and will get there - but a
  // window that failed is retried on the next activation.
  const bool settled =
      ::WaitForSingleObject(g_window_settled, kWindowWaitMs) == WAIT_OBJECT_0;
  return settled && !g_window_created ? FALSE : TRUE;
}

}  // namespace

void StartShutdownListener() {
  static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
  ::InitOnceExecuteOnce(&once, StartOnce, nullptr, nullptr);
}

InvokeInProgress::InvokeInProgress() { ::InterlockedIncrement(&g_invokes); }

InvokeInProgress::~InvokeInProgress() { ::InterlockedDecrement(&g_invokes); }

}  // namespace ghostcopy
