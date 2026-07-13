#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shellapi.h>

#include <memory>

#include "tray_menu_state.h"
#include "win32_window.h"

namespace qi_day_flow {
class NativeBridge;
}

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  FlutterWindow(const flutter::DartProject& project, bool start_in_background);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  static constexpr UINT kTrayMessage = WM_APP + 0x42;
  static constexpr UINT kRequestExitMessage = WM_APP + 0x43;
  static constexpr UINT kTrayShowCommand = 41001;
  static constexpr UINT kTrayExitCommand = 41002;
  static constexpr UINT kTrayCaptureCommand = 41003;
  static constexpr UINT_PTR kExitFallbackTimer = 0x514446;

  void SetupTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayMenu();
  void UpdateTrayCaptureState(qi_day_flow::TrayCaptureState state);
  void QueueTrayCaptureCommand();
  void ShowApplicationWindow();
  void HideApplicationWindow();
  void RequestApplicationExit();
  void CompleteApplicationExit();

  // The project to run.
  flutter::DartProject project_;
  bool start_in_background_ = false;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<qi_day_flow::NativeBridge> native_bridge_;
  NOTIFYICONDATAW tray_icon_ = {};
  UINT taskbar_created_message_ = 0;
  qi_day_flow::TrayCaptureState tray_capture_state_ =
      qi_day_flow::TrayCaptureState::kStopped;
  bool tray_icon_added_ = false;
  bool exit_requested_ = false;
  bool exit_allowed_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
