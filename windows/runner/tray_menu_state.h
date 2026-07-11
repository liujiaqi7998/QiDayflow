#ifndef RUNNER_TRAY_MENU_STATE_H_
#define RUNNER_TRAY_MENU_STATE_H_

#include <string_view>

namespace qi_day_flow {

enum class TrayCaptureState {
  kStopped,
  kStarting,
  kRecording,
  kPaused,
  kStopping,
  kError,
};

enum class TrayCaptureCommand {
  kStartCapture,
  kStopCapture,
};

struct TrayCaptureMenuItem {
  std::wstring_view label;
  bool enabled;
  TrayCaptureCommand command;
};

bool ParseTrayCaptureState(std::string_view value, TrayCaptureState* state);
TrayCaptureMenuItem TrayMenuItemForState(TrayCaptureState state);
std::string_view TrayCommandValue(TrayCaptureCommand command);
TrayCaptureState PendingTrayCaptureState(TrayCaptureCommand command);

}  // namespace qi_day_flow

#endif  // RUNNER_TRAY_MENU_STATE_H_
