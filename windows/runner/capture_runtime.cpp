#include "capture_runtime.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace qi_day_flow {
namespace {

constexpr int64_t kMetadataIntervalMs = 1000;
constexpr int64_t kMediaFoundationTicksPerSecond = 10'000'000;

struct DeadlineAdvance {
  int64_t deadline_ms;
  bool exhausted;
};

DeadlineAdvance AdvanceDeadlinePast(int64_t deadline_ms,
                                    int64_t now_ms,
                                    int64_t period_ms) {
  if (now_ms < deadline_ms) {
    return {deadline_ms, false};
  }

  const uint64_t period = static_cast<uint64_t>(period_ms);
  const uint64_t elapsed = static_cast<uint64_t>(now_ms) -
                           static_cast<uint64_t>(deadline_ms);
  const uint64_t completed_periods = elapsed / period;
  const uint64_t room =
      static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) -
      static_cast<uint64_t>(deadline_ms);
  const uint64_t maximum_periods = room / period;
  if (completed_periods >= maximum_periods) {
    return {std::numeric_limits<int64_t>::max(), true};
  }

  const uint64_t advance = (completed_periods + 1) * period;
  if (deadline_ms >= 0) {
    return {deadline_ms + static_cast<int64_t>(advance), false};
  }

  const uint64_t distance_to_zero =
      static_cast<uint64_t>(-(deadline_ms + 1)) + 1;
  if (advance >= distance_to_zero) {
    return {static_cast<int64_t>(advance - distance_to_zero), false};
  }
  return {deadline_ms + static_cast<int64_t>(advance), false};
}

}  // namespace

CaptureWorkerAction DecideCaptureWorkerAction(bool stop_requested,
                                              bool manual_paused,
                                              bool idle_paused,
                                              bool chunk_has_frames,
                                              int64_t chunk_elapsed_ms,
                                              bool topology_available) {
  if (stop_requested) {
    return CaptureWorkerAction::kStop;
  }
  if (manual_paused || idle_paused) {
    return CaptureWorkerAction::kPause;
  }
  if (chunk_has_frames && chunk_elapsed_ms >= 60'000) {
    return CaptureWorkerAction::kFinalizeChunk;
  }
  if (!topology_available) {
    return CaptureWorkerAction::kInitializeTopology;
  }
  return CaptureWorkerAction::kPollSchedule;
}

bool ShouldWakeCaptureRetryWait(bool stop_requested, bool manual_paused) {
  return stop_requested || manual_paused;
}

bool IsSupportedCaptureIntervalSeconds(uint32_t interval_seconds) {
  return interval_seconds == 1 || interval_seconds == 10 ||
         interval_seconds == 20 || interval_seconds == 30;
}

uint32_t CalculateRegularChunkFrameCount(uint32_t interval_seconds,
                                         uint32_t duration_seconds) {
  if (interval_seconds == 0 || duration_seconds == 0) {
    return 0;
  }
  return (duration_seconds + interval_seconds - 1) / interval_seconds;
}

CaptureVideoTiming VideoTimingForInterval(uint32_t interval_seconds) {
  const uint32_t safe_interval = std::max<uint32_t>(1, interval_seconds);
  return CaptureVideoTiming{
      1,
      safe_interval,
      static_cast<int64_t>(safe_interval) * kMediaFoundationTicksPerSecond,
  };
}

MediaSampleTiming CalculateMediaSampleTiming(int64_t sample_offset_ticks,
                                             int64_t end_offset_ticks) {
  constexpr int64_t kMaximumTimestamp =
      std::numeric_limits<int64_t>::max() - 1;
  const int64_t timestamp_ticks =
      std::clamp<int64_t>(sample_offset_ticks, 0, kMaximumTimestamp);
  const int64_t requested_end_ticks = std::clamp<int64_t>(
      end_offset_ticks, 0, std::numeric_limits<int64_t>::max());
  const int64_t actual_end_ticks =
      requested_end_ticks > timestamp_ticks ? requested_end_ticks
                                            : timestamp_ticks + 1;
  return MediaSampleTiming{
      timestamp_ticks,
      actual_end_ticks - timestamp_ticks,
      actual_end_ticks,
  };
}

int64_t MediaFoundationTicksToDurationMs(int64_t duration_ticks) {
  constexpr int64_t kTicksPerMillisecond =
      kMediaFoundationTicksPerSecond / 1000;
  if (duration_ticks <= 0) {
    return 1;
  }
  const int64_t whole_milliseconds = duration_ticks / kTicksPerMillisecond;
  return std::max<int64_t>(
      1, whole_milliseconds +
             (duration_ticks % kTicksPerMillisecond == 0 ? 0 : 1));
}

int64_t CalculateEncodedDurationMs(uint32_t frame_count,
                                   uint32_t interval_seconds) {
  const uint64_t duration_ms = static_cast<uint64_t>(frame_count) *
                               static_cast<uint64_t>(interval_seconds) * 1000;
  return duration_ms > static_cast<uint64_t>(
                           std::numeric_limits<int64_t>::max())
             ? std::numeric_limits<int64_t>::max()
             : static_cast<int64_t>(duration_ms);
}

CaptureSchedule::CaptureSchedule(uint32_t capture_interval_seconds) {
  Configure(capture_interval_seconds);
}

void CaptureSchedule::Configure(uint32_t capture_interval_seconds) {
  frame_interval_ms_ =
      static_cast<int64_t>(std::max<uint32_t>(1, capture_interval_seconds)) *
      1000;
  next_frame_ms_ = 0;
  next_metadata_ms_ = 0;
  frame_schedule_exhausted_ = false;
  metadata_schedule_exhausted_ = false;
}

void CaptureSchedule::Reset(int64_t now_ms) {
  next_frame_ms_ = now_ms;
  next_metadata_ms_ = now_ms;
  frame_schedule_exhausted_ = false;
  metadata_schedule_exhausted_ = false;
}

CaptureScheduleDecision CaptureSchedule::Poll(int64_t now_ms) {
  CaptureScheduleDecision decision;
  if (!frame_schedule_exhausted_ && now_ms >= next_frame_ms_) {
    decision.capture_frame = true;
    const DeadlineAdvance next =
        AdvanceDeadlinePast(next_frame_ms_, now_ms, frame_interval_ms_);
    next_frame_ms_ = next.deadline_ms;
    frame_schedule_exhausted_ = next.exhausted;
  }
  if (!metadata_schedule_exhausted_ && now_ms >= next_metadata_ms_) {
    decision.sample_metadata = true;
    const DeadlineAdvance next =
        AdvanceDeadlinePast(next_metadata_ms_, now_ms, kMetadataIntervalMs);
    next_metadata_ms_ = next.deadline_ms;
    metadata_schedule_exhausted_ = next.exhausted;
  }
  return decision;
}

void CaptureSchedule::OnFrameCaptured(int64_t now_ms) {
  static_cast<void>(now_ms);
}

int64_t CaptureSchedule::DelayUntilNextMs(int64_t now_ms) const {
  if (frame_schedule_exhausted_ && metadata_schedule_exhausted_) {
    return std::numeric_limits<int64_t>::max();
  }
  const int64_t next_ms = frame_schedule_exhausted_
                              ? next_metadata_ms_
                              : metadata_schedule_exhausted_
                                  ? next_frame_ms_
                                  : std::min(next_frame_ms_, next_metadata_ms_);
  if (next_ms <= now_ms) {
    return 0;
  }
  const uint64_t delay = static_cast<uint64_t>(next_ms) -
                         static_cast<uint64_t>(now_ms);
  return delay >
                 static_cast<uint64_t>(std::numeric_limits<int64_t>::max())
             ? std::numeric_limits<int64_t>::max()
             : static_cast<int64_t>(delay);
}

CaptureChunkProgress::CaptureChunkProgress(
    int64_t regular_chunk_duration_ms) {
  Configure(regular_chunk_duration_ms);
}

void CaptureChunkProgress::Configure(int64_t regular_chunk_duration_ms) {
  regular_chunk_duration_ms_ =
      std::max<int64_t>(1, regular_chunk_duration_ms);
  frame_count_ = 0;
  latest_frame_offset_ms_ = 0;
}

void CaptureChunkProgress::Reset() {
  frame_count_ = 0;
  latest_frame_offset_ms_ = 0;
}

uint32_t CaptureChunkProgress::frame_count() const {
  return frame_count_;
}

int64_t CaptureChunkProgress::latest_frame_offset_ms() const {
  return latest_frame_offset_ms_;
}

bool CaptureChunkProgress::ShouldFinalizeBeforeSample(
    int64_t elapsed_ms) const {
  return frame_count_ > 0 && elapsed_ms >= regular_chunk_duration_ms_;
}

CaptureLoopDecision CaptureChunkProgress::OnTopologyChanged() const {
  return CaptureLoopDecision{true, false};
}

CaptureLoopDecision CaptureChunkProgress::OnTopologyCheckUnavailable() const {
  return CaptureLoopDecision{true, false};
}

CaptureLoopDecision CaptureChunkProgress::OnRecoverableCaptureError() const {
  return CaptureLoopDecision{true, false};
}

CaptureLoopDecision CaptureChunkProgress::OnFrameWritten(int64_t offset_ms) {
  latest_frame_offset_ms_ =
      std::max(latest_frame_offset_ms_, std::max<int64_t>(0, offset_ms));
  if (frame_count_ < std::numeric_limits<uint32_t>::max()) {
    ++frame_count_;
  }
  return CaptureLoopDecision{false, false};
}

int64_t CalculateChunkDurationMs(int64_t elapsed_ms,
                                 int64_t encoded_duration_ms,
                                 int64_t latest_frame_offset_ms) {
  const int64_t latest_frame_end_ms =
      latest_frame_offset_ms >= std::numeric_limits<int64_t>::max()
          ? std::numeric_limits<int64_t>::max()
          : std::max<int64_t>(0, latest_frame_offset_ms) + 1;
  return std::max<int64_t>(
      1, std::max(elapsed_ms,
                  std::max(encoded_duration_ms, latest_frame_end_ms)));
}

std::optional<double> CalculateCpuUsagePercent(
    const std::optional<ProcessCpuSample>& previous,
    const ProcessCpuSample& current,
    uint32_t logical_processor_count) {
  if (!previous.has_value() || logical_processor_count == 0 ||
      previous->process_id != current.process_id ||
      previous->creation_time_100ns != current.creation_time_100ns ||
      current.wall_time_100ns <= previous->wall_time_100ns ||
      current.process_time_100ns < previous->process_time_100ns) {
    return std::nullopt;
  }

  const uint64_t process_delta =
      current.process_time_100ns - previous->process_time_100ns;
  const uint64_t wall_delta =
      current.wall_time_100ns - previous->wall_time_100ns;
  const long double percentage =
      static_cast<long double>(process_delta) * 100.0L /
      (static_cast<long double>(wall_delta) * logical_processor_count);
  if (!std::isfinite(percentage)) {
    return std::nullopt;
  }
  return static_cast<double>(std::clamp<long double>(percentage, 0.0L, 100.0L));
}

std::optional<uint64_t> PrivateUsageToMemoryCommitBytes(
    bool query_succeeded,
    uint64_t private_usage_bytes) {
  if (!query_succeeded) {
    return std::nullopt;
  }
  return private_usage_bytes;
}

}  // namespace qi_day_flow
