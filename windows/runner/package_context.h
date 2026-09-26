#ifndef RUNNER_PACKAGE_CONTEXT_H_
#define RUNNER_PACKAGE_CONTEXT_H_

#include <string>

namespace ghostcopy {

// True when the process is running from inside an MSIX package.
//
// Everything GhostCopy registers for itself at startup - the ghostcopy://
// scheme, the Explorer context menu, the Run key - writes to HKCU, and MSIX
// virtualizes HKCU into a private per-package hive. Those writes still appear
// to succeed inside a package and are invisible to the rest of Windows, so
// each of them has to be replaced by its manifest-declared equivalent rather
// than merely left to fail. Callers use this to pick which path to take.
bool IsPackaged();

// Mirrors Windows.ApplicationModel.StartupTaskState, plus Unavailable for the
// unpackaged case where the WinRT type cannot be constructed at all.
enum class StartupState {
  kUnavailable,
  kDisabled,
  kDisabledByUser,
  kDisabledByPolicy,
  kEnabled,
  kEnabledByPolicy,
};

// Reads the current state of the <uap5:StartupTask> declared in the package
// manifest under |task_id|.
StartupState GetStartupState(const std::wstring& task_id);

// Asks Windows to enable the startup task. The user can refuse it in Task
// Manager's Startup tab, and that refusal is sticky: once the state is
// kDisabledByUser, this returns that same value and only the user can undo it.
// The returned state is therefore the truth, not the request.
StartupState RequestEnableStartup(const std::wstring& task_id);

// Disables the startup task. Returns the resulting state.
StartupState DisableStartup(const std::wstring& task_id);

}  // namespace ghostcopy

#endif  // RUNNER_PACKAGE_CONTEXT_H_
