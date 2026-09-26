// The COM entry points Explorer's surrogate host loads this DLL for.
//
// There is no self-registration here on purpose: a packaged verb handler is
// registered by the <com:SurrogateServer> in the package manifest, not by
// regsvr32, so DllRegisterServer would only be a second source of truth that
// could disagree with the manifest.

#include <windows.h>

#include <new>

#include "module.h"
#include "send_command.h"

namespace {

// Hands out SendCommand instances. Explorer asks for exactly one interface,
// so there is nothing to switch on beyond the CLSID the loader matched.
class SendCommandFactory : public IClassFactory {
 public:
  // Held for the factory's lifetime rather than per AddRef, for the reason in
  // SendCommand's constructor.
  SendCommandFactory() { ::InterlockedIncrement(&g_dll_references); }

  IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_IClassFactory) {
      *ppv = static_cast<IClassFactory*>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  IFACEMETHODIMP_(ULONG) AddRef() override {
    return ::InterlockedIncrement(&ref_count_);
  }

  IFACEMETHODIMP_(ULONG) Release() override {
    const LONG remaining = ::InterlockedDecrement(&ref_count_);
    if (remaining == 0) delete this;
    return remaining;
  }

  IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid,
                                void** ppv) override {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;
    if (outer) return CLASS_E_NOAGGREGATION;

    auto* command = new (std::nothrow) SendCommand();
    if (!command) return E_OUTOFMEMORY;

    const HRESULT hr = command->QueryInterface(riid, ppv);
    command->Release();
    return hr;
  }

  IFACEMETHODIMP LockServer(BOOL lock) override {
    if (lock) {
      ::InterlockedIncrement(&g_dll_references);
    } else {
      ::InterlockedDecrement(&g_dll_references);
    }
    return S_OK;
  }

 private:
  ~SendCommandFactory() { ::InterlockedDecrement(&g_dll_references); }

  LONG ref_count_ = 1;
};

}  // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) {
    ghostcopy::SetModuleHandle(module);
    // Nothing here needs per-thread notifications, and this DLL is loaded
    // into Explorer's surrogate, which creates plenty of threads.
    ::DisableThreadLibraryCalls(module);
  }
  return TRUE;
}

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv) {
  if (!ppv) return E_POINTER;
  *ppv = nullptr;
  if (rclsid != CLSID_GhostCopySendCommand) return CLASS_E_CLASSNOTAVAILABLE;

  auto* factory = new (std::nothrow) SendCommandFactory();
  if (!factory) return E_OUTOFMEMORY;

  const HRESULT hr = factory->QueryInterface(riid, ppv);
  factory->Release();
  return hr;
}

STDAPI DllCanUnloadNow() {
  return g_dll_references == 0 ? S_OK : S_FALSE;
}
