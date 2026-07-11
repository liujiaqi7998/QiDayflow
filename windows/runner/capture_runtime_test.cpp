#include "capture_runtime.h"

#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <optional>

namespace {

bool Expect(bool condition, const char* message) {
  if (condition) {
    return true;
  }
  std::cerr << message << '\n';
  return false;
}

bool ExpectNear(double actual,
                double expected,
                double tolerance,
                const char* message) {
  return Expect(std::abs(actual - expected) <= tolerance, message);
}

bool TestTopologyChangeKeepsChunkProgress() {
  qi_day_flow::CaptureChunkProgress progress(60);
  for (uint32_t frame = 1; frame <= 58; ++frame) {
    const int64_t offset_ms = static_cast<int64_t>(frame - 1) * 1000;
    const qi_day_flow::CaptureLoopDecision decision =
        progress.OnFrameWritten(offset_ms);
    if (!Expect(!decision.rebuild_topology, "frame write rebuilt topology") ||
        !Expect(!decision.finalize_chunk,
                "chunk finalized before the sixtieth frame") ||
        !Expect(progress.frame_count() == frame,
                "successful frame count did not advance")) {
      return false;
    }
  }

  const qi_day_flow::CaptureLoopDecision topology =
      progress.OnTopologyChanged();
  if (!Expect(topology.rebuild_topology,
              "display switch did not request topology rebuild") ||
      !Expect(!topology.finalize_chunk,
              "display switch incorrectly finalized the active chunk") ||
      !Expect(progress.frame_count() == 58,
              "display switch reset the active chunk frame count") ||
      !Expect(progress.latest_frame_offset_ms() == 57'000,
              "display switch reset the active chunk frame offset")) {
    return false;
  }

  const qi_day_flow::CaptureLoopDecision topology_unavailable =
      progress.OnTopologyCheckUnavailable();
  if (!Expect(topology_unavailable.rebuild_topology,
              "failed topology check did not request a rebuild") ||
      !Expect(!topology_unavailable.finalize_chunk,
              "failed topology check incorrectly finalized the chunk") ||
      !Expect(progress.frame_count() == 58,
              "failed topology check changed the frame count") ||
      !Expect(progress.latest_frame_offset_ms() == 57'000,
              "failed topology check changed the frame offset")) {
    return false;
  }

  const qi_day_flow::CaptureLoopDecision access_lost =
      progress.OnRecoverableCaptureError();
  if (!Expect(access_lost.rebuild_topology,
              "recoverable capture error did not request a rebuild") ||
      !Expect(!access_lost.finalize_chunk,
              "recoverable capture error incorrectly finalized the chunk") ||
      !Expect(progress.frame_count() == 58,
              "recoverable capture error changed the frame count") ||
      !Expect(progress.latest_frame_offset_ms() == 57'000,
              "recoverable capture error changed the frame offset")) {
    return false;
  }

  const qi_day_flow::CaptureLoopDecision frame_59 =
      progress.OnFrameWritten(59'000);
  if (!Expect(!frame_59.finalize_chunk,
              "chunk finalized on frame 59 after a display switch") ||
      !Expect(progress.frame_count() == 59,
              "frame 59 was not continuous across a display switch")) {
    return false;
  }
  const qi_day_flow::CaptureLoopDecision frame_60 =
      progress.OnFrameWritten(60'050);
  const int64_t duration_ms = qi_day_flow::CalculateChunkDurationMs(
      60'000, 60'000, progress.latest_frame_offset_ms());
  const int64_t saturated_duration = qi_day_flow::CalculateChunkDurationMs(
      1, 1, std::numeric_limits<int64_t>::max());
  return Expect(frame_60.finalize_chunk,
                "chunk did not finalize on frame 60") &&
         Expect(progress.frame_count() == 60,
                "frame count was not 60 at the regular boundary") &&
         Expect(progress.latest_frame_offset_ms() == 60'050,
                "frame offset was not continuous after a display switch") &&
         Expect(duration_ms == 60'051,
                "chunk duration did not include the final frame metadata") &&
         Expect(saturated_duration == std::numeric_limits<int64_t>::max(),
                "chunk duration overflow was not saturated");
}

bool TestCpuUsageCalculation() {
  using qi_day_flow::ProcessCpuSample;
  const ProcessCpuSample first{
      42,
      100,
      10'000'000,
      20'000'000,
  };
  if (!Expect(!qi_day_flow::CalculateCpuUsagePercent(std::nullopt, first, 4)
                   .has_value(),
              "first CPU sample must be unavailable")) {
    return false;
  }

  const ProcessCpuSample second{
      42,
      100,
      30'000'000,
      30'000'000,
  };
  const std::optional<double> fifty_percent =
      qi_day_flow::CalculateCpuUsagePercent(first, second, 4);
  if (!Expect(fifty_percent.has_value(),
              "adjacent CPU samples did not produce a value") ||
      !ExpectNear(*fifty_percent, 50.0, 0.000001,
                  "CPU usage did not divide by logical processor count")) {
    return false;
  }

  ProcessCpuSample changed_pid = second;
  changed_pid.process_id = 43;
  if (!Expect(!qi_day_flow::CalculateCpuUsagePercent(first, changed_pid, 4)
                   .has_value(),
              "PID change must reset CPU usage")) {
    return false;
  }
  ProcessCpuSample reused_pid = second;
  reused_pid.creation_time_100ns = 101;
  if (!Expect(!qi_day_flow::CalculateCpuUsagePercent(first, reused_pid, 4)
                   .has_value(),
              "PID reuse must reset CPU usage")) {
    return false;
  }

  const ProcessCpuSample over_capacity{
      42,
      100,
      90'000'000,
      30'000'000,
  };
  const std::optional<double> clamped =
      qi_day_flow::CalculateCpuUsagePercent(first, over_capacity, 4);
  return Expect(clamped.has_value(), "over-capacity CPU sample was rejected") &&
         ExpectNear(*clamped, 100.0, 0.000001,
                    "CPU usage was not clamped to 100 percent");
}

bool TestInvalidCpuIntervalsAndMemoryCommit() {
  using qi_day_flow::ProcessCpuSample;
  const ProcessCpuSample previous{7, 22, 500, 1'000};
  const ProcessCpuSample zero_wall{7, 22, 600, 1'000};
  const ProcessCpuSample regressed_cpu{7, 22, 499, 2'000};
  if (!Expect(!qi_day_flow::CalculateCpuUsagePercent(previous, zero_wall, 8)
                   .has_value(),
              "zero wall-clock delta must be unavailable") ||
      !Expect(!qi_day_flow::CalculateCpuUsagePercent(previous, regressed_cpu, 8)
                   .has_value(),
              "regressed process time must be unavailable") ||
      !Expect(!qi_day_flow::CalculateCpuUsagePercent(previous, regressed_cpu, 0)
                   .has_value(),
              "zero logical processor count must be unavailable")) {
    return false;
  }

  const std::optional<uint64_t> memory =
      qi_day_flow::PrivateUsageToMemoryCommitBytes(true, 987'654'321);
  return Expect(memory == 987'654'321,
                "memory commit did not use PrivateUsage bytes") &&
         Expect(!qi_day_flow::PrivateUsageToMemoryCommitBytes(
                     false, 987'654'321)
                     .has_value(),
                "failed memory query must be unavailable");
}

}  // namespace

int main() {
  if (!TestTopologyChangeKeepsChunkProgress()) {
    return 1;
  }
  if (!TestCpuUsageCalculation()) {
    return 2;
  }
  if (!TestInvalidCpuIntervalsAndMemoryCommit()) {
    return 3;
  }
  std::cout << "capture runtime state and resource calculations passed\n";
  return 0;
}
