#ifndef RUNNER_CAPTURE_RUNTIME_H_
#define RUNNER_CAPTURE_RUNTIME_H_

#include <cstdint>
#include <optional>

namespace qi_day_flow {

struct CaptureLoopDecision {
  bool rebuild_topology = false;
  bool finalize_chunk = false;
};

class CaptureChunkProgress {
 public:
  explicit CaptureChunkProgress(uint32_t regular_frame_count);

  void Configure(uint32_t regular_frame_count);
  void Reset();
  uint32_t frame_count() const;
  int64_t latest_frame_offset_ms() const;

  CaptureLoopDecision OnTopologyChanged() const;
  CaptureLoopDecision OnTopologyCheckUnavailable() const;
  CaptureLoopDecision OnRecoverableCaptureError() const;
  CaptureLoopDecision OnFrameWritten(int64_t offset_ms);

 private:
  uint32_t regular_frame_count_ = 1;
  uint32_t frame_count_ = 0;
  int64_t latest_frame_offset_ms_ = 0;
};

int64_t CalculateChunkDurationMs(int64_t elapsed_ms,
                                 int64_t encoded_duration_ms,
                                 int64_t latest_frame_offset_ms);

struct ProcessCpuSample {
  uint32_t process_id = 0;
  uint64_t creation_time_100ns = 0;
  uint64_t process_time_100ns = 0;
  uint64_t wall_time_100ns = 0;
};

std::optional<double> CalculateCpuUsagePercent(
    const std::optional<ProcessCpuSample>& previous,
    const ProcessCpuSample& current,
    uint32_t logical_processor_count);

std::optional<uint64_t> PrivateUsageToMemoryCommitBytes(
    bool query_succeeded,
    uint64_t private_usage_bytes);

}  // namespace qi_day_flow

#endif  // RUNNER_CAPTURE_RUNTIME_H_
