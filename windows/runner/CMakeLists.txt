cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "capture_pixel_buffer.cpp"
  "capture_pixel_buffer.h"
  "capture_runtime.cpp"
  "capture_runtime.h"
  "capture_service.cpp"
  "capture_service.h"
  "frame_similarity.cpp"
  "frame_similarity.h"
  "exit_lifecycle.cpp"
  "exit_lifecycle.h"
  "flutter_window.cpp"
  "main.cpp"
  "native_bridge.cpp"
  "native_bridge.h"
  "native_frame_logger.cpp"
  "native_frame_logger.h"
  "startup_behavior.cpp"
  "startup_behavior.h"
  "tray_menu_state.cpp"
  "tray_menu_state.h"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_compile_definitions(${BINARY_NAME} PRIVATE
  "WIN32_LEAN_AND_MEAN"
  "WINVER=0x0A00"
  "_WIN32_WINNT=0x0A00"
)
target_compile_options(${BINARY_NAME} PRIVATE /FS /utf-8)

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE
  "advapi32.lib"
  "crypt32.lib"
  "d3d11.lib"
  "dwmapi.lib"
  "dxgi.lib"
  "mf.lib"
  "mfplat.lib"
  "mfreadwrite.lib"
  "mfuuid.lib"
  "ole32.lib"
  "oleaut32.lib"
  "psapi.lib"
  "shell32.lib"
  "uuid.lib"
  "version.lib"
  "windowscodecs.lib"
  "Wtsapi32.lib"
)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Small dependency-free native regression tests. Keep these out of the default
# Flutter build while allowing them to be compiled and run explicitly.
enable_testing()

add_executable(qi_day_flow_capture_pixel_buffer_test EXCLUDE_FROM_ALL
  "capture_pixel_buffer.cpp"
  "capture_pixel_buffer_test.cpp"
)
apply_standard_settings(qi_day_flow_capture_pixel_buffer_test)
target_compile_options(qi_day_flow_capture_pixel_buffer_test PRIVATE /FS /utf-8)
add_test(NAME qi_day_flow_capture_pixel_buffer_test
  COMMAND qi_day_flow_capture_pixel_buffer_test)

add_executable(qi_day_flow_capture_runtime_test EXCLUDE_FROM_ALL
  "capture_runtime.cpp"
  "capture_runtime_test.cpp"
)
apply_standard_settings(qi_day_flow_capture_runtime_test)
target_compile_options(qi_day_flow_capture_runtime_test PRIVATE /FS /utf-8)
add_test(NAME qi_day_flow_capture_runtime_test
  COMMAND qi_day_flow_capture_runtime_test)

add_executable(qi_day_flow_frame_similarity_test EXCLUDE_FROM_ALL
  "frame_similarity.cpp"
  "frame_similarity.h"
  "frame_similarity_test.cpp"
)
apply_standard_settings(qi_day_flow_frame_similarity_test)
target_compile_options(qi_day_flow_frame_similarity_test PRIVATE /FS /utf-8)
add_test(NAME qi_day_flow_frame_similarity_test
  COMMAND qi_day_flow_frame_similarity_test)

add_executable(qi_day_flow_native_frame_logger_test EXCLUDE_FROM_ALL
  "native_frame_logger.cpp"
  "native_frame_logger.h"
  "native_frame_logger_test.cpp"
)
apply_standard_settings(qi_day_flow_native_frame_logger_test)
target_compile_definitions(qi_day_flow_native_frame_logger_test PRIVATE
  "NOMINMAX"
  "WIN32_LEAN_AND_MEAN"
)
target_compile_options(qi_day_flow_native_frame_logger_test PRIVATE /FS /utf-8)
add_test(NAME qi_day_flow_native_frame_logger_test
  COMMAND qi_day_flow_native_frame_logger_test)

add_executable(qi_day_flow_tray_menu_state_test EXCLUDE_FROM_ALL
  "tray_menu_state.cpp"
  "tray_menu_state.h"
  "tray_menu_state_test.cpp"
)
apply_standard_settings(qi_day_flow_tray_menu_state_test)
target_compile_options(qi_day_flow_tray_menu_state_test PRIVATE /FS /utf-8)
add_test(NAME qi_day_flow_tray_menu_state_test
  COMMAND qi_day_flow_tray_menu_state_test)

add_executable(qi_day_flow_startup_behavior_test EXCLUDE_FROM_ALL
  "startup_behavior.cpp"
  "startup_behavior.h"
  "startup_behavior_test.cpp"
)
apply_standard_settings(qi_day_flow_startup_behavior_test)
target_compile_options(qi_day_flow_startup_behavior_test PRIVATE /FS /utf-8)
add_test(NAME qi_day_flow_startup_behavior_test
  COMMAND qi_day_flow_startup_behavior_test)

add_executable(qi_day_flow_exit_lifecycle_test EXCLUDE_FROM_ALL
  "exit_lifecycle.cpp"
  "exit_lifecycle.h"
  "exit_lifecycle_test.cpp"
)
apply_standard_settings(qi_day_flow_exit_lifecycle_test)
target_compile_options(qi_day_flow_exit_lifecycle_test PRIVATE /FS /utf-8)
add_test(NAME qi_day_flow_exit_lifecycle_test
  COMMAND qi_day_flow_exit_lifecycle_test)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
