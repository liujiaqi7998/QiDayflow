#include "capture_runtime.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace qi_day_flow {

CaptureChunkProgress::CaptureChunkProgress(uint32_t regular_frame_count) {
  Configure(regular_frame_count);
}

void CaptureChunkProgress::Configure(uint32_t regular_frame_count) {
  regular_frame_count_ = std::max<uint32_t>(1, regular_frame_count);
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
  return CaptureLoopDecision{false,
                             frame_count_ >= regular_frame_count_};
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
