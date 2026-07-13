#ifndef RUNNER_CAPTURE_RUNTIME_H_
#define RUNNER_CAPTURE_RUNTIME_H_

#include <cstdint>
#include <optional>

namespace qi_day_flow {

constexpr uint32_t kDefaultCaptureIntervalSeconds = 10;
constexpr double kDefaultCaptureFramesPerSecond =
    1.0 / kDefaultCaptureIntervalSeconds;
constexpr uint32_t kDefaultRegularChunkFrameCount = 6;

struct CaptureStopPlan {
  bool accepted = false;
  bool request_stop = false;
  bool join_worker = false;
};

CaptureStopPlan PlanCaptureStop(bool already_stopped);

enum class InitialSessionLockState { kLocked, kUnlocked, kUnknown };

enum class SessionNotificationCommand { kNone, kLock, kUnlock };

struct SessionNotificationLifecycle {
  bool keep_window = false;
  bool unregister_on_destroy = false;
};

SessionNotificationCommand SessionNotificationCommandForEvent(
    uint32_t event_code);
SessionNotificationLifecycle PlanSessionNotificationLifecycle(
    bool base_created,
    bool registration_succeeded);
bool ShouldPauseForInitialSessionState(
    bool registration_succeeded,
    InitialSessionLockState state);

struct CaptureLoopDecision {
  bool rebuild_topology = false;
  bool finalize_chunk = false;
};

enum class CaptureWorkerAction {
  kStop,
  kPause,
  kFinalizeChunk,
  kInitializeTopology,
  kPollSchedule,
};

CaptureWorkerAction DecideCaptureWorkerAction(bool stop_requested,
                                              bool manual_paused,
                                              bool system_paused,
                                              bool idle_paused,
                                              bool chunk_has_frames,
                                              int64_t chunk_elapsed_ms,
                                              bool topology_available);

bool ShouldWakeCaptureRetryWait(bool stop_requested,
                                bool manual_paused,
                                bool system_paused);

bool IsSupportedCaptureIntervalSeconds(uint32_t interval_seconds);

uint32_t CalculateRegularChunkFrameCount(uint32_t interval_seconds,
                                         uint32_t duration_seconds);

struct CaptureVideoTiming {
  uint32_t frame_rate_numerator = 1;
  uint32_t frame_rate_denominator = 1;
  int64_t frame_duration_ticks = 10'000'000;
};

CaptureVideoTiming VideoTimingForInterval(uint32_t interval_seconds);

struct MediaSampleTiming {
  int64_t timestamp_ticks = 0;
  int64_t duration_ticks = 1;
  int64_t end_ticks = 1;
};

MediaSampleTiming CalculateMediaSampleTiming(int64_t sample_offset_ticks,
                                             int64_t end_offset_ticks);

int64_t MediaFoundationTicksToDurationMs(int64_t duration_ticks);

int64_t CalculateEncodedDurationMs(uint32_t frame_count,
                                   uint32_t interval_seconds);

struct CaptureScheduleDecision {
  bool capture_frame = false;
  bool sample_metadata = false;
};

class CaptureSchedule {
 public:
  explicit CaptureSchedule(
      uint32_t capture_interval_seconds = kDefaultCaptureIntervalSeconds);

  void Configure(uint32_t capture_interval_seconds);
  void Reset(int64_t now_ms);
  CaptureScheduleDecision Poll(int64_t now_ms);
  void OnFrameCaptured(int64_t now_ms);
  int64_t DelayUntilNextMs(int64_t now_ms) const;

 private:
  int64_t frame_interval_ms_ = 1000;
  int64_t next_frame_ms_ = 0;
  int64_t next_metadata_ms_ = 0;
  bool frame_schedule_exhausted_ = false;
  bool metadata_schedule_exhausted_ = false;
};

class CaptureChunkProgress {
 public:
  explicit CaptureChunkProgress(int64_t regular_chunk_duration_ms);

  void Configure(int64_t regular_chunk_duration_ms);
  void Reset();
  uint32_t frame_count() const;
  int64_t latest_frame_offset_ms() const;
  bool ShouldFinalizeBeforeSample(int64_t elapsed_ms) const;

  CaptureLoopDecision OnTopologyChanged() const;
  CaptureLoopDecision OnTopologyCheckUnavailable() const;
  CaptureLoopDecision OnRecoverableCaptureError() const;
  CaptureLoopDecision OnFrameWritten(int64_t offset_ms);

 private:
  int64_t regular_chunk_duration_ms_ = 60'000;
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
