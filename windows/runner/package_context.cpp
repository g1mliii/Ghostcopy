#include "package_context.h"

#include <windows.h>

#include <appmodel.h>

#include <thread>

#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.h>

namespace ghostcopy {

namespace {

using winrt::Windows::ApplicationModel::StartupTask;
using winrt::Windows::ApplicationModel::StartupTaskState;

StartupState Translate(StartupTaskState state) {
  switch (state) {
    case StartupTaskState::Disabled:
      return StartupState::kDisabled;
    case StartupTaskState::DisabledByUser:
      return StartupState::kDisabledByUser;
    case StartupTaskState::DisabledByPolicy:
      return StartupState::kDisabledByPolicy;
    case StartupTaskState::Enabled:
      return StartupState::kEnabled;
    case StartupTaskState::EnabledByPolicy:
      return StartupState::kEnabledByPolicy;
  }
  return StartupState::kUnavailable;
}

// StartupTask's operations are WinRT async, and blocking on one from the
// Flutter platform thread is not allowed: that thread is an STA with a running
// message pump (main.cpp calls OleInitialize), and C++/WinRT refuses a
// blocking wait there rather than risk a re-entrant pump. The work itself is a
// manifest lookup and a small state write, so the simplest correct answer is
// to run it on a short-lived MTA thread and join it. Every call site is either
// app startup or the user toggling a switch, never a hot path.
StartupState RunOnMta(const std::wstring& task_id,
                      StartupState (*body)(const StartupTask&)) {
  if (!IsPackaged()) return StartupState::kUnavailable;

  StartupState result = StartupState::kUnavailable;
  std::thread worker([&task_id, body, &result] {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (const winrt::hresult_error&) {
      return;
    }
    try {
      const StartupTask task = StartupTask::GetAsync(task_id).get();
      result = body(task);
    } catch (const winrt::hresult_error&) {
      result = StartupState::kUnavailable;
    }
    winrt::uninit_apartment();
  });
  worker.join();
  return result;
}

}  // namespace

bool IsPackaged() {
  // Length 0 with a null buffer: a packaged process answers
  // ERROR_INSUFFICIENT_BUFFER, an unpackaged one APPMODEL_ERROR_NO_PACKAGE.
  UINT32 length = 0;
  return ::GetCurrentPackageFullName(&length, nullptr) !=
         APPMODEL_ERROR_NO_PACKAGE;
}

StartupState GetStartupState(const std::wstring& task_id) {
  return RunOnMta(task_id, [](const StartupTask& task) {
    return Translate(task.State());
  });
}

StartupState RequestEnableStartup(const std::wstring& task_id) {
  return RunOnMta(task_id, [](const StartupTask& task) {
    return Translate(task.RequestEnableAsync().get());
  });
}

StartupState DisableStartup(const std::wstring& task_id) {
  return RunOnMta(task_id, [](const StartupTask& task) {
    task.Disable();
    return Translate(task.State());
  });
}

}  // namespace ghostcopy
