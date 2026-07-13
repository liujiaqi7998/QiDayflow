#include "exit_lifecycle.h"

#include <cassert>
#include <chrono>

int main() {
  using qi_day_flow::ExitLifecycle;

  static_assert(qi_day_flow::kExitFallbackTimeout >
                std::chrono::seconds(15));

  ExitLifecycle lifecycle;
  assert(lifecycle.RequestExit());
  assert(!lifecycle.RequestExit());
  assert(lifecycle.BeginShutdown());
  assert(!lifecycle.BeginShutdown());
  assert(!lifecycle.destroy_ready());
  assert(lifecycle.CompleteShutdown());
  assert(lifecycle.destroy_ready());
  assert(!lifecycle.CompleteShutdown());
  return 0;
}
