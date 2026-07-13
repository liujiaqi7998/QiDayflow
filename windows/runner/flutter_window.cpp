#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <strsafe.h>

#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "native_bridge.h"
#include "resource.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_in_background)
    : project_(project), start_in_background_(start_in_background) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  native_bridge_ = std::make_unique<qi_day_flow::NativeBridge>(
      flutter_controller_->engine()->messenger(), GetHandle(),
      [this]() { ShowApplicationWindow(); },
      [this]() { HideApplicationWindow(); },
      [this]() {
        if (GetHandle() != nullptr) {
          PostMessageW(GetHandle(), kRequestExitMessage, 0, 0);
        }
      },
      [this](qi_day_flow::TrayCaptureState state) {
        UpdateTrayCaptureState(state);
      });
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  SetupTrayIcon();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    if (!start_in_background_) {
      Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (GetHandle() != nullptr) {
    KillTimer(GetHandle(), kExitFallbackTimer);
  }
  RemoveTrayIcon();
  if (native_bridge_) {
    native_bridge_->Shutdown();
    native_bridge_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == qi_day_flow::NativeBridge::kDrainEventsMessage) {
    if (native_bridge_) {
      native_bridge_->DrainEvents();
    }
    return 0;
  }

  if (message == kRequestExitMessage) {
    CompleteApplicationExit();
    return 0;
  }

  if (message == kShutdownCompleteMessage) {
    FinalizeApplicationExit();
    return 0;
  }

  if (taskbar_created_message_ != 0 &&
      message == taskbar_created_message_) {
    tray_icon_added_ = false;
    if (tray_icon_.hIcon != nullptr) {
      DestroyIcon(tray_icon_.hIcon);
      tray_icon_.hIcon = nullptr;
    }
    SetupTrayIcon();
    return 0;
  }

  if (message == kTrayMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
      case NIN_SELECT:
      case NIN_KEYSELECT:
        ShowApplicationWindow();
        return 0;
      case WM_CONTEXTMENU:
      case WM_RBUTTONUP:
        ShowTrayMenu();
        return 0;
      default:
        break;
    }
  }

  if (message == WM_COMMAND) {
    const UINT command = LOWORD(wparam);
    if (command == kTrayShowCommand) {
      ShowApplicationWindow();
      return 0;
    }
    if (command == kTrayExitCommand) {
      RequestApplicationExit();
      return 0;
    }
    if (command == kTrayCaptureCommand) {
      QueueTrayCaptureCommand();
      return 0;
    }
  }

  if (message == WM_CLOSE && !exit_allowed_) {
    HideApplicationWindow();
    return 0;
  }

  if (message == WM_SIZE && wparam == SIZE_MINIMIZED && !exit_allowed_) {
    HideApplicationWindow();
    return 0;
  }

  if (message == WM_TIMER && wparam == kExitFallbackTimer) {
    CompleteApplicationExit();
    return 0;
  }

  if (message == WM_QUERYENDSESSION) {
    return TRUE;
  }

  if (message == WM_ENDSESSION && wparam != FALSE) {
    CompleteApplicationExit();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::SetupTrayIcon() {
  if (tray_icon_added_ || GetHandle() == nullptr) {
    return;
  }
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayMessage;
  tray_icon_.hIcon = static_cast<HICON>(LoadImageW(
      GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
  static_cast<void>(StringCchCopyW(tray_icon_.szTip,
                                   ARRAYSIZE(tray_icon_.szTip),
                                   L"Qi Day Flow"));
  tray_icon_added_ =
      Shell_NotifyIconW(NIM_ADD, &tray_icon_) != FALSE;
  if (tray_icon_added_) {
    tray_icon_.uVersion = NOTIFYICON_VERSION_4;
    static_cast<void>(Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_));
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  static_cast<void>(Shell_NotifyIconW(NIM_DELETE, &tray_icon_));
  tray_icon_added_ = false;
  if (tray_icon_.hIcon != nullptr) {
    DestroyIcon(tray_icon_.hIcon);
    tray_icon_.hIcon = nullptr;
  }
}

void FlutterWindow::ShowTrayMenu() {
  if (GetHandle() == nullptr || exit_lifecycle_.exit_requested() ||
      exit_allowed_) {
    return;
  }
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  const qi_day_flow::TrayCaptureMenuItem capture_item =
      qi_day_flow::TrayMenuItemForState(tray_capture_state_);
  const std::wstring capture_label(capture_item.label);
  const UINT capture_flags =
      MF_STRING | (capture_item.enabled ? MF_ENABLED : MF_GRAYED);
  static_cast<void>(AppendMenuW(menu, capture_flags, kTrayCaptureCommand,
                                capture_label.c_str()));
  static_cast<void>(AppendMenuW(menu, MF_SEPARATOR, 0, nullptr));
  static_cast<void>(AppendMenuW(menu, MF_STRING, kTrayShowCommand,
                                L"显示 Qi Day Flow"));
  static_cast<void>(AppendMenuW(menu, MF_SEPARATOR, 0, nullptr));
  static_cast<void>(AppendMenuW(menu, MF_STRING, kTrayExitCommand, L"退出"));

  POINT cursor = {};
  static_cast<void>(GetCursorPos(&cursor));
  SetForegroundWindow(GetHandle());
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN |
                TPM_RIGHTALIGN,
      cursor.x, cursor.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  PostMessageW(GetHandle(), WM_NULL, 0, 0);

  if (command == kTrayCaptureCommand) {
    QueueTrayCaptureCommand();
  } else if (command == kTrayShowCommand) {
    ShowApplicationWindow();
  } else if (command == kTrayExitCommand) {
    RequestApplicationExit();
  }
}

void FlutterWindow::UpdateTrayCaptureState(
    qi_day_flow::TrayCaptureState state) {
  if (GetHandle() == nullptr || exit_lifecycle_.exit_requested() ||
      exit_allowed_) {
    return;
  }
  tray_capture_state_ = state;
}

void FlutterWindow::QueueTrayCaptureCommand() {
  if (GetHandle() == nullptr || exit_lifecycle_.exit_requested() ||
      exit_allowed_ || !native_bridge_) {
    return;
  }
  const qi_day_flow::TrayCaptureMenuItem item =
      qi_day_flow::TrayMenuItemForState(tray_capture_state_);
  if (!item.enabled) {
    return;
  }
  tray_capture_state_ = qi_day_flow::PendingTrayCaptureState(item.command);
  native_bridge_->NotifyTrayCommand(item.command);
}

void FlutterWindow::ShowApplicationWindow() {
  if (GetHandle() == nullptr) {
    return;
  }
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::HideApplicationWindow() {
  if (GetHandle() != nullptr) {
    ShowWindow(GetHandle(), SW_HIDE);
  }
}

void FlutterWindow::RequestApplicationExit() {
  if (exit_allowed_ || !exit_lifecycle_.RequestExit()) {
    return;
  }
  if (native_bridge_) {
    native_bridge_->NotifyExitRequested();
    SetTimer(GetHandle(), kExitFallbackTimer,
             static_cast<UINT>(
                 qi_day_flow::kExitFallbackTimeout.count()),
             nullptr);
  } else {
    CompleteApplicationExit();
  }
}

void FlutterWindow::CompleteApplicationExit() {
  if (exit_allowed_ || !exit_lifecycle_.BeginShutdown()) {
    return;
  }
  if (GetHandle() != nullptr) {
    KillTimer(GetHandle(), kExitFallbackTimer);
  }
  if (native_bridge_) {
    const HWND window = GetHandle();
    native_bridge_->ShutdownAsync([window]() {
      if (window != nullptr) {
        static_cast<void>(
            PostMessageW(window, kShutdownCompleteMessage, 0, 0));
      }
    });
    return;
  }
  FinalizeApplicationExit();
}

void FlutterWindow::FinalizeApplicationExit() {
  if (!exit_lifecycle_.CompleteShutdown()) {
    return;
  }
  exit_allowed_ = true;
  if (GetHandle() != nullptr) {
    DestroyWindow(GetHandle());
  }
}
