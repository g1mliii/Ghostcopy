#ifndef EXPLORER_COMMAND_MODULE_H_
#define EXPLORER_COMMAND_MODULE_H_

#include <string>

namespace ghostcopy {

// Remembered in DllMain; the DLL sits next to ghostcopy.exe in the package
// root, so it is how the icon below is located.
void SetModuleHandle(void* module);

// The full path of a loaded module - of the process's executable when
// `module` is null - or an empty string if it could not be read.
std::wstring ModulePath(void* module);

// "<package root>\ghostcopy.exe,0", the form IExplorerCommand::GetIcon wants,
// or an empty string if the module path could not be read.
std::wstring AppIconReference();

}  // namespace ghostcopy

#endif  // EXPLORER_COMMAND_MODULE_H_
