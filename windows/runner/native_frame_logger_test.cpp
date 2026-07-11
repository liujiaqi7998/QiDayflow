#include "native_frame_logger.h"

#include <windows.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <thread>
#include <vector>

namespace {

bool Expect(bool condition, const char* message) {
  if (condition) {
    return true;
  }
  std::cerr << message << '\n';
  return false;
}

std::string ReadAll(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

qi_day_flow::NativeFrameLogEntry Entry(uint64_t index) {
  return qi_day_flow::NativeFrameLogEntry{
      "chunk_session_1000_1", index, 1'000 + static_cast<int64_t>(index),
      static_cast<int64_t>(index), "display-1", true, 0};
}

bool TestInfoFiltering(const std::filesystem::path& root) {
  qi_day_flow::NativeFrameLogger logger;
  const std::filesystem::path directory = root / L"info";
  if (!Expect(logger.Configure({directory, qi_day_flow::NativeLogLevel::kInfo,
                                1024, 2}),
              "INFO logger configuration failed")) {
    return false;
  }
  logger.LogFrame(Entry(0));
  logger.Close();
  return Expect(!std::filesystem::exists(directory / L"native-capture.log"),
                "INFO emitted a per-frame log");
}

bool TestDebugWhitelistAndClose(const std::filesystem::path& root) {
  qi_day_flow::NativeFrameLogger logger;
  const std::filesystem::path directory = root / L"debug";
  if (!Expect(logger.Configure({directory, qi_day_flow::NativeLogLevel::kDebug,
                                4096, 2}),
              "DEBUG logger configuration failed")) {
    return false;
  }
  logger.LogFrame(Entry(7));
  logger.Close();
  const std::string content = ReadAll(directory / L"native-capture.log");
  const bool safe =
      content.find("\"chunkId\":\"chunk_session_1000_1\"") !=
          std::string::npos &&
      content.find("\"frameIndex\":7") != std::string::npos &&
      content.find("\"displayId\":\"display-1\"") != std::string::npos &&
      content.find("windowTitle") == std::string::npos &&
      content.find("Authorization") == std::string::npos &&
      content.find("apiKey") == std::string::npos &&
      content.find("jpeg") == std::string::npos &&
      content.find("base64") == std::string::npos;
  const std::filesystem::path renamed = root / L"debug-closed";
  std::error_code error;
  std::filesystem::rename(directory, renamed, error);
  return Expect(safe, "DEBUG frame record was not a safe whitelist") &&
         Expect(!error, "Close did not release the native log file");
}

bool TestRotation(const std::filesystem::path& root) {
  qi_day_flow::NativeFrameLogger logger;
  const std::filesystem::path directory = root / L"rotation";
  constexpr uint64_t max_bytes = 320;
  if (!Expect(logger.Configure({directory, qi_day_flow::NativeLogLevel::kDebug,
                                max_bytes, 2}),
              "rotation logger configuration failed")) {
    return false;
  }
  for (uint64_t index = 0; index < 30; ++index) {
    logger.LogFrame(Entry(index));
  }
  logger.Close();
  for (const wchar_t* name : {L"native-capture.log", L"native-capture.log.1",
                              L"native-capture.log.2"}) {
    const std::filesystem::path file = directory / name;
    if (!Expect(std::filesystem::exists(file), "rotation file missing") ||
        !Expect(std::filesystem::file_size(file) <= max_bytes,
                "rotation file exceeded its size cap")) {
      return false;
    }
  }
  return true;
}

bool TestThreadSafety(const std::filesystem::path& root) {
  qi_day_flow::NativeFrameLogger logger;
  const std::filesystem::path directory = root / L"threads";
  if (!Expect(logger.Configure({directory, qi_day_flow::NativeLogLevel::kDebug,
                                1024 * 1024, 2}),
              "thread logger configuration failed")) {
    return false;
  }
  std::vector<std::thread> workers;
  for (uint64_t worker = 0; worker < 4; ++worker) {
    workers.emplace_back([worker, &logger]() {
      for (uint64_t index = 0; index < 25; ++index) {
        logger.LogFrame(Entry(worker * 100 + index));
      }
    });
  }
  for (auto& worker : workers) {
    worker.join();
  }
  logger.Close();
  const std::string content = ReadAll(directory / L"native-capture.log");
  return Expect(std::count(content.begin(), content.end(), '\n') == 100,
                "concurrent frame records were lost or interleaved");
}

}  // namespace

int main() {
  const std::filesystem::path root =
      std::filesystem::temp_directory_path() /
      (L"qi_day_flow_native_logger_test_" +
       std::to_wstring(GetCurrentProcessId()));
  std::error_code error;
  std::filesystem::remove_all(root, error);
  std::filesystem::create_directories(root, error);
  if (!Expect(!error, "could not create native logger test directory") ||
      !TestInfoFiltering(root) || !TestDebugWhitelistAndClose(root) ||
      !TestRotation(root) || !TestThreadSafety(root)) {
    std::filesystem::remove_all(root, error);
    return 1;
  }
  std::filesystem::remove_all(root, error);
  std::cout << "native frame logging passed\n";
  return 0;
}
