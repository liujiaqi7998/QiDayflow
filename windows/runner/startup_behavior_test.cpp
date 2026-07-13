#include "startup_behavior.h"

#include <iostream>
#include <string>

namespace {

bool Expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAILED: " << message << '\n';
  }
  return condition;
}

bool TestBackgroundArguments() {
  return Expect(!qi_day_flow::HasBackgroundArgument({}),
                "empty arguments started in background") &&
         Expect(qi_day_flow::HasBackgroundArgument({"--background"}),
                "exact background argument was rejected") &&
         Expect(qi_day_flow::HasBackgroundArgument(
                    {"--verbose", "--background"}),
                "background argument was position-dependent") &&
         Expect(!qi_day_flow::HasBackgroundArgument({"--Background"}),
                "case-mismatched background argument was accepted") &&
         Expect(!qi_day_flow::HasBackgroundArgument({"--background=true"}),
                "background argument prefix was accepted");
}

bool TestLaunchAtLoginCommand() {
  const std::wstring executable =
      LR"(C:\Program Files\Qi Day Flow\qi_day_flow.exe)";
  const std::wstring expected =
      LR"("C:\Program Files\Qi Day Flow\qi_day_flow.exe" --background)";
  return Expect(qi_day_flow::BuildLaunchAtLoginCommand(executable) == expected,
                "launch command was not safely quoted") &&
         Expect(qi_day_flow::IsExpectedLaunchAtLoginCommand(expected,
                                                             executable),
                "exact launch command did not match") &&
         Expect(!qi_day_flow::IsExpectedLaunchAtLoginCommand(
                    executable + L" --background", executable),
                "unquoted launch command matched") &&
         Expect(!qi_day_flow::IsExpectedLaunchAtLoginCommand(expected + L" ",
                                                              executable),
                "launch command with trailing whitespace matched") &&
         Expect(!qi_day_flow::IsExpectedLaunchAtLoginCommand(
                    expected + L" --extra", executable),
                "launch command with extra arguments matched") &&
         Expect(!qi_day_flow::IsExpectedLaunchAtLoginCommand(
                    LR"("C:\Program Files\Qi Day Flow\other.exe" --background)",
                    executable),
                "launch command for a different executable matched") &&
         Expect(qi_day_flow::BuildLaunchAtLoginCommand(
                    LR"(C:\bad"path\app.exe)")
                    .empty(),
                "unsafe executable path produced a launch command");
}

bool TestLaunchAtLoginRemovalDecision() {
  const std::wstring executable =
      LR"(C:\Program Files\Qi Day Flow\qi_day_flow.exe)";
  const std::wstring expected =
      qi_day_flow::BuildLaunchAtLoginCommand(executable);
  using Decision = qi_day_flow::LaunchAtLoginRemovalDecision;
  const Decision before_concurrent_change =
      qi_day_flow::DecideLaunchAtLoginRemoval(true, expected, executable);
  const Decision after_concurrent_change =
      qi_day_flow::DecideLaunchAtLoginRemoval(
          true, L"externally-replaced-command", executable);
  return Expect(qi_day_flow::DecideLaunchAtLoginRemoval(
                    false, L"", executable) == Decision::kAlreadyAbsent,
                "missing value was not treated as already disabled") &&
         Expect(qi_day_flow::DecideLaunchAtLoginRemoval(
                    true, expected, executable) ==
                    Decision::kDeleteExpectedValue,
                "owned launch value was not approved for deletion") &&
         Expect(qi_day_flow::DecideLaunchAtLoginRemoval(
                    true, L"externally-managed-command", executable) ==
                    Decision::kConflict,
                "external launch value was approved for deletion") &&
         Expect(qi_day_flow::DecideLaunchAtLoginRemoval(
                    true, expected, L"") == Decision::kConflict,
                "invalid executable path was approved for deletion") &&
         Expect(before_concurrent_change == Decision::kDeleteExpectedValue &&
                    after_concurrent_change == Decision::kConflict,
                "concurrent external replacement was approved for deletion");
}

bool TestLaunchAtLoginWriteDecision() {
  const std::wstring executable =
      LR"(C:\Program Files\Qi Day Flow\qi_day_flow.exe)";
  const std::wstring expected =
      qi_day_flow::BuildLaunchAtLoginCommand(executable);
  using Decision = qi_day_flow::LaunchAtLoginWriteDecision;
  return Expect(qi_day_flow::DecideLaunchAtLoginWrite(
                    false, L"", executable) == Decision::kWriteExpectedValue,
                "missing launch value was not approved for creation") &&
         Expect(qi_day_flow::DecideLaunchAtLoginWrite(
                    true, expected, executable) == Decision::kAlreadyExpected,
                "owned launch value was not treated as already enabled") &&
         Expect(qi_day_flow::DecideLaunchAtLoginWrite(
                    true, L"externally-managed-command", executable) ==
                    Decision::kConflict,
                "external launch value was approved for overwrite") &&
         Expect(qi_day_flow::DecideLaunchAtLoginWrite(
                    false, L"", L"") == Decision::kConflict,
                "invalid executable path was approved for creation");
}

}  // namespace

int main() {
  if (!TestBackgroundArguments() || !TestLaunchAtLoginCommand() ||
      !TestLaunchAtLoginRemovalDecision() ||
      !TestLaunchAtLoginWriteDecision()) {
    return 1;
  }
  std::cout << "startup behavior mapping passed\n";
  return 0;
}
