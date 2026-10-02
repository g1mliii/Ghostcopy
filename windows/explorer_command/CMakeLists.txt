# The Explorer verb handler for "Send with GhostCopy" in an MSIX package.
#
# Outside a package the app writes its own HKCU\Software\Classes\*\shell key
# and needs none of this (see _registerWindowsContextMenu in lib/main.dart).
# MSIX virtualizes that hive, so the packaged entry has to be declared in the
# manifest instead, and a manifest verb can only point at a COM class - hence
# an in-process server rather than a registry command line.
#
# It is built unconditionally so the unpackaged build keeps it compiling; only
# the MSIX payload actually carries it, via msix_config's context_menu.dll_path
# in pubspec.yaml.
cmake_minimum_required(VERSION 3.14)
project(explorer_command LANGUAGES CXX)

set(SHELL_TARGET "ghostcopy_shell")

add_library(${SHELL_TARGET} SHARED
  "dllmain.cpp"
  "module.cpp"
  "send_command.cpp"
  "ghostcopy_shell.def"
)

apply_standard_settings(${SHELL_TARGET})

target_compile_definitions(${SHELL_TARGET} PRIVATE "NOMINMAX" "UNICODE" "_UNICODE")
target_link_libraries(${SHELL_TARGET} PRIVATE "shlwapi.lib" "ole32.lib")
target_include_directories(${SHELL_TARGET} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")

# A release PDB, beside the runner's, for the same reason - see the longer
# note in runner/CMakeLists.txt. This one runs inside Explorer's surrogate
# host, where a crash is least convenient to reproduce and most worth having
# a symbolicated stack for.
target_link_options(${SHELL_TARGET} PRIVATE
  "$<$<CONFIG:Release>:/DEBUG>"
  "$<$<CONFIG:Release>:/OPT:REF>"
  "$<$<CONFIG:Release>:/OPT:ICF>")
set_target_properties(${SHELL_TARGET} PROPERTIES
  PDB_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/symbols")
