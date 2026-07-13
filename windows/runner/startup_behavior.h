#ifndef RUNNER_STARTUP_BEHAVIOR_H_
#define RUNNER_STARTUP_BEHAVIOR_H_

#include <string>
#include <vector>

namespace qi_day_flow {

enum class LaunchAtLoginRemovalDecision {
  kAlreadyAbsent,
  kDeleteExpectedValue,
  kConflict,
};

enum class LaunchAtLoginWriteDecision {
  kWriteExpectedValue,
  kAlreadyExpected,
  kConflict,
};

bool HasBackgroundArgument(const std::vector<std::string>& arguments);

std::wstring BuildLaunchAtLoginCommand(
    const std::wstring& canonical_executable_path);

bool IsExpectedLaunchAtLoginCommand(
    const std::wstring& registry_value,
    const std::wstring& canonical_executable_path);

LaunchAtLoginRemovalDecision DecideLaunchAtLoginRemoval(
    bool value_exists,
    const std::wstring& registry_value,
    const std::wstring& canonical_executable_path);

LaunchAtLoginWriteDecision DecideLaunchAtLoginWrite(
    bool value_exists,
    const std::wstring& registry_value,
    const std::wstring& canonical_executable_path);

}  // namespace qi_day_flow

#endif  // RUNNER_STARTUP_BEHAVIOR_H_
