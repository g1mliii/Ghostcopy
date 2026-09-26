cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "package_context.cpp"
  "power_monitor.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# C++/WinRT (package_context.cpp) needs real coroutine support. Under the
# C++17 that apply_standard_settings sets, MSVC routes it to
# <experimental/coroutine>, which now hard-errors as removed-soon. C++20 has
# <coroutine> in the standard library, so this is the supported way to get it
# rather than defining the deprecation escape hatch. Scoped to the runner:
# plugins keep compiling at their own standard.
target_compile_features(${BINARY_NAME} PRIVATE cxx_std_20)

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Suppress LNK4099 warnings for missing PDB files in third-party libraries (e.g., Firebase)
# These warnings are expected for prebuilt libraries without debug symbols
target_link_options(${BINARY_NAME} PRIVATE "/ignore:4099")

# Emit a PDB for the release build, so Sentry can symbolicate native Windows
# crashes. Flutter's Release configuration links with
# GenerateDebugInformation=false, which means no symbol file exists at all -
# every native frame in a crash report stays a raw address, and uploading
# symbols is not something that can be "wired up later" because there is
# nothing to upload.
#
# /OPT:REF and /OPT:ICF are not optional here: /DEBUG turns both off by
# default, which would leave unreferenced code and duplicate functions in the
# shipped binary. Restoring them keeps the executable what it was; the PDB is
# a separate file.
#
# The PDB goes outside the bundle deliberately. Everything in the Release
# directory ends up in the MSIX payload, and symbols belong in Sentry, not in
# a package every user downloads. See docs/windows-releases.md.
target_link_options(${BINARY_NAME} PRIVATE
  "$<$<CONFIG:Release>:/DEBUG>"
  "$<$<CONFIG:Release>:/OPT:REF>"
  "$<$<CONFIG:Release>:/OPT:ICF>")
set_target_properties(${BINARY_NAME} PROPERTIES
  PDB_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/symbols")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "Wtsapi32.lib")
# OleInitialize in main.cpp and OleFlushClipboard in flutter_window.cpp.
target_link_libraries(${BINARY_NAME} PRIVATE "ole32.lib")
# C++/WinRT, for Windows.ApplicationModel.StartupTask in package_context.cpp.
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
