#include "startup_behavior.h"

#include <algorithm>

namespace qi_day_flow {

bool HasBackgroundArgument(const std::vector<std::string>& arguments) {
  return std::find(arguments.begin(), arguments.end(), "--background") !=
         arguments.end();
}

std::wstring BuildLaunchAtLoginCommand(
    const std::wstring& canonical_executable_path) {
  if (canonical_executable_path.empty() ||
      canonical_executable_path.find(L'\"') != std::wstring::npos) {
    return {};
  }
  return L"\"" + canonical_executable_path + L"\" --background";
}

bool IsExpectedLaunchAtLoginCommand(
    const std::wstring& registry_value,
    const std::wstring& canonical_executable_path) {
  const std::wstring expected =
      BuildLaunchAtLoginCommand(canonical_executable_path);
  return !expected.empty() && registry_value == expected;
}

LaunchAtLoginRemovalDecision DecideLaunchAtLoginRemoval(
    bool value_exists,
    const std::wstring& registry_value,
    const std::wstring& canonical_executable_path) {
  if (!value_exists) {
    return LaunchAtLoginRemovalDecision::kAlreadyAbsent;
  }
  return IsExpectedLaunchAtLoginCommand(registry_value,
                                        canonical_executable_path)
             ? LaunchAtLoginRemovalDecision::kDeleteExpectedValue
             : LaunchAtLoginRemovalDecision::kConflict;
}

LaunchAtLoginWriteDecision DecideLaunchAtLoginWrite(
    bool value_exists,
    const std::wstring& registry_value,
    const std::wstring& canonical_executable_path) {
  if (BuildLaunchAtLoginCommand(canonical_executable_path).empty()) {
    return LaunchAtLoginWriteDecision::kConflict;
  }
  if (!value_exists) {
    return LaunchAtLoginWriteDecision::kWriteExpectedValue;
  }
  return IsExpectedLaunchAtLoginCommand(registry_value,
                                        canonical_executable_path)
             ? LaunchAtLoginWriteDecision::kAlreadyExpected
             : LaunchAtLoginWriteDecision::kConflict;
}

}  // namespace qi_day_flow
