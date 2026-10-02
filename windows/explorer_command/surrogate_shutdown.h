#ifndef EXPLORER_COMMAND_SURROGATE_SHUTDOWN_H_
#define EXPLORER_COMMAND_SURROGATE_SHUTDOWN_H_

namespace ghostcopy {

// Gives the COM surrogate this DLL is hosted in a way to hear Windows ask it
// to close. Safe to call repeatedly; does nothing outside dllhost.exe. The
// first call returns once the window it listens with exists.
//
// The surrogate runs under GhostCopy's package identity, so a package update
// has to close it, and asks by sending end-session messages to the process's
// top-level windows. dllhost has none - COM's own window is message-only,
// which those messages never reach - so the request went unanswered until
// the update gave up and killed it: a MoAppHang (hang type 0x200000,
// quiesce) on every Store update since the verb shipped, holding the Store
// at 100% for about ninety seconds each time. Explorer keeps the handler
// loaded after any right-click, so the surrogate was almost always there.
void StartShutdownListener();

}  // namespace ghostcopy

#endif  // EXPLORER_COMMAND_SURROGATE_SHUTDOWN_H_
