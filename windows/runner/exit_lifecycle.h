#ifndef RUNNER_EXIT_LIFECYCLE_H_
#define RUNNER_EXIT_LIFECYCLE_H_

#include <chrono>

namespace qi_day_flow {

inline constexpr std::chrono::milliseconds kExitFallbackTimeout =
    std::chrono::seconds(30);

class ExitLifecycle {
 public:
  bool RequestExit();
  bool BeginShutdown();
  bool CompleteShutdown();

  bool shutdown_started() const { return shutdown_started_; }
  bool destroy_ready() const { return destroy_ready_; }
  bool exit_requested() const { return exit_requested_; }

 private:
  bool exit_requested_ = false;
  bool shutdown_started_ = false;
  bool destroy_ready_ = false;
};

}  // namespace qi_day_flow

#endif  // RUNNER_EXIT_LIFECYCLE_H_
