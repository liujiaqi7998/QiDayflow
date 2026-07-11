#include "native_frame_logger.h"

#include <algorithm>
#include <sstream>
#include <system_error>

namespace qi_day_flow {
namespace {

constexpr wchar_t kNativeLogFileName[] = L"native-capture.log";

std::string JsonEscapeLimited(const std::string& value) {
  constexpr size_t kMaximumIdentifierBytes = 96;
  const size_t length = std::min(value.size(), kMaximumIdentifierBytes);
  std::string result;
  result.reserve(length + 8);
  for (size_t index = 0; index < length; ++index) {
    const unsigned char character =
        static_cast<unsigned char>(value[index]);
    switch (character) {
      case '"':
        result += "\\\"";
        break;
      case '\\':
        result += "\\\\";
        break;
      case '\b':
        result += "\\b";
        break;
      case '\f':
        result += "\\f";
        break;
      case '\n':
        result += "\\n";
        break;
      case '\r':
        result += "\\r";
        break;
      case '\t':
        result += "\\t";
        break;
      default:
        if (character >= 0x20) {
          result.push_back(static_cast<char>(character));
        }
        break;
    }
  }
  return result;
}

std::string SerializeFrame(const NativeFrameLogEntry& entry) {
  std::ostringstream output;
  output << "{\"level\":\"DEBUG\",\"event\":\"capture.frame\""
         << ",\"chunkId\":\"" << JsonEscapeLimited(entry.chunk_id) << '"'
         << ",\"frameIndex\":" << entry.frame_index
         << ",\"timestampMs\":" << entry.timestamp_ms
         << ",\"offsetMs\":" << entry.offset_ms << ",\"displayId\":\""
         << JsonEscapeLimited(entry.display_id) << '"'
         << ",\"writeSucceeded\":"
         << (entry.write_succeeded ? "true" : "false")
         << ",\"hresult\":" << entry.hresult << "}\n";
  return output.str();
}

}  // namespace

NativeFrameLogger::NativeFrameLogger() : level_(NativeLogLevel::kInfo) {}

NativeFrameLogger::~NativeFrameLogger() {
  Close();
}

bool NativeFrameLogger::Configure(
    const NativeFrameLoggerConfig& config) noexcept {
  if (config.log_directory.empty() || !config.log_directory.is_absolute() ||
      config.max_bytes < 256 || config.max_backups > 10) {
    return false;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  CloseLocked();
  config_ = config;
  current_path_ = config_.log_directory / kNativeLogFileName;
  configured_ = true;
  level_.store(config_.level, std::memory_order_release);
  return true;
}

void NativeFrameLogger::LogFrame(const NativeFrameLogEntry& entry) noexcept {
  if (level_.load(std::memory_order_acquire) != NativeLogLevel::kDebug) {
    return;
  }
  const std::string record = SerializeFrame(entry);
  std::lock_guard<std::mutex> lock(mutex_);
  if (!configured_ || config_.level != NativeLogLevel::kDebug ||
      record.size() > config_.max_bytes || !EnsureOpenLocked()) {
    return;
  }
  if (current_size_ > 0 &&
      current_size_ + record.size() > config_.max_bytes &&
      !RotateLocked()) {
    return;
  }
  stream_.write(record.data(), static_cast<std::streamsize>(record.size()));
  if (!stream_) {
    CloseLocked();
    return;
  }
  current_size_ += static_cast<uint64_t>(record.size());
}

void NativeFrameLogger::Close() noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  CloseLocked();
  configured_ = false;
  level_.store(NativeLogLevel::kInfo, std::memory_order_release);
}

bool NativeFrameLogger::EnsureOpenLocked() noexcept {
  if (stream_.is_open()) {
    return true;
  }
  std::error_code error;
  std::filesystem::create_directories(config_.log_directory, error);
  if (error) {
    return false;
  }
  current_size_ = std::filesystem::exists(current_path_, error)
                      ? std::filesystem::file_size(current_path_, error)
                      : 0;
  if (error) {
    current_size_ = 0;
    return false;
  }
  stream_.open(current_path_, std::ios::binary | std::ios::app);
  return stream_.is_open();
}

bool NativeFrameLogger::RotateLocked() noexcept {
  CloseLocked();
  std::error_code error;
  if (config_.max_backups == 0) {
    std::filesystem::remove(current_path_, error);
    if (error) {
      return false;
    }
    return EnsureOpenLocked();
  }
  for (uint32_t index = config_.max_backups; index >= 2; --index) {
    const std::filesystem::path source =
        current_path_.wstring() + L"." + std::to_wstring(index - 1);
    const std::filesystem::path target =
        current_path_.wstring() + L"." + std::to_wstring(index);
    error.clear();
    if (!std::filesystem::exists(source, error) || error) {
      if (error) {
        return false;
      }
      continue;
    }
    std::filesystem::remove(target, error);
    if (error) {
      return false;
    }
    std::filesystem::rename(source, target, error);
    if (error) {
      return false;
    }
  }
  const std::filesystem::path first_backup =
      current_path_.wstring() + L".1";
  std::filesystem::remove(first_backup, error);
  if (error) {
    return false;
  }
  std::filesystem::rename(current_path_, first_backup, error);
  if (error) {
    return false;
  }
  return EnsureOpenLocked();
}

void NativeFrameLogger::CloseLocked() noexcept {
  if (stream_.is_open()) {
    stream_.flush();
    stream_.close();
  }
  stream_.clear();
  current_size_ = 0;
}

}  // namespace qi_day_flow
