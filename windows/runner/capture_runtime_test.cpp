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
  qi_day_flow::CaptureChunkProgress progress(60'000);
  for (uint32_t frame = 1; frame <= 58; ++frame) {
    const int64_t offset_ms = static_cast<int64_t>(frame - 1) * 1000;
    const qi_day_flow::CaptureLoopDecision decision =
        progress.OnFrameWritten(offset_ms);
    if (!Expect(!decision.rebuild_topology, "frame write rebuilt topology") ||
        !Expect(!decision.finalize_chunk,
                "frame count incorrectly finalized the chunk") ||
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
      progress.OnFrameWritten(59'050);
  const int64_t duration_ms = qi_day_flow::CalculateChunkDurationMs(
      60'000, 60'000, progress.latest_frame_offset_ms());
  const int64_t saturated_duration = qi_day_flow::CalculateChunkDurationMs(
      1, 1, std::numeric_limits<int64_t>::max());
  return Expect(!frame_60.finalize_chunk,
                "frame count incorrectly finalized a regular chunk") &&
         Expect(progress.frame_count() == 60,
                "frame count was not 60 at the regular boundary") &&
         Expect(progress.latest_frame_offset_ms() == 59'050,
                "frame offset was not continuous after a display switch") &&
         Expect(progress.ShouldFinalizeBeforeSample(59'999) == false,
                "chunk finalized before 60 seconds elapsed") &&
         Expect(progress.ShouldFinalizeBeforeSample(60'000),
                "chunk did not finalize at 60 monotonic seconds") &&
         Expect(duration_ms == 60'000,
                "regular chunk duration was not 60 seconds") &&
         Expect(saturated_duration == std::numeric_limits<int64_t>::max(),
                "chunk duration overflow was not saturated");
}

bool TestSupportedIntervalsAndVideoTiming() {
  const uint32_t intervals[] = {1, 10, 20, 30};
  const uint32_t expected_frames[] = {60, 6, 3, 2};
  for (size_t index = 0; index < 4; ++index) {
    const uint32_t interval = intervals[index];
    if (!Expect(qi_day_flow::IsSupportedCaptureIntervalSeconds(interval),
                "supported capture interval was rejected") ||
        !Expect(qi_day_flow::CalculateRegularChunkFrameCount(interval, 60) ==
                    expected_frames[index],
                "regular frame count did not match the interval")) {
      return false;
    }
    const qi_day_flow::CaptureVideoTiming timing =
        qi_day_flow::VideoTimingForInterval(interval);
    if (!Expect(timing.frame_rate_numerator == 1,
                "frame-rate numerator must be one") ||
        !Expect(timing.frame_rate_denominator == interval,
                "frame-rate denominator did not match the interval") ||
        !Expect(timing.frame_duration_ticks ==
                    static_cast<int64_t>(interval) * 10'000'000,
                "Media Foundation frame duration was incorrect") ||
        !Expect(qi_day_flow::CalculateEncodedDurationMs(
                    expected_frames[index], interval) == 60'000,
                "regular MP4 duration was not 60 seconds")) {
      return false;
    }
  }
  const uint32_t rejected[] = {0, 2, 9, 11, 19, 21, 29, 31, 60};
  for (const uint32_t interval : rejected) {
    if (!Expect(!qi_day_flow::IsSupportedCaptureIntervalSeconds(interval),
                "unsupported capture interval was accepted")) {
      return false;
    }
  }
  return true;
}

bool TestPartialThirtySecondIntervalUsesActualElapsedDuration() {
  const qi_day_flow::MediaSampleTiming timing =
      qi_day_flow::CalculateMediaSampleTiming(0, 5 * 10'000'000LL);
  return Expect(timing.timestamp_ticks == 0,
                "partial sample timestamp was not zero") &&
         Expect(timing.duration_ticks == 5 * 10'000'000LL,
                "partial sample used the nominal 30-second duration") &&
         Expect(timing.end_ticks == 5 * 10'000'000LL,
                "partial sample ended after actual elapsed time") &&
         Expect(qi_day_flow::MediaFoundationTicksToDurationMs(
                    timing.end_ticks) == 5'000,
                "partial metadata duration was not five seconds");
}

bool TestRegularChunksHaveExactActualTimings() {
  const uint32_t intervals[] = {1, 10, 20, 30};
  const uint32_t expected_frames[] = {60, 6, 3, 2};
  constexpr int64_t chunk_end_ticks = 60 * 10'000'000LL;
  for (size_t index = 0; index < 4; ++index) {
    const int64_t interval_ticks =
        static_cast<int64_t>(intervals[index]) * 10'000'000LL;
    int64_t encoded_end_ticks = 0;
    for (uint32_t frame = 0; frame < expected_frames[index]; ++frame) {
      const int64_t sample_ticks = frame * interval_ticks;
      const int64_t next_ticks =
          frame + 1 == expected_frames[index]
              ? chunk_end_ticks
              : (frame + 1) * interval_ticks;
      const qi_day_flow::MediaSampleTiming timing =
          qi_day_flow::CalculateMediaSampleTiming(sample_ticks, next_ticks);
      if (!Expect(timing.timestamp_ticks == encoded_end_ticks,
                  "regular samples were not contiguous") ||
          !Expect(timing.duration_ticks == interval_ticks,
                  "regular sample duration did not match its actual delta")) {
        return false;
      }
      encoded_end_ticks = timing.end_ticks;
    }
    if (!Expect(encoded_end_ticks == chunk_end_ticks,
                "regular MP4 duration was not exactly 60 seconds") ||
        !Expect(qi_day_flow::MediaFoundationTicksToDurationMs(
                    encoded_end_ticks) == 60'000,
                "regular metadata duration was not exactly 60 seconds")) {
      return false;
    }
  }
  return true;
}

bool TestDelayedSamplesUseMonotonicNonOverlappingTimestamps() {
  const int64_t sample_offsets[] = {
      0, 12 * 10'000'000LL, 31 * 10'000'000LL};
  const int64_t expected_durations[] = {
      12 * 10'000'000LL, 19 * 10'000'000LL, 29 * 10'000'000LL};
  constexpr int64_t chunk_end_ticks = 60 * 10'000'000LL;
  int64_t previous_end_ticks = 0;
  for (size_t index = 0; index < 3; ++index) {
    const int64_t next_ticks =
        index + 1 < 3 ? sample_offsets[index + 1] : chunk_end_ticks;
    const qi_day_flow::MediaSampleTiming timing =
        qi_day_flow::CalculateMediaSampleTiming(sample_offsets[index],
                                                next_ticks);
    if (!Expect(timing.timestamp_ticks == sample_offsets[index],
                "delayed sample lost its monotonic offset") ||
        !Expect(timing.timestamp_ticks >= previous_end_ticks,
                "delayed samples overlap") ||
        !Expect(timing.duration_ticks == expected_durations[index],
                "delayed sample duration did not use the next offset delta")) {
      return false;
    }
    previous_end_ticks = timing.end_ticks;
  }
  return Expect(previous_end_ticks == chunk_end_ticks,
                "delayed samples did not end at the chunk boundary");
}

bool TestMediaTimingMinimumTickAndOverflow() {
  const qi_day_flow::MediaSampleTiming minimum =
      qi_day_flow::CalculateMediaSampleTiming(42, 42);
  const qi_day_flow::MediaSampleTiming negative =
      qi_day_flow::CalculateMediaSampleTiming(-20, -10);
  const qi_day_flow::MediaSampleTiming overflow =
      qi_day_flow::CalculateMediaSampleTiming(
          std::numeric_limits<int64_t>::max(),
          std::numeric_limits<int64_t>::max());
  return Expect(minimum.timestamp_ticks == 42 && minimum.duration_ticks == 1 &&
                    minimum.end_ticks == 43,
                "zero elapsed duration did not become one tick") &&
         Expect(negative.timestamp_ticks == 0 && negative.duration_ticks == 1 &&
                    negative.end_ticks == 1,
                "negative timing was not clamped safely") &&
         Expect(overflow.timestamp_ticks ==
                    std::numeric_limits<int64_t>::max() - 1 &&
                    overflow.duration_ticks == 1 &&
                    overflow.end_ticks == std::numeric_limits<int64_t>::max(),
                "sample timing overflow was not saturated") &&
         Expect(qi_day_flow::MediaFoundationTicksToDurationMs(1) == 1,
                "minimum Media Foundation tick was lost in metadata") &&
         Expect(qi_day_flow::MediaFoundationTicksToDurationMs(
                    std::numeric_limits<int64_t>::max()) ==
                    std::numeric_limits<int64_t>::max() / 10'000 + 1,
                "tick-to-millisecond conversion overflowed");
}

bool TestAcquisitionDelayPreservesIndependentCadences() {
  const uint32_t intervals[] = {1, 10, 20, 30};
  const uint32_t expected_frames[] = {60, 6, 3, 2};
  for (size_t index = 0; index < 4; ++index) {
    qi_day_flow::CaptureSchedule schedule(intervals[index]);
    qi_day_flow::CaptureChunkProgress progress(60'000);
    schedule.Reset(0);
    uint32_t metadata_samples = 0;
    int64_t now_ms = 0;
    while (now_ms < 60'000) {
      const qi_day_flow::CaptureScheduleDecision due = schedule.Poll(now_ms);
      if (due.sample_metadata) {
        if (!Expect(now_ms % 1000 == 0,
                    "metadata opportunity drifted from its one-second phase")) {
          return false;
        }
        ++metadata_samples;
      }
      if (due.capture_frame) {
        const int64_t interval_ms =
            static_cast<int64_t>(intervals[index]) * 1000;
        if (!Expect(now_ms % interval_ms == 0,
                    "frame opportunity drifted from the planned phase")) {
          return false;
        }
        progress.OnFrameWritten(now_ms);
        now_ms += 100;
        schedule.OnFrameCaptured(now_ms);
      }
      now_ms += std::max<int64_t>(
          1, schedule.DelayUntilNextMs(now_ms));
    }
    if (!Expect(progress.frame_count() == expected_frames[index],
                "100 ms acquisition delay changed phase opportunities") ||
        !Expect(metadata_samples == 60,
                "metadata did not remain on an independent one-second phase") ||
        !Expect(progress.ShouldFinalizeBeforeSample(60'000),
                "boundary was not reported before the next sample")) {
      return false;
    }
  }
  return true;
}

bool TestResumeAndLatePollResetDeadlinesWithoutBurst() {
  qi_day_flow::CaptureSchedule schedule(10);
  schedule.Reset(0);
  const qi_day_flow::CaptureScheduleDecision initial = schedule.Poll(0);
  const qi_day_flow::CaptureScheduleDecision duplicate = schedule.Poll(0);
  if (!Expect(initial.capture_frame && initial.sample_metadata,
              "initial schedules were not due") ||
      !Expect(!duplicate.capture_frame && !duplicate.sample_metadata,
              "same deadline emitted duplicate work")) {
    return false;
  }

  const qi_day_flow::CaptureScheduleDecision late = schedule.Poll(25'000);
  const qi_day_flow::CaptureScheduleDecision after_late = schedule.Poll(25'000);
  if (!Expect(late.capture_frame && late.sample_metadata,
              "late poll did not emit one unit of due work") ||
      !Expect(!after_late.capture_frame && !after_late.sample_metadata,
              "late poll attempted catch-up work")) {
    return false;
  }

  schedule.Reset(40'000);
  const qi_day_flow::CaptureScheduleDecision resumed = schedule.Poll(40'000);
  const qi_day_flow::CaptureScheduleDecision one_second =
      schedule.Poll(41'000);
  const qi_day_flow::CaptureScheduleDecision ten_seconds =
      schedule.Poll(50'000);
  return Expect(resumed.capture_frame && resumed.sample_metadata,
                "resume did not establish fresh immediate deadlines") &&
         Expect(!one_second.capture_frame && one_second.sample_metadata,
                "metadata and frame cadences were not independent") &&
         Expect(ten_seconds.capture_frame && ten_seconds.sample_metadata,
                "fresh frame deadline did not use the selected interval");
}

bool TestMultiHourLatePollSkipsMissedPeriodsInPhase() {
  const uint32_t intervals[] = {1, 10, 20, 30};
  constexpr int64_t late_ms = 12 * 60 * 60 * 1000 + 250;
  for (const uint32_t interval : intervals) {
    qi_day_flow::CaptureSchedule schedule(interval);
    schedule.Reset(0);
    if (!Expect(schedule.Poll(0).capture_frame,
                "initial frame opportunity was not due")) {
      return false;
    }
    const qi_day_flow::CaptureScheduleDecision late = schedule.Poll(late_ms);
    const qi_day_flow::CaptureScheduleDecision duplicate =
        schedule.Poll(late_ms);
    if (!Expect(late.capture_frame && late.sample_metadata,
                "multi-hour late poll did not emit one due decision") ||
        !Expect(!duplicate.capture_frame && !duplicate.sample_metadata,
                "multi-hour late poll emitted catch-up work") ||
        !Expect(schedule.DelayUntilNextMs(late_ms) == 750,
                "late deadlines were not arithmetically phase aligned")) {
      return false;
    }
  }
  return true;
}

bool TestSuccessfulCaptureDoesNotReanchorFrameDeadline() {
  qi_day_flow::CaptureSchedule schedule(30);
  schedule.Reset(0);
  const qi_day_flow::CaptureScheduleDecision initial = schedule.Poll(0);
  schedule.OnFrameCaptured(100);
  const qi_day_flow::CaptureScheduleDecision planned_deadline =
      schedule.Poll(30'000);
  const qi_day_flow::CaptureScheduleDecision after_deadline =
      schedule.Poll(30'100);
  return Expect(initial.capture_frame,
                 "initial frame deadline was not due") &&
         Expect(planned_deadline.capture_frame,
                "capture completion re-anchored the planned deadline") &&
         Expect(!after_deadline.capture_frame,
                "planned deadline emitted duplicate work");
}

bool TestExtremeScheduleInputsSaturateWithoutDuplicateWork() {
  constexpr int64_t minimum = std::numeric_limits<int64_t>::min();
  constexpr int64_t maximum = std::numeric_limits<int64_t>::max();

  qi_day_flow::CaptureSchedule full_span(1);
  full_span.Reset(minimum);
  const qi_day_flow::CaptureScheduleDecision full_span_due =
      full_span.Poll(maximum);
  const qi_day_flow::CaptureScheduleDecision full_span_duplicate =
      full_span.Poll(maximum);
  if (!Expect(full_span_due.capture_frame && full_span_due.sample_metadata,
              "full-span extreme poll did not emit its single due decision") ||
      !Expect(!full_span_duplicate.capture_frame &&
                  !full_span_duplicate.sample_metadata,
              "full-span extreme poll emitted duplicate work")) {
    return false;
  }

  qi_day_flow::CaptureSchedule positive_span(1);
  positive_span.Reset(0);
  const qi_day_flow::CaptureScheduleDecision positive_span_due =
      positive_span.Poll(maximum);
  const qi_day_flow::CaptureScheduleDecision positive_span_duplicate =
      positive_span.Poll(maximum);
  return Expect(positive_span_due.capture_frame &&
                    positive_span_due.sample_metadata,
                "positive extreme poll did not emit its single due decision") &&
         Expect(!positive_span_duplicate.capture_frame &&
                    !positive_span_duplicate.sample_metadata,
                "positive extreme poll emitted duplicate work") &&
         Expect(positive_span.DelayUntilNextMs(maximum) == maximum,
                "exhausted schedules did not avoid a zero-delay busy loop");
}

bool TestWorkerControlAndBoundaryPrecedeTopologyInitialization() {
  using qi_day_flow::CaptureWorkerAction;
  using qi_day_flow::DecideCaptureWorkerAction;
  if (!Expect(DecideCaptureWorkerAction(true, false, false, true, 60'000,
                                        false) == CaptureWorkerAction::kStop,
              "stop did not precede topology initialization") ||
      !Expect(DecideCaptureWorkerAction(false, true, false, true, 60'000,
                                        false) == CaptureWorkerAction::kPause,
              "manual pause did not precede topology initialization") ||
      !Expect(DecideCaptureWorkerAction(false, false, true, true, 60'000,
                                        false) == CaptureWorkerAction::kPause,
              "idle pause did not precede topology initialization")) {
    return false;
  }

  uint32_t initialization_attempts = 0;
  for (int64_t elapsed_ms = 0; elapsed_ms <= 60'000; elapsed_ms += 5'000) {
    const CaptureWorkerAction action = DecideCaptureWorkerAction(
        false, false, false, true, elapsed_ms, false);
    if (elapsed_ms < 60'000) {
      if (!Expect(action == CaptureWorkerAction::kInitializeTopology,
                  "topology retry was not selected before the boundary")) {
        return false;
      }
      ++initialization_attempts;
    } else if (!Expect(action == CaptureWorkerAction::kFinalizeChunk,
                       "non-empty chunk did not rotate during init failure")) {
      return false;
    }
  }
  return Expect(initialization_attempts == 12,
                "topology failure simulation had an unexpected retry count") &&
         Expect(qi_day_flow::ShouldWakeCaptureRetryWait(false, true),
                "manual pause did not interrupt the topology retry wait") &&
         Expect(qi_day_flow::ShouldWakeCaptureRetryWait(true, false),
                "stop did not interrupt the topology retry wait") &&
         Expect(!qi_day_flow::ShouldWakeCaptureRetryWait(false, false),
                "retry wait woke without a control request") &&
         Expect(DecideCaptureWorkerAction(false, false, false, false, 60'000,
                                          false) ==
                    CaptureWorkerAction::kInitializeTopology,
                "empty chunk incorrectly requested finalization") &&
         Expect(DecideCaptureWorkerAction(false, false, false, true, 59'999,
                                          true) ==
                    CaptureWorkerAction::kPollSchedule,
                "ready worker did not proceed to its schedule");
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
  if (!TestSupportedIntervalsAndVideoTiming()) {
    return 2;
  }
  if (!TestPartialThirtySecondIntervalUsesActualElapsedDuration()) {
    return 3;
  }
  if (!TestRegularChunksHaveExactActualTimings()) {
    return 4;
  }
  if (!TestDelayedSamplesUseMonotonicNonOverlappingTimestamps()) {
    return 5;
  }
  if (!TestMediaTimingMinimumTickAndOverflow()) {
    return 6;
  }
  if (!TestAcquisitionDelayPreservesIndependentCadences()) {
    return 7;
  }
  if (!TestResumeAndLatePollResetDeadlinesWithoutBurst()) {
    return 8;
  }
  if (!TestMultiHourLatePollSkipsMissedPeriodsInPhase()) {
    return 9;
  }
  if (!TestSuccessfulCaptureDoesNotReanchorFrameDeadline()) {
    return 10;
  }
  if (!TestExtremeScheduleInputsSaturateWithoutDuplicateWork()) {
    return 11;
  }
  if (!TestWorkerControlAndBoundaryPrecedeTopologyInitialization()) {
    return 12;
  }
  if (!TestCpuUsageCalculation()) {
    return 13;
  }
  if (!TestInvalidCpuIntervalsAndMemoryCommit()) {
    return 14;
  }
  std::cout << "capture runtime state and resource calculations passed\n";
  return 0;
}
