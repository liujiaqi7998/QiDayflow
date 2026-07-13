#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "startup_behavior.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool start_in_background =
      qi_day_flow::HasBackgroundArgument(command_line_arguments);
  HANDLE single_instance =
      CreateMutexW(nullptr, TRUE, L"Local\\QiDayFlow.SingleInstance.v1");
  if (single_instance != nullptr && GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing_window = nullptr;
    for (int attempt = 0; attempt < 20 && existing_window == nullptr;
         ++attempt) {
      existing_window =
          FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
      if (existing_window == nullptr) {
        Sleep(100);
      }
    }
    if (existing_window != nullptr && !start_in_background) {
      ShowWindow(existing_window, SW_RESTORE);
      SetForegroundWindow(existing_window);
      FlashWindow(existing_window, TRUE);
    }
    CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT com_result =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const bool com_initialized = SUCCEEDED(com_result);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_in_background);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Qi Day Flow", origin, size)) {
    if (com_initialized) {
      ::CoUninitialize();
    }
    if (single_instance != nullptr) {
      ::ReleaseMutex(single_instance);
      ::CloseHandle(single_instance);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (com_initialized) {
    ::CoUninitialize();
  }
  if (single_instance != nullptr) {
    ::ReleaseMutex(single_instance);
    ::CloseHandle(single_instance);
  }
  return EXIT_SUCCESS;
}
