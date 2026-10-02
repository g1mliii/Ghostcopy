#include "surrogate_shutdown.h"

#include <windows.h>

#include <wchar.h>

namespace ghostcopy {

namespace {

constexpr wchar_t kWindowClass[] = L"GhostCopyShellShutdownListener";

// Only the surrogate is ours to end. The manifest declares a SurrogateServer,
// so this is always dllhost.exe in practice; the check is what keeps a future
// in-process registration from taking Explorer down with it.
bool IsSurrogateHost() {
  wchar_t path[MAX_PATH];
  const DWORD length = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  // dllhost.exe lives in System32, so its path always fits; one that does not
  // is some other host.
  if (length == 0 || length == MAX_PATH) return false;
  const wchar_t* separator = ::wcsrchr(path, L'\\');
  const wchar_t* name = separator ? separator + 1 : path;
  return ::_wcsicmp(name, L"dllhost.exe") == 0;
}

// Ends the surrogate outright. It holds nothing worth flushing - every
// command hands its work to ghostcopy.exe and returns - and ExitProcess would
// run every loaded module's detach code with Explorer's calls still in
// flight on other threads. Explorer sees the server disconnect, and the next
// right-click starts a fresh one.
void EndSurrogate() { ::TerminateProcess(::GetCurrentProcess(), 0); }

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

DWORD WINAPI ListenerThread(void* module) {
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = ListenerProc;
  window_class.hInstance = static_cast<HINSTANCE>(module);
  window_class.lpszClassName = kWindowClass;
  if (!::RegisterClassExW(&window_class)) return 0;

  // Top-level, never shown, and kept off the taskbar and Alt+Tab. Not
  // HWND_MESSAGE: a message-only window is exactly what the surrogate
  // already had, and end-session messages are not sent to one.
  const HWND window = ::CreateWindowExW(
      WS_EX_TOOLWINDOW, kWindowClass, L"", WS_POPUP, 0, 0, 0, 0, nullptr,
      nullptr, static_cast<HINSTANCE>(module), nullptr);
  if (!window) return 0;

  MSG message;
  while (::GetMessageW(&message, nullptr, 0, 0) > 0) {
    ::TranslateMessage(&message);
    ::DispatchMessageW(&message);
  }
  return 0;
}

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
    return TRUE;
  }

  const HANDLE thread =
      ::CreateThread(nullptr, 0, ListenerThread, module, 0, nullptr);
  if (thread) ::CloseHandle(thread);
  return TRUE;
}

}  // namespace

void StartShutdownListener() {
  static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
  ::InitOnceExecuteOnce(&once, StartOnce, nullptr, nullptr);
}

}  // namespace ghostcopy
