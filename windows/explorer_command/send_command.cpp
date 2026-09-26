#include "send_command.h"

#include <appmodel.h>
#include <shlwapi.h>

#include <new>
#include <string>

#include "module.h"

// Must match the Clsid in the <desktop5:Verb> and <com:Class> the package
// manifest declares; see the note in send_command.h.
extern "C" const GUID CLSID_GhostCopySendCommand = {
    0xbce5c0bc,
    0x582b,
    0x49ba,
    {0x8f, 0xed, 0x53, 0x7b, 0x9f, 0x31, 0x00, 0xc0}};

LONG g_dll_references = 0;

namespace {

// The <Application Id> msix writes into the manifest, which it derives from
// pubspec.yaml's `name:` with underscores removed. Together with the package
// family name this forms the AUMID that ActivateApplication needs. If the
// package name ever changes, this changes with it.
constexpr wchar_t kApplicationId[] = L"ghostcopy";

// The argument main.dart already parses for a single file, the same one the
// unpackaged HKCU verb passes. Sending is handled before any window is
// created, and that process exits when it is done.
constexpr wchar_t kSendFileArgument[] = L"--send-file";

// Launches the packaged app with |arguments|.
//
// Not CreateProcess on the executable next to this DLL: that path is under
// WindowsApps, whose ACL denies direct launch, and a process started that way
// would run without the package identity the app needs for its own state.
// ActivateApplication is the supported way in, and for a
// Windows.FullTrustApplication the argument string arrives as the command
// line, which is exactly what main.dart reads.
HRESULT ActivatePackagedApp(const std::wstring& arguments) {
  wchar_t family[PACKAGE_FAMILY_NAME_MAX_LENGTH + 1] = {};
  UINT32 length = ARRAYSIZE(family);
  if (::GetCurrentPackageFamilyName(&length, family) != ERROR_SUCCESS) {
    // Running unpackaged. The unpackaged build registers its verb in HKCU and
    // never loads this DLL, so this is a misconfiguration rather than a case
    // to handle.
    return HRESULT_FROM_WIN32(APPMODEL_ERROR_NO_PACKAGE);
  }

  const std::wstring aumid = std::wstring(family) + L"!" + kApplicationId;

  IApplicationActivationManager* manager = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_ApplicationActivationManager, nullptr,
                                  CLSCTX_LOCAL_SERVER, IID_PPV_ARGS(&manager));
  if (FAILED(hr)) return hr;

  DWORD process_id = 0;
  hr = manager->ActivateApplication(aumid.c_str(), arguments.c_str(), AO_NONE,
                                    &process_id);
  manager->Release();
  return hr;
}

// Wraps |path| in quotes so a space in it survives CommandLineToArgvW, which
// is what the Flutter runner parses the command line with.
std::wstring BuildSendArguments(PCWSTR path) {
  return std::wstring(kSendFileArgument) + L" \"" + path + L"\"";
}

}  // namespace

IFACEMETHODIMP SendCommand::QueryInterface(REFIID riid, void** ppv) {
  if (!ppv) return E_POINTER;
  if (riid == IID_IUnknown || riid == IID_IExplorerCommand) {
    *ppv = static_cast<IExplorerCommand*>(this);
    AddRef();
    return S_OK;
  }
  *ppv = nullptr;
  return E_NOINTERFACE;
}

// The module reference is taken for the object's whole lifetime, not per
// AddRef. Counting it in AddRef/Release instead looks equivalent but is not:
// an object handed back with a reference count of 1 has had one AddRef and one
// Release, leaving the module count at zero, so DllCanUnloadNow would say yes
// while Explorer still holds the object - and the surrogate would unload the
// DLL out from under it.
SendCommand::SendCommand() {
  ::InterlockedIncrement(&g_dll_references);
}

SendCommand::~SendCommand() {
  ::InterlockedDecrement(&g_dll_references);
}

IFACEMETHODIMP_(ULONG) SendCommand::AddRef() {
  return ::InterlockedIncrement(&ref_count_);
}

IFACEMETHODIMP_(ULONG) SendCommand::Release() {
  const LONG remaining = ::InterlockedDecrement(&ref_count_);
  if (remaining == 0) delete this;
  return remaining;
}

IFACEMETHODIMP SendCommand::GetTitle(IShellItemArray*, LPWSTR* name) {
  // The same wording as the unpackaged HKCU verb, so the entry does not
  // change between an unpackaged build and the Store one.
  return ::SHStrDupW(L"Send with GhostCopy", name);
}

IFACEMETHODIMP SendCommand::GetIcon(IShellItemArray*, LPWSTR* icon) {
  const std::wstring reference = ghostcopy::AppIconReference();
  if (reference.empty()) return E_NOTIMPL;
  return ::SHStrDupW(reference.c_str(), icon);
}

IFACEMETHODIMP SendCommand::GetToolTip(IShellItemArray*, LPWSTR*) {
  // Explorer shows the title; a tooltip repeating it is noise.
  return E_NOTIMPL;
}

IFACEMETHODIMP SendCommand::GetCanonicalName(GUID* guid) {
  if (!guid) return E_POINTER;
  *guid = CLSID_GhostCopySendCommand;
  return S_OK;
}

IFACEMETHODIMP SendCommand::GetState(IShellItemArray*, BOOL,
                                     EXPCMDSTATE* state) {
  if (!state) return E_POINTER;
  // Deliberately unconditional. This is called while Explorer builds the
  // context menu, so anything that touched the network or the app's state
  // here would show up as a slow right-click on every file.
  *state = ECS_ENABLED;
  return S_OK;
}

IFACEMETHODIMP SendCommand::GetFlags(EXPCMDFLAGS* flags) {
  if (!flags) return E_POINTER;
  *flags = ECF_DEFAULT;
  return S_OK;
}

IFACEMETHODIMP SendCommand::EnumSubCommands(IEnumExplorerCommand**) {
  return E_NOTIMPL;
}

IFACEMETHODIMP SendCommand::Invoke(IShellItemArray* items, IBindCtx*) {
  if (!items) return S_OK;

  DWORD count = 0;
  if (FAILED(items->GetCount(&count))) return E_FAIL;

  // One activation per selected file, matching what the unpackaged verb does:
  // Explorer invokes a "%1" command once per item, and --send-file takes one
  // path and exits. Explorer already warns the user before invoking a verb on
  // a very large selection, so there is no second cap here.
  HRESULT first_failure = S_OK;
  for (DWORD i = 0; i < count; ++i) {
    IShellItem* item = nullptr;
    if (FAILED(items->GetItemAt(i, &item))) continue;

    PWSTR path = nullptr;
    // SIGDN_FILESYSPATH fails for anything without one - a library, a zip's
    // contents, a device. Those have no file to send, so skipping is right.
    if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
      const HRESULT hr = ActivatePackagedApp(BuildSendArguments(path));
      if (FAILED(hr) && SUCCEEDED(first_failure)) first_failure = hr;
      ::CoTaskMemFree(path);
    }
    item->Release();
  }
  return first_failure;
}
