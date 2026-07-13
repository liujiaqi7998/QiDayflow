#ifndef RUNNER_CAPTURE_SERVICE_H_
#define RUNNER_CAPTURE_SERVICE_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace qi_day_flow {

class NativeFrameLogger;

struct DisplayInfo {
  int32_t index = 0;
  std::string id;
  std::string name;
  std::string adapter_name;
  int32_t left = 0;
  int32_t top = 0;
  int32_t width = 0;
  int32_t height = 0;
  int32_t rotation = 0;
  bool is_primary = false;
};

struct CaptureConfig {
  std::wstring output_root;
  std::string session_id;
  uint32_t capture_interval_seconds = 10;
  int32_t chunk_duration_seconds = 60;
  uint32_t max_width = 1920;
  uint32_t max_height = 1080;
  bool idle_pause_enabled = true;
  uint32_t idle_timeout_seconds = 600;
};

struct WindowRecord {
  int64_t timestamp_ms = 0;
  int64_t offset_ms = 0;
  uint32_t process_id = 0;
  std::string window_title;
  std::string process_name;
  std::string process_path;
  std::string app_name;
  std::optional<double> cpu_usage_percent;
  std::optional<uint64_t> memory_commit_bytes;
};

struct SourceChangeRecord {
  int64_t timestamp_ms = 0;
  int64_t offset_ms = 0;
  std::string display_id;
  int32_t left = 0;
  int32_t top = 0;
  int32_t width = 0;
  int32_t height = 0;
};

struct ChunkResult {
  std::string session_id;
  std::string chunk_id;
  std::string directory_path;
  std::string video_path;
  std::string metadata_path;
  int64_t start_time_ms = 0;
  int64_t end_time_ms = 0;
  int64_t duration_ms = 0;
  uint32_t video_frame_count = 0;
  uint32_t video_width = 0;
  uint32_t video_height = 0;
  uint32_t capture_interval_seconds = 10;
  uint32_t video_frame_rate_numerator = 1;
  uint32_t video_frame_rate_denominator = 1;
  int64_t video_frame_duration_ticks = 10'000'000;
  int32_t virtual_left = 0;
  int32_t virtual_top = 0;
  int32_t virtual_width = 0;
  int32_t virtual_height = 0;
  std::vector<DisplayInfo> displays;
  std::vector<SourceChangeRecord> source_changes;
  std::vector<WindowRecord> window_records;
};

struct ExtractedVideoFrame {
  int64_t offset_ms = 0;
  std::vector<uint8_t> jpeg_bytes;
};

struct VideoFrameExtractionConfig {
  std::wstring video_path;
  std::wstring capture_root;
  uint32_t expected_frame_count = 0;
  uint32_t max_frames = 8;
  uint32_t max_width = 1920;
  uint32_t max_height = 1080;
  uint32_t jpeg_quality = 85;
  uint32_t max_frame_bytes = 2 * 1024 * 1024;
  uint32_t max_total_bytes = 12 * 1024 * 1024;
};

enum class CaptureState {
  kStopped,
  kStarting,
  kRecording,
  kManualPaused,
  kIdlePaused,
  kStopping,
  kError,
};

struct CaptureEvent {
  enum class Type { kState, kChunkFinalized, kError };

  Type type = Type::kState;
  CaptureState state = CaptureState::kStopped;
  int64_t timestamp_ms = 0;
  std::string session_id;
  std::string reason;
  std::string error_code;
  std::string error_message;
  std::string hresult;
  bool recoverable = false;
  ChunkResult chunk;
};

using CaptureEventCallback = std::function<void(CaptureEvent)>;

class CaptureService {
 public:
  explicit CaptureService(CaptureEventCallback callback,
                          NativeFrameLogger* frame_logger = nullptr);
  ~CaptureService();

  CaptureService(const CaptureService&) = delete;
  CaptureService& operator=(const CaptureService&) = delete;

  static uint64_t GetIdleMilliseconds();
  static bool ExtractVideoFrames(const VideoFrameExtractionConfig& config,
                                 std::vector<ExtractedVideoFrame>* frames,
                                 std::string* error);

  bool Start(const CaptureConfig& config, std::string* error);
  bool Pause(std::string* error);
  bool Resume(std::string* error);
  bool Stop(std::string* error);
  void Shutdown();

  CaptureState state() const;
  std::string session_id() const;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace qi_day_flow

#endif  // RUNNER_CAPTURE_SERVICE_H_
