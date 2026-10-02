#include "module.h"

#include <windows.h>

namespace ghostcopy {

namespace {

HMODULE g_module = nullptr;

// The executable msix_config points at, in the package root beside this DLL.
constexpr wchar_t kExecutableName[] = L"ghostcopy.exe";

}  // namespace

void SetModuleHandle(void* module) {
  g_module = static_cast<HMODULE>(module);
}

std::wstring ModulePath(void* module) {
  const auto handle = static_cast<HMODULE>(module);
  std::wstring path(MAX_PATH, L'\0');
  DWORD length = ::GetModuleFileNameW(handle, path.data(),
                                      static_cast<DWORD>(path.size()));
  if (length == 0) return {};
  // A package path can exceed MAX_PATH; grow until it fits rather than
  // returning a truncated one, which would silently resolve to nothing.
  while (length == path.size()) {
    path.resize(path.size() * 2);
    length = ::GetModuleFileNameW(handle, path.data(),
                                  static_cast<DWORD>(path.size()));
    if (length == 0) return {};
  }
  path.resize(length);
  return path;
}

std::wstring AppIconReference() {
  if (!g_module) return {};

  std::wstring path = ModulePath(g_module);
  if (path.empty()) return {};

  const size_t separator = path.find_last_of(L'\\');
  if (separator == std::wstring::npos) return {};
  path.resize(separator + 1);

  return path + kExecutableName + L",0";
}

}  // namespace ghostcopy
