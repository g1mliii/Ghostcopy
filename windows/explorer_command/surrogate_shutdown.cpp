#include "surrogate_shutdown.h"

#include <windows.h>

#include <appmodel.h>
#include <wchar.h>

#include <new>
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
bool IsSurrogateHost() {
  UINT32 length = 0;
  if (::GetCurrentPackageFullName(&length, nullptr) !=
      ERROR_INSUFFICIENT_BUFFER) {
    return false;
  }
  const std::wstring path = ModulePath(nullptr);
  const size_t separator = path.find_last_of(L'\\');
  const wchar_t* name = path.c_str() + (separator == std::wstring::npos
                                             ? 0
                                             : separator + 1);
  return !path.empty() && ::_wcsicmp(name, L"dllhost.exe") == 0;
}

// Sends under way, so a close request lets them finish. Guarded by a lock
// rather than an interlocked count because the close waits on it.
SRWLOCK g_invoke_lock = SRWLOCK_INIT;
CONDITION_VARIABLE g_invokes_done = CONDITION_VARIABLE_INIT;
LONG g_invokes = 0;

// Ends the surrogate outright, once any send already under way is done or
// has had its time. Past that it holds nothing worth flushing - every
// command hands its work to ghostcopy.exe and returns - and ExitProcess would
// run every loaded module's detach code with Explorer's calls still in
// flight on other threads. Explorer sees the server disconnect, and the next
// right-click starts a fresh one.
void EndSurrogate() {
  const ULONGLONG deadline = ::GetTickCount64() + kDrainLimitMs;
  ::AcquireSRWLockExclusive(&g_invoke_lock);
  while (g_invokes > 0) {
    const ULONGLONG now = ::GetTickCount64();
    if (now >= deadline) break;
    ::SleepConditionVariableSRW(&g_invokes_done, &g_invoke_lock,
                                static_cast<DWORD>(deadline - now), 0);
  }
  ::ReleaseSRWLockExclusive(&g_invoke_lock);
  ::TerminateProcess(::GetCurrentProcess(), 0);
}

LRESULT CALLBACK ListenerProc(HWND window, UINT message, WPARAM wparam,
                              LPARAM lparam) {
  switch (message) {
    case WM_QUERYENDSESSION:
      return TRUE;
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

// The handshake between the first activation and the listener thread. Two
// references, one each, so whichever finishes last frees it - the activation
// may stop waiting before the thread is done with it.
struct Startup {
  HMODULE module;
  HANDLE settled;
  bool created = false;
  LONG references = 2;
};

void Release(Startup* startup) {
  if (::InterlockedDecrement(&startup->references) == 0) {
    ::CloseHandle(startup->settled);
    delete startup;
  }
}

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
  // HWND_MESSAGE: a message-only window is exactly what the surrogate
  // already had, and end-session messages are not sent to one.
  return ::CreateWindowExW(WS_EX_TOOLWINDOW, kWindowClass, L"", WS_POPUP, 0,
                           0, 0, 0, nullptr, nullptr, module, nullptr);
}

DWORD WINAPI ListenerThread(void* parameter) {
  auto* startup = static_cast<Startup*>(parameter);
  const HWND window = CreateListenerWindow(startup->module);
  startup->created = window != nullptr;
  ::SetEvent(startup->settled);
  Release(startup);
  if (!window) return 0;

  MSG message;
  while (::GetMessageW(&message, nullptr, 0, 0) > 0) {
    ::TranslateMessage(&message);
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

  auto* startup = new (std::nothrow) Startup{module};
  if (!startup) return FALSE;
  startup->settled = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!startup->settled) {
    delete startup;
    return FALSE;
  }

  const HANDLE thread =
      ::CreateThread(nullptr, 0, ListenerThread, startup, 0, nullptr);
  if (!thread) {
    ::CloseHandle(startup->settled);
    delete startup;
    return FALSE;
  }
  ::CloseHandle(thread);

  // Not returned to COM until the window exists: until then the surrogate
  // is as windowless as before, and an update that asks it to close in that
  // gap would wait out the full timeout this is here to remove. A timeout
  // counts as started - the thread is alive and will get there - but a
  // window that failed is retried on the next activation.
  const bool settled =
      ::WaitForSingleObject(startup->settled, kWindowWaitMs) == WAIT_OBJECT_0;
  const bool failed = settled && !startup->created;
  Release(startup);
  return failed ? FALSE : TRUE;
}

}  // namespace

void StartShutdownListener() {
  static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
  ::InitOnceExecuteOnce(&once, StartOnce, nullptr, nullptr);
}

InvokeInProgress::InvokeInProgress() {
  ::AcquireSRWLockExclusive(&g_invoke_lock);
  ++g_invokes;
  ::ReleaseSRWLockExclusive(&g_invoke_lock);
}

InvokeInProgress::~InvokeInProgress() {
  ::AcquireSRWLockExclusive(&g_invoke_lock);
  if (--g_invokes == 0) ::WakeAllConditionVariable(&g_invokes_done);
  ::ReleaseSRWLockExclusive(&g_invoke_lock);
}

}  // namespace ghostcopy
