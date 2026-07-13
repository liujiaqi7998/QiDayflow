#include "exit_lifecycle.h"

namespace qi_day_flow {

bool ExitLifecycle::RequestExit() {
  if (exit_requested_) {
    return false;
  }
  exit_requested_ = true;
  return true;
}

bool ExitLifecycle::BeginShutdown() {
  if (shutdown_started_) {
    return false;
  }
  shutdown_started_ = true;
  return true;
}

bool ExitLifecycle::CompleteShutdown() {
  if (!shutdown_started_ || destroy_ready_) {
    return false;
  }
  destroy_ready_ = true;
  return true;
}

}  // namespace qi_day_flow
