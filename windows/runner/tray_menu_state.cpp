#include "tray_menu_state.h"

namespace qi_day_flow {

bool ParseTrayCaptureState(std::string_view value, TrayCaptureState* state) {
  if (state == nullptr) {
    return false;
  }
  TrayCaptureState parsed;
  if (value == "stopped") {
    parsed = TrayCaptureState::kStopped;
  } else if (value == "starting") {
    parsed = TrayCaptureState::kStarting;
  } else if (value == "recording") {
    parsed = TrayCaptureState::kRecording;
  } else if (value == "paused") {
    parsed = TrayCaptureState::kPaused;
  } else if (value == "stopping") {
    parsed = TrayCaptureState::kStopping;
  } else if (value == "error") {
    parsed = TrayCaptureState::kError;
  } else {
    return false;
  }
  *state = parsed;
  return true;
}

TrayCaptureMenuItem TrayMenuItemForState(TrayCaptureState state) {
  switch (state) {
    case TrayCaptureState::kStopped:
    case TrayCaptureState::kError:
      return {L"开始录制", true, TrayCaptureCommand::kStartCapture};
    case TrayCaptureState::kStarting:
    case TrayCaptureState::kStopping:
      return {L"停止录制", false, TrayCaptureCommand::kStopCapture};
    case TrayCaptureState::kRecording:
    case TrayCaptureState::kPaused:
      return {L"停止录制", true, TrayCaptureCommand::kStopCapture};
  }
  return {L"开始录制", false, TrayCaptureCommand::kStartCapture};
}

std::string_view TrayCommandValue(TrayCaptureCommand command) {
  switch (command) {
    case TrayCaptureCommand::kStartCapture:
      return "startCapture";
    case TrayCaptureCommand::kStopCapture:
      return "stopCapture";
  }
  return {};
}

TrayCaptureState PendingTrayCaptureState(TrayCaptureCommand command) {
  switch (command) {
    case TrayCaptureCommand::kStartCapture:
      return TrayCaptureState::kStarting;
    case TrayCaptureCommand::kStopCapture:
      return TrayCaptureState::kStopping;
  }
  return TrayCaptureState::kError;
}

}  // namespace qi_day_flow
