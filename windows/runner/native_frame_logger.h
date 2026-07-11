#ifndef RUNNER_NATIVE_FRAME_LOGGER_H_
#define RUNNER_NATIVE_FRAME_LOGGER_H_

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>

namespace qi_day_flow {

enum class NativeLogLevel { kDebug = 0, kInfo = 1, kWarning = 2, kError = 3 };

struct NativeFrameLoggerConfig {
  std::filesystem::path log_directory;
  NativeLogLevel level = NativeLogLevel::kInfo;
  uint64_t max_bytes = 1024 * 1024;
  uint32_t max_backups = 3;
};

struct NativeFrameLogEntry {
  std::string chunk_id;
  uint64_t frame_index = 0;
  int64_t timestamp_ms = 0;
  int64_t offset_ms = 0;
  std::string display_id;
  bool write_succeeded = false;
  int64_t hresult = 0;
};

class NativeFrameLogger {
 public:
  NativeFrameLogger();
  ~NativeFrameLogger();

  NativeFrameLogger(const NativeFrameLogger&) = delete;
  NativeFrameLogger& operator=(const NativeFrameLogger&) = delete;

  bool Configure(const NativeFrameLoggerConfig& config) noexcept;
  void LogFrame(const NativeFrameLogEntry& entry) noexcept;
  void Close() noexcept;

 private:
  bool EnsureOpenLocked() noexcept;
  bool RotateLocked() noexcept;
  void CloseLocked() noexcept;

  std::atomic<NativeLogLevel> level_;
  std::mutex mutex_;
  NativeFrameLoggerConfig config_;
  std::filesystem::path current_path_;
  std::ofstream stream_;
  uint64_t current_size_ = 0;
  bool configured_ = false;
};

}  // namespace qi_day_flow

#endif  // RUNNER_NATIVE_FRAME_LOGGER_H_
