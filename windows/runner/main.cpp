#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <shobjidl.h>

#include <cwchar>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize OLE (required for super_clipboard drag & drop and clipboard)
  // OleInitialize includes COM initialization plus OLE functionality
  ::OleInitialize(nullptr);

  // Come back after a Microsoft Store update. The update closes the app to
  // replace it and nothing else starts it again, so the tray icon and hotkey
  // were gone until the next login. A packaged app that registered here is
  // relaunched once the update finishes - Windows' documented way for a
  // full-trust MSIX app. Started as a login launch would be: hidden, in the
  // tray, because that is where it was.
  //
  // Only the update case. Not after a crash or hang (a crash on startup would
  // loop), and not after a reboot, which is the startup task's job and only
  // if the user turned it on. Windows also ignores a process that ran for
  // under 60 seconds. --send-file is a one-shot upload that should never come
  // back as a tray app; a second instance handing its arguments over also
  // registers, but it exits before any update could catch it.
  if (std::wcsstr(command_line, L"--send-file") == nullptr) {
    ::RegisterApplicationRestart(
        L"--launched-at-startup",
        RESTART_NO_CRASH | RESTART_NO_HANG | RESTART_NO_REBOOT);
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"ghostcopy", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Quit from the tray ends the loop with the window still up:
  // windowManager.destroy() is a bare PostQuitMessage. Left to `window`'s
  // destructor, the Flutter controller was torn down while its pointer was
  // still set, and destroying Flutter's child window sent the top-level one
  // messages that were forwarded into the half-destroyed controller - an
  // access violation on every Quit (Sentry FLUTTER-2, -3 and -A). Destroy()
  // takes the WM_DESTROY path a close takes, which clears the controller
  // first. Before OleUninitialize, because plugins revoke drag and drop and
  // release COM objects as the engine shuts down.
  window.Destroy();

  ::OleUninitialize();
  return EXIT_SUCCESS;
}
