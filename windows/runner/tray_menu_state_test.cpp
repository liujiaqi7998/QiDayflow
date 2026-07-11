#include "tray_menu_state.h"

#include <iostream>
#include <string_view>

namespace {

using qi_day_flow::ParseTrayCaptureState;
using qi_day_flow::PendingTrayCaptureState;
using qi_day_flow::TrayCaptureCommand;
using qi_day_flow::TrayCaptureMenuItem;
using qi_day_flow::TrayCaptureState;
using qi_day_flow::TrayCommandValue;
using qi_day_flow::TrayMenuItemForState;

bool Expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAILED: " << message << '\n';
  }
  return condition;
}

bool ExpectMenu(TrayCaptureState state,
                std::wstring_view label,
                bool enabled,
                TrayCaptureCommand command,
                std::string_view command_value) {
  const TrayCaptureMenuItem item = TrayMenuItemForState(state);
  return Expect(item.label == label, "unexpected tray menu label") &&
         Expect(item.enabled == enabled, "unexpected tray menu enabled state") &&
         Expect(item.command == command, "unexpected tray menu command") &&
         Expect(TrayCommandValue(item.command) == command_value,
                "unexpected tray command value");
}

bool TestStateParsingAndMenus() {
  struct Case {
    const char* value;
    TrayCaptureState state;
    const wchar_t* label;
    bool enabled;
    TrayCaptureCommand command;
    const char* command_value;
  };
  const Case cases[] = {
      {"stopped", TrayCaptureState::kStopped, L"开始录制", true,
       TrayCaptureCommand::kStartCapture, "startCapture"},
      {"starting", TrayCaptureState::kStarting, L"停止录制", false,
       TrayCaptureCommand::kStopCapture, "stopCapture"},
      {"recording", TrayCaptureState::kRecording, L"停止录制", true,
       TrayCaptureCommand::kStopCapture, "stopCapture"},
      {"paused", TrayCaptureState::kPaused, L"停止录制", true,
       TrayCaptureCommand::kStopCapture, "stopCapture"},
      {"stopping", TrayCaptureState::kStopping, L"停止录制", false,
       TrayCaptureCommand::kStopCapture, "stopCapture"},
      {"error", TrayCaptureState::kError, L"开始录制", true,
       TrayCaptureCommand::kStartCapture, "startCapture"},
  };

  for (const Case& test_case : cases) {
    TrayCaptureState parsed = TrayCaptureState::kError;
    if (!Expect(ParseTrayCaptureState(test_case.value, &parsed),
                "valid tray capture state was rejected") ||
        !Expect(parsed == test_case.state,
                "tray capture state parsed incorrectly") ||
        !ExpectMenu(test_case.state, test_case.label, test_case.enabled,
                    test_case.command, test_case.command_value)) {
      return false;
    }
  }
  return true;
}

bool TestInvalidStateParsing() {
  TrayCaptureState state = TrayCaptureState::kPaused;
  return Expect(!ParseTrayCaptureState("", &state),
                "empty tray capture state was accepted") &&
         Expect(state == TrayCaptureState::kPaused,
                "failed parse modified the output state") &&
         Expect(!ParseTrayCaptureState("capturing", &state),
                "unsupported tray capture state alias was accepted") &&
         Expect(!ParseTrayCaptureState("Recording", &state),
                "case-mismatched tray capture state was accepted") &&
         Expect(!ParseTrayCaptureState("stopped", nullptr),
                "null tray capture state output was accepted");
}

bool TestPendingCommandStates() {
  return Expect(
             PendingTrayCaptureState(TrayCaptureCommand::kStartCapture) ==
                 TrayCaptureState::kStarting,
             "start command did not enter the starting state") &&
         Expect(PendingTrayCaptureState(TrayCaptureCommand::kStopCapture) ==
                    TrayCaptureState::kStopping,
                "stop command did not enter the stopping state");
}

}  // namespace

int main() {
  if (!TestStateParsingAndMenus() || !TestInvalidStateParsing() ||
      !TestPendingCommandStates()) {
    return 1;
  }
  std::cout << "tray menu state mapping passed\n";
  return 0;
}
