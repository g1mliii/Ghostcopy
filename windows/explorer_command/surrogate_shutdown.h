#ifndef EXPLORER_COMMAND_SURROGATE_SHUTDOWN_H_
#define EXPLORER_COMMAND_SURROGATE_SHUTDOWN_H_

namespace ghostcopy {

// Gives the COM surrogate this DLL is hosted in a way to hear Windows ask it
// to close. Safe to call repeatedly; does nothing outside a dllhost.exe
// running under the package's identity. The first call returns once the
// window it listens with exists, and a call that failed is retried by the
// next.
//
// A package update closes the package's processes by sending end-session
// messages to their top-level windows, and dllhost has none, so every Store
// update waited out a ninety-second timeout to kill it. The history is in
// docs/windows-store-update-investigation.md.
void StartShutdownListener();

// Held for the length of an Invoke, so a close request lets a send already
// under way finish - a multi-file send is one activation per file, and
// ending the surrogate partway would drop the rest without a word.
class InvokeInProgress {
 public:
  InvokeInProgress();
  ~InvokeInProgress();
  InvokeInProgress(const InvokeInProgress&) = delete;
  InvokeInProgress& operator=(const InvokeInProgress&) = delete;
};

}  // namespace ghostcopy

#endif  // EXPLORER_COMMAND_SURROGATE_SHUTDOWN_H_
