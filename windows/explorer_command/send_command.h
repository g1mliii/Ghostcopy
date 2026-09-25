#ifndef EXPLORER_COMMAND_SEND_COMMAND_H_
#define EXPLORER_COMMAND_SEND_COMMAND_H_

#include <windows.h>

#include <shobjidl_core.h>

// {BCE5C0BC-582B-49BA-8FED-537B9F3100C0}
//
// The CLSID Explorer looks up for the "Send with GhostCopy" verb. It appears
// in three places that must agree, or the entry silently never shows: here,
// the <desktop5:Verb Clsid> in the package manifest, and the
// <com:Class Id> of the surrogate server that points at this DLL. Both of
// those are generated from msix_config's `context_menu` block in pubspec.yaml.
// It is a published contract with installed packages - never regenerate it.
// clang-format off
extern "C" const GUID CLSID_GhostCopySendCommand;
// clang-format on

// The verb handler itself.
//
// Explorer loads this DLL into a COM surrogate (dllhost.exe) running under the
// package's identity, asks it for a title and a state per selection, and calls
// Invoke when the user clicks. Everything it does has to be quick and
// non-blocking: this runs inside the shell's context-menu build, so a slow
// GetState is a visibly slow right-click on every file in Explorer.
class SendCommand : public IExplorerCommand {
 public:
  SendCommand();

  // IUnknown
  IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
  IFACEMETHODIMP_(ULONG) AddRef() override;
  IFACEMETHODIMP_(ULONG) Release() override;

  // IExplorerCommand
  IFACEMETHODIMP GetTitle(IShellItemArray* items, LPWSTR* name) override;
  IFACEMETHODIMP GetIcon(IShellItemArray* items, LPWSTR* icon) override;
  IFACEMETHODIMP GetToolTip(IShellItemArray* items, LPWSTR* infotip) override;
  IFACEMETHODIMP GetCanonicalName(GUID* guid) override;
  IFACEMETHODIMP GetState(IShellItemArray* items, BOOL ok_to_be_slow,
                          EXPCMDSTATE* state) override;
  IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx* ctx) override;
  IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override;
  IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** enum_commands) override;

 private:
  ~SendCommand();

  LONG ref_count_ = 1;
};

// Tracks live objects and server locks so DllCanUnloadNow can answer.
extern LONG g_dll_references;

#endif  // EXPLORER_COMMAND_SEND_COMMAND_H_
