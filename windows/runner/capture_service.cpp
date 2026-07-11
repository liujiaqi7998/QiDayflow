#include "capture_service.h"

#include "capture_pixel_buffer.h"
#include "capture_runtime.h"
#include "native_frame_logger.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <objidl.h>
#include <propvarutil.h>
#include <psapi.h>
#include <windows.h>
#include <wincodec.h>
#include <winver.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <cwctype>
#include <filesystem>
#include <limits>
#include <mutex>
#include <numeric>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace qi_day_flow {
namespace {

using Microsoft::WRL::ComPtr;
using SteadyClock = std::chrono::steady_clock;

constexpr DWORD kAcquireTimeoutMs = 100;
constexpr uint64_t kMaximumSourceFrameBytes = 512ULL * 1024ULL * 1024ULL;
constexpr uint64_t kMaximumVideoFileBytes = 512ULL * 1024ULL * 1024ULL;
constexpr uint32_t kCaptureVideoWidth = 1920;
constexpr uint32_t kCaptureVideoHeight = 1080;
constexpr double kCaptureFramesPerSecond = 1.0;
constexpr int32_t kCaptureChunkDurationSeconds = 60;
constexpr uint32_t kMinimumVideoBitrate = 2500000;
constexpr uint32_t kMaximumVideoBitrate = 4000000;
constexpr uint32_t kHardMaximumExtractedFrames = 8;
constexpr uint32_t kHardMaximumExtractWidth = 1920;
constexpr uint32_t kHardMaximumExtractHeight = 1080;
constexpr uint32_t kHardMaximumFrameBytes = 2 * 1024 * 1024;
constexpr uint32_t kHardMaximumTotalBytes = 12 * 1024 * 1024;
constexpr LONGLONG kMediaFoundationTicksPerSecond = 10000000LL;
constexpr DWORD kSourceReaderAllStreams =
    static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);
constexpr DWORD kSourceReaderFirstVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD kSourceReaderMediaSource =
    static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE);

uint32_t CalculateRegularChunkFrameCount(double fps,
                                         int32_t duration_seconds) {
  return std::max<uint32_t>(
      1, static_cast<uint32_t>(std::llround(fps * duration_seconds)));
}

int64_t UnixTimeMillis() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

std::string Utf8FromWide(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }
  const int required = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (required <= 0) {
    return {};
  }
  std::string result(static_cast<size_t>(required), '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          required, nullptr, nullptr) != required) {
    return {};
  }
  return result;
}

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int required = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (required <= 0) {
    return {};
  }
  std::wstring result(static_cast<size_t>(required), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          required) != required) {
    return {};
  }
  return result;
}

std::wstring Lowercase(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t character) {
                   return static_cast<wchar_t>(std::towlower(character));
                 });
  return value;
}

std::wstring FileNameFromPath(const std::wstring& path) {
  const size_t separator = path.find_last_of(L"\\/");
  return separator == std::wstring::npos ? path : path.substr(separator + 1);
}

std::wstring StemFromFileName(std::wstring name) {
  const std::wstring lower = Lowercase(name);
  if (lower.size() > 4 && lower.compare(lower.size() - 4, 4, L".exe") == 0) {
    name.resize(name.size() - 4);
  }
  return name;
}

std::string HResultString(HRESULT result) {
  char buffer[16] = {};
  static_cast<void>(sprintf_s(buffer, "0x%08lX",
                              static_cast<unsigned long>(result)));
  return buffer;
}

std::string JsonEscape(const std::string& input) {
  std::string output;
  output.reserve(input.size() + 8);
  constexpr char kHex[] = "0123456789abcdef";
  for (const unsigned char character : input) {
    switch (character) {
      case '"':
        output += "\\\"";
        break;
      case '\\':
        output += "\\\\";
        break;
      case '\b':
        output += "\\b";
        break;
      case '\f':
        output += "\\f";
        break;
      case '\n':
        output += "\\n";
        break;
      case '\r':
        output += "\\r";
        break;
      case '\t':
        output += "\\t";
        break;
      default:
        if (character < 0x20) {
          output += "\\u00";
          output.push_back(kHex[(character >> 4) & 0x0F]);
          output.push_back(kHex[character & 0x0F]);
        } else {
          output.push_back(static_cast<char>(character));
        }
        break;
    }
  }
  return output;
}

bool WriteUtf8FileAtomically(const std::filesystem::path& final_path,
                             const std::string& contents,
                             std::string* error) {
  std::filesystem::path temporary_path = final_path;
  temporary_path += L".tmp";
  HANDLE file = CreateFileW(temporary_path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    if (error != nullptr) {
      *error = "Unable to create metadata file";
    }
    return false;
  }

  bool success = true;
  size_t offset = 0;
  while (offset < contents.size()) {
    const DWORD requested = static_cast<DWORD>(std::min<size_t>(
        contents.size() - offset,
        static_cast<size_t>(std::numeric_limits<DWORD>::max())));
    DWORD written = 0;
    if (!WriteFile(file, contents.data() + offset, requested, &written,
                   nullptr) || written == 0) {
      success = false;
      break;
    }
    offset += written;
  }
  if (success) {
    success = FlushFileBuffers(file) != FALSE;
  }
  CloseHandle(file);
  if (!success ||
      !MoveFileExW(temporary_path.c_str(), final_path.c_str(),
                   MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(temporary_path.c_str());
    if (error != nullptr) {
      *error = "Unable to commit metadata file";
    }
    return false;
  }
  return true;
}

std::string SanitizePathComponent(const std::string& value) {
  std::string result;
  result.reserve(value.size());
  for (const unsigned char character : value) {
    const bool allowed =
        (character >= 'a' && character <= 'z') ||
        (character >= 'A' && character <= 'Z') ||
        (character >= '0' && character <= '9') || character == '-' ||
        character == '_';
    result.push_back(allowed ? static_cast<char>(character) : '_');
  }
  if (result.empty()) {
    result = "session";
  }
  if (result.size() > 80) {
    result.resize(80);
  }
  return result;
}

struct WindowSnapshot {
  uint32_t process_id = 0;
  std::string window_title;
  std::string process_name;
  std::string process_path;
  std::string app_name;
  std::optional<uint64_t> creation_time_100ns;
  std::optional<uint64_t> process_time_100ns;
  std::optional<uint64_t> memory_commit_bytes;
};

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle = nullptr) : handle_(handle) {}
  ~ScopedHandle() { Reset(); }

  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;

  HANDLE get() const { return handle_; }

  void Reset(HANDLE handle = nullptr) {
    if (handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE) {
      CloseHandle(handle_);
    }
    handle_ = handle;
  }

 private:
  HANDLE handle_ = nullptr;
};

uint64_t FileTimeTicks(const FILETIME& value) {
  ULARGE_INTEGER ticks = {};
  ticks.LowPart = value.dwLowDateTime;
  ticks.HighPart = value.dwHighDateTime;
  return ticks.QuadPart;
}

class WindowTracker {
 public:
  WindowSnapshot GetForegroundWindowSnapshot() {
    WindowSnapshot snapshot;
    const HWND window = GetForegroundWindow();
    if (window == nullptr) {
      snapshot.app_name = "Unknown";
      return snapshot;
    }
    const int title_length = std::clamp(GetWindowTextLengthW(window), 0, 4096);
    std::vector<wchar_t> title(static_cast<size_t>(title_length) + 1, L'\0');
    const int copied =
        GetWindowTextW(window, title.data(), static_cast<int>(title.size()));
    if (copied > 0) {
      snapshot.window_title = Utf8FromWide(
          std::wstring(title.data(), static_cast<size_t>(copied)));
    }

    DWORD process_id = 0;
    static_cast<void>(GetWindowThreadProcessId(window, &process_id));
    snapshot.process_id = process_id;
    ScopedHandle process(OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
                                     FALSE, process_id));
    if (process.get() == nullptr) {
      process.Reset(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                process_id));
    }
    if (process.get() != nullptr) {
      std::vector<wchar_t> path(32768, L'\0');
      DWORD path_length = static_cast<DWORD>(path.size());
      if (QueryFullProcessImageNameW(process.get(), 0, path.data(),
                                     &path_length)) {
        const std::wstring process_path(path.data(), path_length);
        const std::wstring process_name = FileNameFromPath(process_path);
        snapshot.process_path = Utf8FromWide(process_path);
        snapshot.process_name = Utf8FromWide(process_name);
        snapshot.app_name = FriendlyName(process_path, process_name);
      }

      FILETIME creation_time = {};
      FILETIME exit_time = {};
      FILETIME kernel_time = {};
      FILETIME user_time = {};
      if (GetProcessTimes(process.get(), &creation_time, &exit_time,
                          &kernel_time, &user_time)) {
        const uint64_t kernel_ticks = FileTimeTicks(kernel_time);
        const uint64_t user_ticks = FileTimeTicks(user_time);
        if (kernel_ticks <=
            std::numeric_limits<uint64_t>::max() - user_ticks) {
          snapshot.creation_time_100ns = FileTimeTicks(creation_time);
          snapshot.process_time_100ns = kernel_ticks + user_ticks;
        }
      }

      PROCESS_MEMORY_COUNTERS_EX memory_counters = {};
      memory_counters.cb = sizeof(memory_counters);
      const bool memory_query_succeeded =
          GetProcessMemoryInfo(
              process.get(),
              reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&memory_counters),
              sizeof(memory_counters)) != FALSE;
      snapshot.memory_commit_bytes = PrivateUsageToMemoryCommitBytes(
          memory_query_succeeded,
          static_cast<uint64_t>(memory_counters.PrivateUsage));
    }
    if (snapshot.process_name.empty()) {
      snapshot.process_name = "Unknown";
    }
    if (snapshot.app_name.empty()) {
      snapshot.app_name = snapshot.process_name;
    }
    return snapshot;
  }

 private:
  std::string FriendlyName(const std::wstring& process_path,
                           const std::wstring& process_name) {
    const auto cached = friendly_name_cache_.find(process_path);
    if (cached != friendly_name_cache_.end()) {
      return cached->second;
    }
    const std::wstring stem = Lowercase(StemFromFileName(process_name));
    static const std::unordered_map<std::wstring, std::string> kKnownNames = {
        {L"code", "Visual Studio Code"},
        {L"cursor", "Cursor"},
        {L"chrome", "Google Chrome"},
        {L"msedge", "Microsoft Edge"},
        {L"firefox", "Mozilla Firefox"},
        {L"winword", "Microsoft Word"},
        {L"excel", "Microsoft Excel"},
        {L"powerpnt", "Microsoft PowerPoint"},
        {L"outlook", "Microsoft Outlook"},
        {L"explorer", "File Explorer"},
        {L"windowsterminal", "Windows Terminal"},
        {L"powershell", "PowerShell"},
        {L"cmd", "Command Prompt"},
        {L"notepad", "Notepad"},
        {L"wechat", "WeChat"},
        {L"weixin", "WeChat"},
        {L"dingtalk", "DingTalk"},
        {L"feishu", "Feishu"},
        {L"lark", "Lark"},
    };
    const auto known = kKnownNames.find(stem);
    if (known != kKnownNames.end()) {
      friendly_name_cache_[process_path] = known->second;
      return known->second;
    }

    std::string result = ReadFileDescription(process_path);
    if (result.empty()) {
      result = Utf8FromWide(StemFromFileName(process_name));
    }
    friendly_name_cache_[process_path] = result;
    return result;
  }

  static std::string ReadFileDescription(const std::wstring& path) {
    DWORD ignored = 0;
    const DWORD version_size = GetFileVersionInfoSizeW(path.c_str(), &ignored);
    if (version_size == 0) {
      return {};
    }
    std::vector<uint8_t> version_data(version_size);
    if (!GetFileVersionInfoW(path.c_str(), 0, version_size,
                             version_data.data())) {
      return {};
    }
    struct Translation {
      WORD language;
      WORD code_page;
    };
    LPVOID translation_value = nullptr;
    UINT translation_bytes = 0;
    WORD language = 0x0409;
    WORD code_page = 0x04B0;
    if (VerQueryValueW(version_data.data(), L"\\VarFileInfo\\Translation",
                       &translation_value, &translation_bytes) &&
        translation_value != nullptr &&
        translation_bytes >= sizeof(Translation)) {
      const auto* translation =
          static_cast<const Translation*>(translation_value);
      language = translation->language;
      code_page = translation->code_page;
    }
    wchar_t query[96] = {};
    static_cast<void>(_snwprintf_s(
        query, _countof(query), _TRUNCATE,
        L"\\StringFileInfo\\%04x%04x\\FileDescription", language,
        code_page));
    LPVOID description_value = nullptr;
    UINT description_length = 0;
    if (!VerQueryValueW(version_data.data(), query, &description_value,
                        &description_length) ||
        description_value == nullptr || description_length <= 1) {
      return {};
    }
    return Utf8FromWide(std::wstring(
        static_cast<const wchar_t*>(description_value),
        static_cast<size_t>(description_length - 1)));
  }

  std::unordered_map<std::wstring, std::string> friendly_name_cache_;
};

uint64_t GetIdleMillisecondsInternal() {
  LASTINPUTINFO info = {};
  info.cbSize = sizeof(info);
  if (!GetLastInputInfo(&info)) {
    return 0;
  }
  const uint64_t now = GetTickCount64();
  uint64_t last_input =
      (now & 0xFFFFFFFF00000000ULL) | static_cast<uint64_t>(info.dwTime);
  if (last_input > now) {
    last_input -= (1ULL << 32);
  }
  return now - last_input;
}

uint32_t LogicalProcessorCount() {
  const DWORD count = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  return count == 0 ? 1U : static_cast<uint32_t>(count);
}

uint64_t SteadyTimeTicks100ns(SteadyClock::time_point now) {
  using HundredNanoseconds =
      std::chrono::duration<uint64_t, std::ratio<1, 10000000>>;
  return std::chrono::duration_cast<HundredNanoseconds>(now.time_since_epoch())
      .count();
}

struct NativeOutput {
  DisplayInfo info;
  ComPtr<IDXGIAdapter1> adapter;
  ComPtr<IDXGIOutput> output;
  DXGI_OUTPUT_DESC description = {};
  LUID adapter_luid = {};
  HMONITOR monitor = nullptr;
};

HMONITOR ResolveCaptureMonitor() {
  const HWND foreground = GetForegroundWindow();
  if (foreground != nullptr && IsWindow(foreground)) {
    const HMONITOR monitor =
        MonitorFromWindow(foreground, MONITOR_DEFAULTTONEAREST);
    if (monitor != nullptr) {
      return monitor;
    }
  }

  POINT cursor = {};
  if (GetCursorPos(&cursor)) {
    const HMONITOR monitor =
        MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
    if (monitor != nullptr) {
      return monitor;
    }
  }
  return MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
}

std::string MonitorFriendlyName(const wchar_t* device_name) {
  DISPLAY_DEVICEW display_device = {};
  display_device.cb = sizeof(display_device);
  if (EnumDisplayDevicesW(device_name, 0, &display_device, 0) &&
      display_device.DeviceString[0] != L'\0') {
    return Utf8FromWide(display_device.DeviceString);
  }
  return Utf8FromWide(device_name);
}

HRESULT EnumerateNativeOutputs(std::vector<NativeOutput>* outputs) {
  if (outputs == nullptr) {
    return E_POINTER;
  }
  outputs->clear();
  ComPtr<IDXGIFactory1> factory;
  HRESULT result = CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf()));
  if (FAILED(result)) {
    return result;
  }

  int32_t global_index = 0;
  for (UINT adapter_index = 0;; ++adapter_index) {
    ComPtr<IDXGIAdapter1> adapter;
    result = factory->EnumAdapters1(adapter_index, adapter.GetAddressOf());
    if (result == DXGI_ERROR_NOT_FOUND) {
      break;
    }
    if (FAILED(result)) {
      return result;
    }
    DXGI_ADAPTER_DESC1 adapter_description = {};
    if (FAILED(adapter->GetDesc1(&adapter_description))) {
      continue;
    }
    for (UINT output_index = 0;; ++output_index) {
      ComPtr<IDXGIOutput> output;
      result = adapter->EnumOutputs(output_index, output.GetAddressOf());
      if (result == DXGI_ERROR_NOT_FOUND) {
        break;
      }
      if (FAILED(result)) {
        return result;
      }
      DXGI_OUTPUT_DESC description = {};
      if (FAILED(output->GetDesc(&description)) ||
          !description.AttachedToDesktop) {
        continue;
      }
      const RECT& rectangle = description.DesktopCoordinates;
      const LONG width = rectangle.right - rectangle.left;
      const LONG height = rectangle.bottom - rectangle.top;
      if (width <= 0 || height <= 0) {
        continue;
      }

      MONITORINFO monitor_info = {};
      monitor_info.cbSize = sizeof(monitor_info);
      const HMONITOR monitor = description.Monitor != nullptr
                                   ? description.Monitor
                                   : MonitorFromRect(&rectangle,
                                                     MONITOR_DEFAULTTONULL);
      const bool has_monitor_info =
          monitor != nullptr && GetMonitorInfoW(monitor, &monitor_info);

      NativeOutput native_output;
      native_output.info.index = global_index++;
      native_output.info.id = Utf8FromWide(description.DeviceName);
      native_output.info.name = MonitorFriendlyName(description.DeviceName);
      native_output.info.adapter_name =
          Utf8FromWide(adapter_description.Description);
      native_output.info.left = rectangle.left;
      native_output.info.top = rectangle.top;
      native_output.info.width = width;
      native_output.info.height = height;
      native_output.info.rotation = static_cast<int32_t>(description.Rotation);
      native_output.info.is_primary =
          has_monitor_info &&
          (monitor_info.dwFlags & MONITORINFOF_PRIMARY) != 0;
      native_output.adapter = adapter;
      native_output.output = output;
      native_output.description = description;
      native_output.adapter_luid = adapter_description.AdapterLuid;
      native_output.monitor = monitor;
      outputs->push_back(std::move(native_output));
    }
  }
  return outputs->empty() ? DXGI_ERROR_NOT_FOUND : S_OK;
}

size_t SelectNativeOutputIndex(const std::vector<NativeOutput>& outputs,
                               HMONITOR target_monitor) {
  for (size_t index = 0; index < outputs.size(); ++index) {
    if (outputs[index].monitor == target_monitor) {
      return index;
    }
  }
  for (size_t index = 0; index < outputs.size(); ++index) {
    if (outputs[index].info.is_primary) {
      return index;
    }
  }
  return 0;
}

bool SameLuid(const LUID& left, const LUID& right) {
  return left.HighPart == right.HighPart && left.LowPart == right.LowPart;
}

bool SameOutput(const NativeOutput& left, const NativeOutput& right) {
  return SameLuid(left.adapter_luid, right.adapter_luid) &&
         _stricmp(left.info.id.c_str(), right.info.id.c_str()) == 0 &&
         left.info.left == right.info.left && left.info.top == right.info.top &&
         left.info.width == right.info.width &&
         left.info.height == right.info.height &&
         left.description.Rotation == right.description.Rotation;
}

void RotateBgra(const std::vector<uint8_t>& source,
                uint32_t source_width,
                uint32_t source_height,
                DXGI_MODE_ROTATION rotation,
                std::vector<uint8_t>* destination,
                uint32_t* destination_width,
                uint32_t* destination_height) {
  const bool quarter_turn = rotation == DXGI_MODE_ROTATION_ROTATE90 ||
                            rotation == DXGI_MODE_ROTATION_ROTATE270;
  *destination_width = quarter_turn ? source_height : source_width;
  *destination_height = quarter_turn ? source_width : source_height;
  destination->resize(static_cast<size_t>(*destination_width) *
                      *destination_height * 4U);
  for (uint32_t y = 0; y < source_height; ++y) {
    for (uint32_t x = 0; x < source_width; ++x) {
      uint32_t target_x = x;
      uint32_t target_y = y;
      switch (rotation) {
        case DXGI_MODE_ROTATION_ROTATE90:
          target_x = source_height - 1U - y;
          target_y = x;
          break;
        case DXGI_MODE_ROTATION_ROTATE180:
          target_x = source_width - 1U - x;
          target_y = source_height - 1U - y;
          break;
        case DXGI_MODE_ROTATION_ROTATE270:
          target_x = y;
          target_y = source_width - 1U - x;
          break;
        case DXGI_MODE_ROTATION_IDENTITY:
        case DXGI_MODE_ROTATION_UNSPECIFIED:
        default:
          break;
      }
      const size_t source_offset =
          (static_cast<size_t>(y) * source_width + x) * 4U;
      const size_t target_offset =
          (static_cast<size_t>(target_y) * *destination_width + target_x) * 4U;
      memcpy(destination->data() + target_offset,
             source.data() + source_offset, 4U);
    }
  }
}

void ResizeBgraNearest(const std::vector<uint8_t>& source,
                       uint32_t source_width,
                       uint32_t source_height,
                       uint32_t target_width,
                       uint32_t target_height,
                       std::vector<uint8_t>* destination) {
  destination->resize(static_cast<size_t>(target_width) * target_height * 4U);
  for (uint32_t y = 0; y < target_height; ++y) {
    const uint32_t source_y = std::min(
        source_height - 1U,
        static_cast<uint32_t>(static_cast<uint64_t>(y) * source_height /
                              target_height));
    for (uint32_t x = 0; x < target_width; ++x) {
      const uint32_t source_x = std::min(
          source_width - 1U,
          static_cast<uint32_t>(static_cast<uint64_t>(x) * source_width /
                                target_width));
      memcpy(destination->data() +
                 (static_cast<size_t>(y) * target_width + x) * 4U,
             source.data() +
                 (static_cast<size_t>(source_y) * source_width + source_x) *
                     4U,
             4U);
    }
  }
}

class OutputCapture {
 public:
  explicit OutputCapture(NativeOutput output) : output_(std::move(output)) {}
  OutputCapture(OutputCapture&&) noexcept = default;
  OutputCapture& operator=(OutputCapture&&) noexcept = default;
  OutputCapture(const OutputCapture&) = delete;
  OutputCapture& operator=(const OutputCapture&) = delete;

  const NativeOutput& output() const { return output_; }
  const std::vector<uint8_t>& pixels() const { return oriented_pixels_; }

  HRESULT Initialize() {
    constexpr UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    const std::array<D3D_FEATURE_LEVEL, 4> feature_levels = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    D3D_FEATURE_LEVEL selected_level = D3D_FEATURE_LEVEL_10_0;
    HRESULT result = D3D11CreateDevice(
        output_.adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, flags,
        feature_levels.data(), static_cast<UINT>(feature_levels.size()),
        D3D11_SDK_VERSION, device_.GetAddressOf(), &selected_level,
        context_.GetAddressOf());
    if (result == E_INVALIDARG) {
      result = D3D11CreateDevice(
          output_.adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, flags,
          feature_levels.data() + 1,
          static_cast<UINT>(feature_levels.size() - 1), D3D11_SDK_VERSION,
          device_.GetAddressOf(), &selected_level, context_.GetAddressOf());
    }
    if (FAILED(result)) {
      return result;
    }
    ComPtr<IDXGIOutput1> output1;
    result = output_.output.As(&output1);
    if (FAILED(result)) {
      return result;
    }
    return output1->DuplicateOutput(device_.Get(), duplication_.GetAddressOf());
  }

  HRESULT Acquire() {
    if (duplication_ == nullptr || device_ == nullptr || context_ == nullptr) {
      return E_UNEXPECTED;
    }
    DXGI_OUTDUPL_FRAME_INFO frame_info = {};
    ComPtr<IDXGIResource> desktop_resource;
    HRESULT result = duplication_->AcquireNextFrame(
        kAcquireTimeoutMs, &frame_info, desktop_resource.GetAddressOf());
    if (result == DXGI_ERROR_WAIT_TIMEOUT) {
      return oriented_pixels_.empty() ? S_FALSE : S_OK;
    }
    if (FAILED(result)) {
      return result;
    }

    ComPtr<ID3D11Texture2D> desktop_texture;
    result = desktop_resource.As(&desktop_texture);
    if (FAILED(result)) {
      static_cast<void>(duplication_->ReleaseFrame());
      return result;
    }
    D3D11_TEXTURE2D_DESC description = {};
    desktop_texture->GetDesc(&description);
    if (description.Format != DXGI_FORMAT_B8G8R8A8_UNORM &&
        description.Format != DXGI_FORMAT_B8G8R8A8_UNORM_SRGB) {
      static_cast<void>(duplication_->ReleaseFrame());
      return DXGI_ERROR_UNSUPPORTED;
    }
    if (staging_ == nullptr || staging_width_ != description.Width ||
        staging_height_ != description.Height) {
      staging_.Reset();
      D3D11_TEXTURE2D_DESC staging_description = description;
      staging_description.BindFlags = 0;
      staging_description.MiscFlags = 0;
      staging_description.Usage = D3D11_USAGE_STAGING;
      staging_description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      staging_description.ArraySize = 1;
      staging_description.MipLevels = 1;
      staging_description.SampleDesc.Count = 1;
      staging_description.SampleDesc.Quality = 0;
      result = device_->CreateTexture2D(&staging_description, nullptr,
                                        staging_.GetAddressOf());
      if (FAILED(result)) {
        static_cast<void>(duplication_->ReleaseFrame());
        return result;
      }
      staging_width_ = description.Width;
      staging_height_ = description.Height;
    }

    context_->CopyResource(staging_.Get(), desktop_texture.Get());
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    result = context_->Map(staging_.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(result)) {
      static_cast<void>(duplication_->ReleaseFrame());
      return result;
    }
    const size_t row_bytes = static_cast<size_t>(description.Width) * 4U;
    std::vector<uint8_t> raw(row_bytes * description.Height);
    for (UINT row = 0; row < description.Height; ++row) {
      memcpy(raw.data() + static_cast<size_t>(row) * row_bytes,
             static_cast<const uint8_t*>(mapped.pData) +
                 static_cast<size_t>(row) * mapped.RowPitch,
             row_bytes);
    }
    context_->Unmap(staging_.Get(), 0);
    result = duplication_->ReleaseFrame();
    if (FAILED(result)) {
      return result;
    }

    std::vector<uint8_t> oriented;
    uint32_t oriented_width = 0;
    uint32_t oriented_height = 0;
    RotateBgra(raw, description.Width, description.Height,
               output_.description.Rotation, &oriented, &oriented_width,
               &oriented_height);
    const uint32_t expected_width =
        static_cast<uint32_t>(output_.info.width);
    const uint32_t expected_height =
        static_cast<uint32_t>(output_.info.height);
    if (oriented_width != expected_width ||
        oriented_height != expected_height) {
      ResizeBgraNearest(oriented, oriented_width, oriented_height,
                        expected_width, expected_height, &oriented_pixels_);
    } else {
      oriented_pixels_ = std::move(oriented);
    }
    return S_OK;
  }

 private:
  NativeOutput output_;
  ComPtr<ID3D11Device> device_;
  ComPtr<ID3D11DeviceContext> context_;
  ComPtr<IDXGIOutputDuplication> duplication_;
  ComPtr<ID3D11Texture2D> staging_;
  uint32_t staging_width_ = 0;
  uint32_t staging_height_ = 0;
  std::vector<uint8_t> oriented_pixels_;
};

bool IsRecoverableCaptureError(HRESULT result) {
  return result == DXGI_ERROR_ACCESS_LOST ||
         result == DXGI_ERROR_DEVICE_REMOVED ||
         result == DXGI_ERROR_DEVICE_RESET ||
         result == DXGI_ERROR_SESSION_DISCONNECTED ||
         result == DXGI_ERROR_NOT_CURRENTLY_AVAILABLE;
}

struct ContentLayout {
  uint32_t left = 0;
  uint32_t top = 0;
  uint32_t width = 0;
  uint32_t height = 0;
};

uint32_t DivideRounded(uint64_t numerator, uint32_t denominator) {
  return static_cast<uint32_t>(
      (numerator + static_cast<uint64_t>(denominator) / 2ULL) /
      denominator);
}

ContentLayout CalculateContentLayout(uint32_t source_width,
                                     uint32_t source_height,
                                     uint32_t canvas_width,
                                     uint32_t canvas_height) {
  ContentLayout layout;
  if (static_cast<uint64_t>(source_width) * canvas_height >=
      static_cast<uint64_t>(source_height) * canvas_width) {
    layout.width = canvas_width;
    layout.height = std::clamp<uint32_t>(
        DivideRounded(static_cast<uint64_t>(source_height) * canvas_width,
                      source_width),
        1, canvas_height);
  } else {
    layout.height = canvas_height;
    layout.width = std::clamp<uint32_t>(
        DivideRounded(static_cast<uint64_t>(source_width) * canvas_height,
                      source_height),
        1, canvas_width);
  }
  layout.left = (canvas_width - layout.width) / 2U;
  layout.top = (canvas_height - layout.height) / 2U;
  return layout;
}

HRESULT LetterboxBgraWithWic(IWICImagingFactory* factory,
                             const std::vector<uint8_t>& source,
                             uint32_t source_width,
                             uint32_t source_height,
                             uint32_t canvas_width,
                             uint32_t canvas_height,
                             std::vector<uint8_t>* destination) {
  if (factory == nullptr || destination == nullptr || source.empty() ||
      source_width == 0 || source_height == 0 || canvas_width == 0 ||
      canvas_height == 0) {
    return E_INVALIDARG;
  }
  const uint64_t source_stride = static_cast<uint64_t>(source_width) * 4ULL;
  const uint64_t source_bytes = source_stride * source_height;
  const uint64_t canvas_stride = static_cast<uint64_t>(canvas_width) * 4ULL;
  const uint64_t canvas_bytes = canvas_stride * canvas_height;
  if (source_stride > std::numeric_limits<UINT>::max() ||
      source_bytes > std::numeric_limits<UINT>::max() ||
      source.size() != source_bytes ||
      canvas_stride > std::numeric_limits<UINT>::max() ||
      canvas_bytes > std::numeric_limits<UINT>::max()) {
    return E_INVALIDARG;
  }
  ComPtr<IWICBitmap> bitmap;
  HRESULT result = factory->CreateBitmapFromMemory(
      source_width, source_height, GUID_WICPixelFormat32bppBGRA,
      static_cast<UINT>(source_stride), static_cast<UINT>(source_bytes),
      const_cast<BYTE*>(source.data()), bitmap.GetAddressOf());
  if (FAILED(result)) {
    return result;
  }
  ComPtr<IWICBitmapSource> bitmap_source = bitmap;
  ComPtr<IWICBitmapScaler> scaler;
  const ContentLayout layout = CalculateContentLayout(
      source_width, source_height, canvas_width, canvas_height);
  if (source_width != layout.width || source_height != layout.height) {
    result = factory->CreateBitmapScaler(scaler.GetAddressOf());
    if (FAILED(result)) {
      return result;
    }
    result = scaler->Initialize(bitmap.Get(), layout.width, layout.height,
                                WICBitmapInterpolationModeFant);
    if (FAILED(result)) {
      return result;
    }
    bitmap_source = scaler;
  }
  const size_t scaled_stride = static_cast<size_t>(layout.width) * 4U;
  const size_t scaled_bytes = scaled_stride * layout.height;
  if (scaled_stride > std::numeric_limits<UINT>::max() ||
      scaled_bytes > std::numeric_limits<UINT>::max()) {
    return E_INVALIDARG;
  }
  std::vector<uint8_t> scaled(scaled_bytes);
  result = bitmap_source->CopyPixels(
      nullptr, static_cast<UINT>(scaled_stride),
      static_cast<UINT>(scaled_bytes), scaled.data());
  if (FAILED(result)) {
    return result;
  }
  for (size_t alpha = 3; alpha < scaled.size(); alpha += 4) {
    scaled[alpha] = 0xFF;
  }

  destination->assign(static_cast<size_t>(canvas_bytes), 0);
  for (size_t alpha = 3; alpha < destination->size(); alpha += 4) {
    (*destination)[alpha] = 0xFF;
  }
  for (uint32_t row = 0; row < layout.height; ++row) {
    memcpy(destination->data() +
               (static_cast<size_t>(layout.top + row) * canvas_width +
                layout.left) *
                   4U,
           scaled.data() + static_cast<size_t>(row) * scaled_stride,
           scaled_stride);
  }
  return S_OK;
}

bool IsPathWithin(const std::filesystem::path& root,
                  const std::filesystem::path& child) {
  auto root_iterator = root.begin();
  auto child_iterator = child.begin();
  for (; root_iterator != root.end(); ++root_iterator, ++child_iterator) {
    if (child_iterator == child.end() ||
        _wcsicmp(root_iterator->c_str(), child_iterator->c_str()) != 0) {
      return false;
    }
  }
  return child_iterator != child.end();
}

bool ValidateVideoPath(const VideoFrameExtractionConfig& config,
                       std::filesystem::path* canonical_video,
                       std::string* error) {
  if (canonical_video == nullptr || error == nullptr ||
      config.video_path.empty() || config.capture_root.empty()) {
    if (error != nullptr) {
      *error = "videoPath and captureRoot are required";
    }
    return false;
  }
  std::error_code filesystem_error;
  const std::filesystem::path root =
      std::filesystem::weakly_canonical(config.capture_root, filesystem_error);
  if (filesystem_error || root.empty() ||
      !std::filesystem::is_directory(root, filesystem_error)) {
    *error = "captureRoot is not an accessible directory";
    return false;
  }
  const std::filesystem::path video =
      std::filesystem::canonical(config.video_path, filesystem_error);
  if (filesystem_error || !std::filesystem::is_regular_file(
                              video, filesystem_error)) {
    *error = "videoPath is not an accessible file";
    return false;
  }
  if (!IsPathWithin(root, video) ||
      Lowercase(video.extension().wstring()) != L".mp4" ||
      Lowercase(video.filename().wstring()).rfind(L"chunk_", 0) != 0) {
    *error = "videoPath must be a chunk MP4 inside captureRoot";
    return false;
  }
  const uintmax_t file_size = std::filesystem::file_size(video, filesystem_error);
  if (filesystem_error || file_size == 0 ||
      file_size > kMaximumVideoFileBytes) {
    *error = "videoPath is empty or exceeds the extraction size limit";
    return false;
  }
  *canonical_video = video;
  return true;
}

HRESULT CreateWicFactory(ComPtr<IWICImagingFactory>* factory) {
  HRESULT result = CoCreateInstance(CLSID_WICImagingFactory2, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(factory->GetAddressOf()));
  if (FAILED(result)) {
    result = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(factory->GetAddressOf()));
  }
  return result;
}

HRESULT CopySampleToBgra(IMFSample* sample,
                         IMFMediaType* media_type,
                         std::vector<uint8_t>* pixels,
                         uint32_t* width,
                         uint32_t* height) {
  if (sample == nullptr || media_type == nullptr || pixels == nullptr ||
      width == nullptr || height == nullptr) {
    return E_POINTER;
  }
  UINT32 frame_width = 0;
  UINT32 frame_height = 0;
  HRESULT result =
      MFGetAttributeSize(media_type, MF_MT_FRAME_SIZE, &frame_width,
                         &frame_height);
  if (FAILED(result) || frame_width == 0 || frame_height == 0 ||
      frame_width > kHardMaximumExtractWidth * 8U ||
      frame_height > kHardMaximumExtractHeight * 8U) {
    return FAILED(result) ? result : MF_E_INVALIDMEDIATYPE;
  }
  ComPtr<IMFMediaBuffer> buffer;
  result = sample->ConvertToContiguousBuffer(buffer.GetAddressOf());
  if (FAILED(result)) {
    return result;
  }
  const size_t row_bytes = static_cast<size_t>(frame_width) * 4U;
  const size_t total_bytes = row_bytes * frame_height;
  pixels->resize(total_bytes);

  ComPtr<IMF2DBuffer> buffer2d;
  if (SUCCEEDED(buffer.As(&buffer2d))) {
    BYTE* scanline = nullptr;
    LONG pitch = 0;
    result = buffer2d->Lock2D(&scanline, &pitch);
    if (FAILED(result)) {
      return result;
    }
    result = MFCopyImage(pixels->data(), static_cast<LONG>(row_bytes),
                         scanline, pitch, static_cast<DWORD>(row_bytes),
                         frame_height);
    buffer2d->Unlock2D();
  } else {
    BYTE* data = nullptr;
    DWORD maximum_length = 0;
    DWORD current_length = 0;
    result = buffer->Lock(&data, &maximum_length, &current_length);
    if (FAILED(result)) {
      return result;
    }
    LONG stride = static_cast<LONG>(row_bytes);
    const UINT32 stored_stride =
        MFGetAttributeUINT32(media_type, MF_MT_DEFAULT_STRIDE,
                             static_cast<UINT32>(stride));
    stride = static_cast<LONG>(stored_stride);
    const size_t absolute_stride =
        static_cast<size_t>(stride < 0 ? -static_cast<int64_t>(stride)
                                      : stride);
    if (absolute_stride < row_bytes ||
        absolute_stride * frame_height > current_length) {
      result = MF_E_BUFFERTOOSMALL;
    } else {
      result = CopyDecodedRgb32Rows(data, current_length, frame_width,
                                    frame_height, stride, pixels->data(),
                                    pixels->size())
                   ? S_OK
                   : MF_E_BUFFERTOOSMALL;
    }
    buffer->Unlock();
  }
  if (SUCCEEDED(result)) {
    *width = frame_width;
    *height = frame_height;
  }
  return result;
}

HRESULT EncodeJpegToMemory(IWICImagingFactory* factory,
                           const std::vector<uint8_t>& pixels,
                           uint32_t width,
                           uint32_t height,
                           const VideoFrameExtractionConfig& config,
                           std::vector<uint8_t>* jpeg_bytes) {
  if (factory == nullptr || pixels.empty() || jpeg_bytes == nullptr) {
    return E_INVALIDARG;
  }
  uint32_t target_width = 0;
  uint32_t target_height = 0;
  const double scale =
      std::min(1.0, std::min(static_cast<double>(config.max_width) / width,
                            static_cast<double>(config.max_height) / height));
  target_width = std::max<uint32_t>(
      1, static_cast<uint32_t>(std::lround(width * scale)));
  target_height = std::max<uint32_t>(
      1, static_cast<uint32_t>(std::lround(height * scale)));

  const uint64_t stride = static_cast<uint64_t>(width) * 4ULL;
  const uint64_t byte_count = stride * height;
  if (stride > std::numeric_limits<UINT>::max() ||
      byte_count > std::numeric_limits<UINT>::max()) {
    return E_INVALIDARG;
  }
  ComPtr<IWICBitmap> bitmap;
  HRESULT result = factory->CreateBitmapFromMemory(
      width, height, GUID_WICPixelFormat32bppBGR, static_cast<UINT>(stride),
      static_cast<UINT>(byte_count), const_cast<BYTE*>(pixels.data()),
      bitmap.GetAddressOf());
  if (FAILED(result)) {
    return result;
  }
  ComPtr<IWICBitmapSource> source = bitmap;
  ComPtr<IWICBitmapScaler> scaler;
  if (target_width != width || target_height != height) {
    result = factory->CreateBitmapScaler(scaler.GetAddressOf());
    if (FAILED(result)) {
      return result;
    }
    result = scaler->Initialize(source.Get(), target_width, target_height,
                                WICBitmapInterpolationModeFant);
    if (FAILED(result)) {
      return result;
    }
    source = scaler;
  }
  ComPtr<IWICFormatConverter> converter;
  result = factory->CreateFormatConverter(converter.GetAddressOf());
  if (FAILED(result)) {
    return result;
  }
  result = converter->Initialize(
      source.Get(), GUID_WICPixelFormat24bppBGR, WICBitmapDitherTypeNone,
      nullptr, 0.0, WICBitmapPaletteTypeCustom);
  if (FAILED(result)) {
    return result;
  }

  ComPtr<IStream> memory_stream;
  result = CreateStreamOnHGlobal(nullptr, TRUE, memory_stream.GetAddressOf());
  if (FAILED(result)) {
    return result;
  }
  ComPtr<IWICStream> wic_stream;
  result = factory->CreateStream(wic_stream.GetAddressOf());
  if (FAILED(result)) {
    return result;
  }
  result = wic_stream->InitializeFromIStream(memory_stream.Get());
  if (FAILED(result)) {
    return result;
  }
  ComPtr<IWICBitmapEncoder> encoder;
  result = factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr,
                                  encoder.GetAddressOf());
  if (FAILED(result)) {
    return result;
  }
  result = encoder->Initialize(wic_stream.Get(), WICBitmapEncoderNoCache);
  if (FAILED(result)) {
    return result;
  }
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> properties;
  result = encoder->CreateNewFrame(frame.GetAddressOf(),
                                   properties.GetAddressOf());
  if (FAILED(result)) {
    return result;
  }
  if (properties != nullptr) {
    PROPBAG2 option = {};
    option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT quality;
    VariantInit(&quality);
    quality.vt = VT_R4;
    quality.fltVal = static_cast<float>(config.jpeg_quality) / 100.0F;
    static_cast<void>(properties->Write(1, &option, &quality));
    VariantClear(&quality);
  }
  result = frame->Initialize(properties.Get());
  if (SUCCEEDED(result)) {
    result = frame->SetSize(target_width, target_height);
  }
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  if (SUCCEEDED(result)) {
    result = frame->SetPixelFormat(&format);
  }
  if (SUCCEEDED(result)) {
    result = frame->WriteSource(converter.Get(), nullptr);
  }
  if (SUCCEEDED(result)) {
    result = frame->Commit();
  }
  if (SUCCEEDED(result)) {
    result = encoder->Commit();
  }
  if (SUCCEEDED(result)) {
    result = wic_stream->Commit(STGC_DEFAULT);
  }
  if (FAILED(result)) {
    return result;
  }

  STATSTG statistics = {};
  result = memory_stream->Stat(&statistics, STATFLAG_NONAME);
  if (FAILED(result) || statistics.cbSize.HighPart != 0 ||
      statistics.cbSize.LowPart > config.max_frame_bytes) {
    return FAILED(result) ? result : HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE);
  }
  HGLOBAL global = nullptr;
  result = GetHGlobalFromStream(memory_stream.Get(), &global);
  if (FAILED(result) || global == nullptr) {
    return FAILED(result) ? result : E_FAIL;
  }
  const void* bytes = GlobalLock(global);
  if (bytes == nullptr) {
    return HRESULT_FROM_WIN32(GetLastError());
  }
  jpeg_bytes->assign(static_cast<const uint8_t*>(bytes),
                     static_cast<const uint8_t*>(bytes) +
                         statistics.cbSize.LowPart);
  GlobalUnlock(global);
  return S_OK;
}

}  // namespace

class CaptureService::Impl {
 public:
  Impl(CaptureEventCallback callback, NativeFrameLogger* frame_logger)
      : callback_(std::move(callback)), frame_logger_(frame_logger) {}

  ~Impl() { Shutdown(); }

  bool Start(const CaptureConfig& config, std::string* error) {
    std::lock_guard<std::mutex> lock(lifecycle_mutex_);
    if (state_.load() != CaptureState::kStopped) {
      if (error != nullptr) {
        *error = "Capture is already active";
      }
      return false;
    }
    if (config.output_root.empty() || config.session_id.empty() ||
        !std::isfinite(config.fps) ||
        config.fps != kCaptureFramesPerSecond ||
        config.chunk_duration_seconds != kCaptureChunkDurationSeconds ||
        config.max_width != kCaptureVideoWidth ||
        config.max_height != kCaptureVideoHeight) {
      if (error != nullptr) {
        *error =
            "Capture requires 1920x1080, 1 FPS, and 60-second chunks";
      }
      return false;
    }
    if (worker_.joinable()) {
      worker_.join();
    }
    config_ = config;
    chunk_progress_.Configure(CalculateRegularChunkFrameCount(
        config_.fps, config_.chunk_duration_seconds));
    previous_cpu_sample_.reset();
    session_id_ = config.session_id;
    stop_requested_.store(false);
    manual_pause_requested_.store(false);
    state_.store(CaptureState::kStarting);
    EmitState(CaptureState::kStarting, "initializing");
    worker_ = std::thread(&Impl::Run, this);
    return true;
  }

  bool Pause(std::string* error) {
    const CaptureState current = state_.load();
    if (current == CaptureState::kStopped ||
        current == CaptureState::kStopping) {
      if (error != nullptr) {
        *error = "Capture is not active";
      }
      return false;
    }
    manual_pause_requested_.store(true);
    wake_condition_.notify_all();
    return true;
  }

  bool Resume(std::string* error) {
    const CaptureState current = state_.load();
    if (current == CaptureState::kStopped ||
        current == CaptureState::kStopping) {
      if (error != nullptr) {
        *error = "Capture is not active";
      }
      return false;
    }
    manual_pause_requested_.store(false);
    wake_condition_.notify_all();
    return true;
  }

  bool Stop(std::string* error) {
    if (state_.load() == CaptureState::kStopped) {
      if (error != nullptr) {
        *error = "Capture is already stopped";
      }
      return false;
    }
    stop_requested_.store(true);
    EmitState(CaptureState::kStopping, "stopRequested");
    wake_condition_.notify_all();
    std::lock_guard<std::mutex> lock(lifecycle_mutex_);
    if (worker_.joinable()) {
      worker_.join();
    }
    return true;
  }

  void Shutdown() {
    stop_requested_.store(true);
    wake_condition_.notify_all();
    std::lock_guard<std::mutex> lock(lifecycle_mutex_);
    if (worker_.joinable()) {
      worker_.join();
    }
  }

  CaptureState state() const { return state_.load(); }

  std::string session_id() const {
    std::lock_guard<std::mutex> lock(lifecycle_mutex_);
    return session_id_;
  }

 private:
  struct PendingWindowRecord {
    WindowRecord record;
    std::optional<ProcessCpuSample> cpu_sample;
  };

  void Run() {
    const HRESULT com_result =
        CoInitializeEx(nullptr, COINIT_MULTITHREADED | COINIT_DISABLE_OLE1DDE);
    const bool com_initialized = SUCCEEDED(com_result);
    if (!com_initialized && com_result != RPC_E_CHANGED_MODE) {
      EmitError("comInitializationFailed", "Unable to initialize COM",
                com_result, false);
      FinishWorker(com_initialized, false);
      return;
    }
    HRESULT result = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    const bool media_foundation_started = SUCCEEDED(result);
    if (!media_foundation_started) {
      EmitError("mediaFoundationInitializationFailed",
                "Unable to initialize Media Foundation", result, false);
      FinishWorker(com_initialized, false);
      return;
    }
    result = CreateWicFactory(&wic_factory_);
    if (FAILED(result)) {
      EmitError("wicInitializationFailed", "Unable to initialize WIC", result,
                false);
      FinishWorker(com_initialized, media_foundation_started);
      return;
    }

    std::error_code filesystem_error;
    capture_directory_ = std::filesystem::path(config_.output_root);
    std::filesystem::create_directories(capture_directory_, filesystem_error);
    if (filesystem_error) {
      EmitError("directoryCreateFailed", "Unable to create capture directory",
                HRESULT_FROM_WIN32(filesystem_error.value()), false);
      FinishWorker(com_initialized, media_foundation_started);
      return;
    }

    uint32_t retry_attempt = 0;
    SteadyClock::time_point next_frame_time = SteadyClock::now();
    bool was_paused = false;
    while (!stop_requested_.load()) {
      if (output_captures_.empty()) {
        result = InitializeCaptureTopology();
        if (FAILED(result)) {
          ++retry_attempt;
          EmitError("captureInitializationFailed",
                    "Unable to initialize the active display output", result,
                    true);
          EmitStateIfChanged(CaptureState::kStarting, "retrying");
          WaitFor(std::chrono::seconds(std::min<uint32_t>(retry_attempt, 5)));
          continue;
        }
        retry_attempt = 0;
        next_frame_time = SteadyClock::now();
      }

      const bool manual_paused = manual_pause_requested_.load();
      const bool idle_paused =
          config_.idle_pause_enabled &&
          GetIdleMillisecondsInternal() >=
              static_cast<uint64_t>(config_.idle_timeout_seconds) * 1000ULL;
      if (manual_paused || idle_paused) {
        if (!was_paused) {
          FinalizeCurrentChunk(SteadyClock::now());
          was_paused = true;
        }
        EmitStateIfChanged(manual_paused ? CaptureState::kManualPaused
                                        : CaptureState::kIdlePaused,
                           manual_paused ? "manual" : "idle");
        WaitFor(std::chrono::milliseconds(250));
        continue;
      }
      if (was_paused) {
        was_paused = false;
        next_frame_time = SteadyClock::now();
      }
      EmitStateIfChanged(CaptureState::kRecording, "active");

      const SteadyClock::time_point now = SteadyClock::now();
      if (now < next_frame_time) {
        WaitUntil(next_frame_time);
        continue;
      }
      const auto interval = std::chrono::duration<double>(1.0 / config_.fps);
      next_frame_time = now +
                        std::chrono::duration_cast<SteadyClock::duration>(
                            interval);

      bool topology_changed = false;
      result = DetectCaptureTargetChange(&topology_changed);
      if (FAILED(result)) {
        const CaptureLoopDecision decision =
            chunk_progress_.OnTopologyCheckUnavailable();
        if (decision.finalize_chunk) {
          FinalizeCurrentChunk(now);
        }
        if (decision.rebuild_topology) {
          ResetCaptureTopology();
        }
        EmitState(CaptureState::kStarting, "reconnecting");
        EmitError("displayTopologyCheckFailed",
                  "Unable to verify the display topology", result, true);
        continue;
      }
      if (topology_changed) {
        const CaptureLoopDecision decision =
            chunk_progress_.OnTopologyChanged();
        if (decision.finalize_chunk) {
          FinalizeCurrentChunk(now);
        }
        if (decision.rebuild_topology) {
          ResetCaptureTopology();
        }
        EmitState(CaptureState::kStarting, "topologyChanged");
        continue;
      }

      const std::vector<uint8_t>* source_frame = nullptr;
      result = AcquireSelectedFrame(&source_frame);
      if (result == S_FALSE) {
        continue;
      }
      if (FAILED(result)) {
        const bool access_lost = IsRecoverableCaptureError(result);
        EmitError(access_lost ? "captureAccessLost" : "captureFrameFailed",
                  access_lost
                      ? "Desktop Duplication access was lost; rebuilding the active output"
                      : "Unable to acquire the active display frame",
                   result, true);
        const CaptureLoopDecision decision =
            access_lost
                ? chunk_progress_.OnRecoverableCaptureError()
                : CaptureLoopDecision{true, true};
        if (decision.finalize_chunk) {
          FinalizeCurrentChunk(now);
        }
        if (decision.rebuild_topology) {
          ResetCaptureTopology();
        }
        EmitState(CaptureState::kStarting, "reconnecting");
        WaitFor(std::chrono::milliseconds(250));
        continue;
      }

      if (!chunk_open_) {
        result = StartNewChunk(now);
        if (FAILED(result)) {
          EmitError("videoWriterInitializationFailed",
                    "Unable to initialize the H.264 MP4 writer", result, true);
          ResetChunkState(true);
          WaitFor(std::chrono::milliseconds(500));
          continue;
        }
      }
      const SteadyClock::time_point sample_time = SteadyClock::now();
      PendingWindowRecord pending_window = SampleForegroundWindow(sample_time);
      const uint64_t frame_index = chunk_progress_.frame_count();
      result = WriteVideoFrame(*source_frame);
      if (frame_logger_ != nullptr) {
        frame_logger_->LogFrame(NativeFrameLogEntry{
            chunk_id_, frame_index, pending_window.record.timestamp_ms,
            pending_window.record.offset_ms,
            output_captures_.empty()
                ? std::string()
                : output_captures_.front().output().info.id,
            SUCCEEDED(result), static_cast<int64_t>(result)});
      }
      if (FAILED(result)) {
        EmitError("videoFrameWriteFailed",
                  "Unable to write a frame to the MP4 chunk", result, true);
        FinalizeCurrentChunk(now);
      } else {
        const CaptureLoopDecision decision =
            chunk_progress_.OnFrameWritten(pending_window.record.offset_ms);
        CommitWindowRecord(std::move(pending_window));
        TrackCapturedSource(sample_time);
        if (decision.finalize_chunk) {
          FinalizeCurrentChunk(sample_time);
        }
      }
    }

    FinalizeCurrentChunk(SteadyClock::now());
    ResetCaptureTopology();
    wic_factory_.Reset();
    FinishWorker(com_initialized, media_foundation_started);
  }

  void FinishWorker(bool com_initialized, bool media_foundation_started) {
    if (media_foundation_started) {
      static_cast<void>(MFShutdown());
    }
    state_.store(CaptureState::kStopped);
    EmitState(CaptureState::kStopped, "stopped");
    if (com_initialized) {
      CoUninitialize();
    }
  }

  void WaitFor(std::chrono::milliseconds duration) {
    std::unique_lock<std::mutex> lock(wait_mutex_);
    wake_condition_.wait_for(lock, duration,
                             [this]() { return stop_requested_.load(); });
  }

  void WaitFor(std::chrono::seconds duration) {
    WaitFor(std::chrono::duration_cast<std::chrono::milliseconds>(duration));
  }

  void WaitUntil(SteadyClock::time_point deadline) {
    std::unique_lock<std::mutex> lock(wait_mutex_);
    wake_condition_.wait_until(lock, deadline, [this]() {
      return stop_requested_.load() || manual_pause_requested_.load();
    });
  }

  HRESULT InitializeCaptureTopology() {
    ResetCaptureTopology();
    std::vector<NativeOutput> outputs;
    HRESULT result = EnumerateNativeOutputs(&outputs);
    if (FAILED(result)) {
      return result;
    }
    const size_t selected_index =
        SelectNativeOutputIndex(outputs, ResolveCaptureMonitor());
    NativeOutput selected = std::move(outputs[selected_index]);
    const DisplayInfo selected_info = selected.info;
    const uint64_t byte_count =
        static_cast<uint64_t>(selected_info.width) *
        static_cast<uint64_t>(selected_info.height) * 4ULL;
    if (selected_info.width <= 0 || selected_info.height <= 0 ||
        byte_count > kMaximumSourceFrameBytes) {
      return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_MEMORY);
    }
    OutputCapture capture(std::move(selected));
    result = capture.Initialize();
    if (FAILED(result)) {
      return result;
    }
    output_captures_.push_back(std::move(capture));
    virtual_left_ = selected_info.left;
    virtual_top_ = selected_info.top;
    virtual_width_ = static_cast<uint32_t>(selected_info.width);
    virtual_height_ = static_cast<uint32_t>(selected_info.height);
    return S_OK;
  }

  void ResetCaptureTopology() {
    output_captures_.clear();
    virtual_left_ = 0;
    virtual_top_ = 0;
    virtual_width_ = 0;
    virtual_height_ = 0;
  }

  HRESULT DetectCaptureTargetChange(bool* changed) const {
    if (changed == nullptr) {
      return E_POINTER;
    }
    std::vector<NativeOutput> current;
    const HRESULT result = EnumerateNativeOutputs(&current);
    if (FAILED(result)) {
      return result;
    }
    if (output_captures_.size() != 1) {
      *changed = true;
      return S_OK;
    }
    const size_t selected_index =
        SelectNativeOutputIndex(current, ResolveCaptureMonitor());
    *changed =
        !SameOutput(current[selected_index], output_captures_.front().output());
    return S_OK;
  }

  HRESULT AcquireSelectedFrame(const std::vector<uint8_t>** frame) {
    if (frame == nullptr || output_captures_.size() != 1 ||
        virtual_width_ == 0 || virtual_height_ == 0) {
      return E_UNEXPECTED;
    }
    *frame = nullptr;
    OutputCapture& capture = output_captures_.front();
    const HRESULT result = capture.Acquire();
    if (result == S_FALSE || FAILED(result)) {
      return result;
    }
    const std::vector<uint8_t>& pixels = capture.pixels();
    const size_t expected_bytes =
        static_cast<size_t>(virtual_width_) * virtual_height_ * 4U;
    if (pixels.size() != expected_bytes) {
      return E_UNEXPECTED;
    }
    *frame = &pixels;
    return S_OK;
  }

  HRESULT StartNewChunk(SteadyClock::time_point now) {
    chunk_start_steady_ = now;
    chunk_start_time_ms_ = UnixTimeMillis();
    std::error_code filesystem_error;
    const std::string safe_session = SanitizePathComponent(config_.session_id);
    do {
      ++chunk_sequence_;
      chunk_id_ = "chunk_" + safe_session + "_" +
                  std::to_string(chunk_start_time_ms_) + "_" +
                  std::to_string(chunk_sequence_);
      final_video_path_ =
          capture_directory_ / WideFromUtf8(chunk_id_ + ".mp4");
      temporary_video_path_ =
          capture_directory_ / WideFromUtf8(chunk_id_ + ".partial.mp4");
      metadata_path_ = capture_directory_ / WideFromUtf8(chunk_id_ + ".json");
      std::filesystem::path temporary_metadata_path = metadata_path_;
      temporary_metadata_path += L".tmp";
      filesystem_error.clear();
      const bool collision =
          std::filesystem::exists(final_video_path_, filesystem_error) ||
          std::filesystem::exists(temporary_video_path_, filesystem_error) ||
          std::filesystem::exists(metadata_path_, filesystem_error) ||
          std::filesystem::exists(temporary_metadata_path, filesystem_error);
      if (filesystem_error) {
        return HRESULT_FROM_WIN32(filesystem_error.value());
      }
      if (!collision) {
        break;
      }
    } while (true);
    if (capture_directory_.empty()) {
      return E_UNEXPECTED;
    }

    video_width_ = kCaptureVideoWidth;
    video_height_ = kCaptureVideoHeight;
    owns_temporary_video_ = true;
    HRESULT result = CreateSinkWriter();
    if (FAILED(result)) {
      ResetChunkState(true);
      return result;
    }
    chunk_displays_.clear();
    source_changes_.clear();
    has_chunk_virtual_desktop_ = false;
    chunk_virtual_left_ = 0;
    chunk_virtual_top_ = 0;
    chunk_virtual_width_ = 0;
    chunk_virtual_height_ = 0;
    window_records_.clear();
    chunk_progress_.Reset();
    chunk_open_ = true;
    return S_OK;
  }

  HRESULT CreateSinkWriter() {
    ComPtr<IMFAttributes> attributes;
    HRESULT result = MFCreateAttributes(attributes.GetAddressOf(), 3);
    if (FAILED(result)) {
      return result;
    }
    static_cast<void>(attributes->SetUINT32(
        MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE));
    static_cast<void>(attributes->SetUINT32(
        MF_SINK_WRITER_DISABLE_THROTTLING, TRUE));
    static_cast<void>(attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE,
                                          MFTranscodeContainerType_MPEG4));
    result = MFCreateSinkWriterFromURL(temporary_video_path_.c_str(), nullptr,
                                       attributes.Get(),
                                       sink_writer_.GetAddressOf());
    if (FAILED(result)) {
      return result;
    }

    frame_rate_numerator_ = 1;
    frame_rate_denominator_ = 1;
    frame_duration_ticks_ = kMediaFoundationTicksPerSecond;

    ComPtr<IMFMediaType> output_type;
    result = MFCreateMediaType(output_type.GetAddressOf());
    if (FAILED(result)) {
      return result;
    }
    result = output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    if (SUCCEEDED(result)) {
      result = output_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    }
    const uint64_t estimated_bitrate = static_cast<uint64_t>(std::llround(
        static_cast<long double>(video_width_) * video_height_ *
        kCaptureFramesPerSecond * 2.5L));
    const uint32_t bitrate = static_cast<uint32_t>(
        std::clamp<uint64_t>(estimated_bitrate, kMinimumVideoBitrate,
                             kMaximumVideoBitrate));
    if (SUCCEEDED(result)) {
      result = output_type->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
    }
    if (SUCCEEDED(result)) {
      result = output_type->SetUINT32(MF_MT_INTERLACE_MODE,
                                      MFVideoInterlace_Progressive);
    }
    if (SUCCEEDED(result)) {
      result = MFSetAttributeSize(output_type.Get(), MF_MT_FRAME_SIZE,
                                  video_width_, video_height_);
    }
    if (SUCCEEDED(result)) {
      result = MFSetAttributeRatio(output_type.Get(), MF_MT_FRAME_RATE,
                                   frame_rate_numerator_,
                                   frame_rate_denominator_);
    }
    if (SUCCEEDED(result)) {
      result = MFSetAttributeRatio(output_type.Get(), MF_MT_PIXEL_ASPECT_RATIO,
                                   1, 1);
    }
    if (FAILED(result)) {
      return result;
    }
    result = sink_writer_->AddStream(output_type.Get(), &sink_stream_index_);
    if (FAILED(result)) {
      return result;
    }

    ComPtr<IMFMediaType> input_type;
    result = MFCreateMediaType(input_type.GetAddressOf());
    if (SUCCEEDED(result)) {
      result = input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    }
    if (SUCCEEDED(result)) {
      result = input_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    }
    if (SUCCEEDED(result)) {
      result = input_type->SetUINT32(MF_MT_INTERLACE_MODE,
                                     MFVideoInterlace_Progressive);
    }
    if (SUCCEEDED(result)) {
      result = MFSetAttributeSize(input_type.Get(), MF_MT_FRAME_SIZE,
                                  video_width_, video_height_);
    }
    if (SUCCEEDED(result)) {
      result = MFSetAttributeRatio(input_type.Get(), MF_MT_FRAME_RATE,
                                   frame_rate_numerator_,
                                   frame_rate_denominator_);
    }
    if (SUCCEEDED(result)) {
      result = MFSetAttributeRatio(input_type.Get(), MF_MT_PIXEL_ASPECT_RATIO,
                                   1, 1);
    }
    if (SUCCEEDED(result)) {
      result = input_type->SetUINT32(MF_MT_DEFAULT_STRIDE, video_width_ * 4U);
    }
    if (SUCCEEDED(result)) {
      result = input_type->SetUINT32(MF_MT_FIXED_SIZE_SAMPLES, TRUE);
    }
    if (SUCCEEDED(result)) {
      result = input_type->SetUINT32(MF_MT_SAMPLE_SIZE,
                                     video_width_ * video_height_ * 4U);
    }
    if (SUCCEEDED(result)) {
      result = sink_writer_->SetInputMediaType(sink_stream_index_,
                                               input_type.Get(), nullptr);
    }
    if (SUCCEEDED(result)) {
      result = sink_writer_->BeginWriting();
    }
    return result;
  }

  HRESULT WriteVideoFrame(const std::vector<uint8_t>& source_frame) {
    if (!chunk_open_ || sink_writer_ == nullptr) {
      return E_UNEXPECTED;
    }
    std::vector<uint8_t> resized;
    HRESULT result = LetterboxBgraWithWic(
        wic_factory_.Get(), source_frame, virtual_width_, virtual_height_,
        video_width_, video_height_, &resized);
    if (FAILED(result)) {
      return result;
    }
    const size_t byte_count = resized.size();
    if (byte_count > std::numeric_limits<DWORD>::max()) {
      return E_INVALIDARG;
    }
    ComPtr<IMFMediaBuffer> buffer;
    result = MFCreateMemoryBuffer(static_cast<DWORD>(byte_count),
                                  buffer.GetAddressOf());
    if (FAILED(result)) {
      return result;
    }
    BYTE* destination = nullptr;
    DWORD maximum_length = 0;
    result = buffer->Lock(&destination, &maximum_length, nullptr);
    if (FAILED(result)) {
      return result;
    }
    if (maximum_length < byte_count) {
      buffer->Unlock();
      return MF_E_BUFFERTOOSMALL;
    }
    if (!CopyTopDownBgraRows(resized.data(), resized.size(), video_width_,
                             video_height_, destination, maximum_length)) {
      buffer->Unlock();
      return E_INVALIDARG;
    }
    buffer->Unlock();
    result = buffer->SetCurrentLength(static_cast<DWORD>(byte_count));
    if (FAILED(result)) {
      return result;
    }
    ComPtr<IMFSample> sample;
    result = MFCreateSample(sample.GetAddressOf());
    if (SUCCEEDED(result)) {
      result = sample->AddBuffer(buffer.Get());
    }
    if (SUCCEEDED(result)) {
      result = sample->SetSampleTime(
          static_cast<LONGLONG>(chunk_progress_.frame_count()) *
          frame_duration_ticks_);
    }
    if (SUCCEEDED(result)) {
      result = sample->SetSampleDuration(frame_duration_ticks_);
    }
    if (SUCCEEDED(result)) {
      result = sink_writer_->WriteSample(sink_stream_index_, sample.Get());
    }
    return result;
  }

  PendingWindowRecord SampleForegroundWindow(SteadyClock::time_point now) {
    PendingWindowRecord pending;
    const WindowSnapshot snapshot =
        window_tracker_.GetForegroundWindowSnapshot();
    const int64_t offset_ms = std::max<int64_t>(
        0, std::chrono::duration_cast<std::chrono::milliseconds>(
               now - chunk_start_steady_)
               .count());
    pending.record.timestamp_ms = chunk_start_time_ms_ + offset_ms;
    pending.record.offset_ms = offset_ms;
    pending.record.process_id = snapshot.process_id;
    pending.record.window_title = snapshot.window_title;
    pending.record.process_name = snapshot.process_name;
    pending.record.process_path = snapshot.process_path;
    pending.record.app_name = snapshot.app_name;
    pending.record.memory_commit_bytes = snapshot.memory_commit_bytes;
    if (snapshot.creation_time_100ns.has_value() &&
        snapshot.process_time_100ns.has_value()) {
      pending.cpu_sample = ProcessCpuSample{
          snapshot.process_id,
          *snapshot.creation_time_100ns,
          *snapshot.process_time_100ns,
          SteadyTimeTicks100ns(now),
      };
      pending.record.cpu_usage_percent = CalculateCpuUsagePercent(
          previous_cpu_sample_, *pending.cpu_sample, logical_processor_count_);
    }
    return pending;
  }

  void CommitWindowRecord(PendingWindowRecord pending) {
    previous_cpu_sample_ = pending.cpu_sample;
    window_records_.push_back(std::move(pending.record));
  }

  static bool SameDisplaySource(const DisplayInfo& display,
                                const SourceChangeRecord& source) {
    return _stricmp(display.id.c_str(), source.display_id.c_str()) == 0 &&
           display.left == source.left && display.top == source.top &&
           display.width == source.width && display.height == source.height;
  }

  static bool SameDisplaySource(const DisplayInfo& left,
                                const DisplayInfo& right) {
    return _stricmp(left.id.c_str(), right.id.c_str()) == 0 &&
           left.left == right.left && left.top == right.top &&
           left.width == right.width && left.height == right.height;
  }

  void TrackCapturedSource(SteadyClock::time_point now) {
    if (!chunk_open_ || output_captures_.size() != 1) {
      return;
    }
    const DisplayInfo& display = output_captures_.front().output().info;
    const int64_t offset_ms = std::max<int64_t>(
        0, std::chrono::duration_cast<std::chrono::milliseconds>(
               now - chunk_start_steady_)
               .count());
    if (!has_chunk_virtual_desktop_) {
      chunk_virtual_left_ = display.left;
      chunk_virtual_top_ = display.top;
      chunk_virtual_width_ = display.width;
      chunk_virtual_height_ = display.height;
      has_chunk_virtual_desktop_ = true;
    }
    if (std::none_of(chunk_displays_.begin(), chunk_displays_.end(),
                     [&display](const DisplayInfo& existing) {
                       return SameDisplaySource(existing, display);
                     })) {
      chunk_displays_.push_back(display);
    }
    if (!source_changes_.empty() &&
        SameDisplaySource(display, source_changes_.back())) {
      return;
    }
    SourceChangeRecord source;
    source.timestamp_ms = chunk_start_time_ms_ + offset_ms;
    source.offset_ms = offset_ms;
    source.display_id = display.id;
    source.left = display.left;
    source.top = display.top;
    source.width = display.width;
    source.height = display.height;
    source_changes_.push_back(std::move(source));
  }

  void FinalizeCurrentChunk(SteadyClock::time_point now) {
    if (!chunk_open_) {
      return;
    }
    if (chunk_progress_.frame_count() == 0) {
      ResetChunkState(true);
      return;
    }
    if (sink_writer_ == nullptr) {
      EmitError("videoWriterUnavailable",
                "The partial MP4 was retained because the writer was unavailable",
                E_UNEXPECTED, true);
      ResetChunkState(false);
      return;
    }
    const HRESULT finalize_result = sink_writer_->Finalize();
    sink_writer_.Reset();
    if (FAILED(finalize_result)) {
      EmitError("videoFinalizeFailed", "Unable to finalize the MP4 chunk",
                finalize_result, true);
      ResetChunkState(false);
      return;
    }
    if (!MoveFileExW(temporary_video_path_.c_str(), final_video_path_.c_str(),
                     MOVEFILE_WRITE_THROUGH)) {
      const HRESULT move_result = HRESULT_FROM_WIN32(GetLastError());
      EmitError("videoCommitFailed", "Unable to commit the MP4 chunk",
                move_result, true);
      ResetChunkState(false);
      return;
    }
    owns_temporary_video_ = false;
    owns_final_video_ = true;

    const int64_t elapsed_ms = std::max<int64_t>(
        1, std::chrono::duration_cast<std::chrono::milliseconds>(
               now - chunk_start_steady_)
               .count());
    const int64_t encoded_duration_ms = std::max<int64_t>(
        1, static_cast<int64_t>(std::llround(
               static_cast<double>(chunk_progress_.frame_count()) * 1000.0 /
               kCaptureFramesPerSecond)));
    ChunkResult chunk;
    chunk.session_id = config_.session_id;
    chunk.chunk_id = chunk_id_;
    chunk.directory_path = Utf8FromWide(capture_directory_.wstring());
    chunk.video_path = Utf8FromWide(final_video_path_.wstring());
    chunk.metadata_path = Utf8FromWide(metadata_path_.wstring());
    chunk.start_time_ms = chunk_start_time_ms_;
    chunk.duration_ms = CalculateChunkDurationMs(
        elapsed_ms, encoded_duration_ms,
        chunk_progress_.latest_frame_offset_ms());
    chunk.end_time_ms = chunk.start_time_ms + chunk.duration_ms;
    chunk.video_frame_count = chunk_progress_.frame_count();
    chunk.video_width = video_width_;
    chunk.video_height = video_height_;
    chunk.virtual_left = chunk_virtual_left_;
    chunk.virtual_top = chunk_virtual_top_;
    chunk.virtual_width = chunk_virtual_width_;
    chunk.virtual_height = chunk_virtual_height_;
    chunk.displays = chunk_displays_;
    chunk.source_changes = source_changes_;
    chunk.window_records = window_records_;

    std::string metadata_error;
    if (!WriteUtf8FileAtomically(metadata_path_, BuildMetadataJson(chunk),
                                 &metadata_error)) {
      EmitError("metadataWriteFailed", metadata_error, E_FAIL, true);
      ResetChunkState(false);
      return;
    }
    owns_metadata_ = true;
    CaptureEvent event;
    event.type = CaptureEvent::Type::kChunkFinalized;
    event.timestamp_ms = UnixTimeMillis();
    event.session_id = config_.session_id;
    event.chunk = std::move(chunk);
    Emit(std::move(event));
    ResetChunkState(false);
  }

  std::string BuildMetadataJson(const ChunkResult& chunk) const {
    std::ostringstream output;
    output << "{\n"
           << "  \"schemaVersion\": 3,\n"
           << "  \"captureScope\": \"active-window-display\",\n"
           << "  \"sessionId\": \"" << JsonEscape(chunk.session_id)
           << "\",\n"
           << "  \"chunkId\": \"" << JsonEscape(chunk.chunk_id)
           << "\",\n"
           << "  \"startTimeMs\": " << chunk.start_time_ms << ",\n"
           << "  \"endTimeMs\": " << chunk.end_time_ms << ",\n"
           << "  \"durationMs\": " << chunk.duration_ms << ",\n"
           << "  \"virtualDesktop\": {\"left\": "
           << chunk.virtual_left << ", \"top\": " << chunk.virtual_top
           << ", \"width\": " << chunk.virtual_width
           << ", \"height\": " << chunk.virtual_height << "},\n"
           << "  \"video\": {\"path\": \""
           << JsonEscape(chunk.video_path) << "\", \"codec\": \"h264\", "
           << "\"container\": \"mp4\", \"fps\": 1"
           << ", \"frameCount\": " << chunk.video_frame_count
           << ", \"width\": " << chunk.video_width
           << ", \"height\": " << chunk.video_height << "},\n"
           << "  \"displays\": [\n";
    for (size_t index = 0; index < chunk.displays.size(); ++index) {
      const DisplayInfo& display = chunk.displays[index];
      output << "    {\"index\": " << display.index << ", \"id\": \""
             << JsonEscape(display.id) << "\", \"name\": \""
             << JsonEscape(display.name) << "\", \"adapterName\": \""
             << JsonEscape(display.adapter_name) << "\", \"left\": "
             << display.left << ", \"top\": " << display.top
             << ", \"width\": " << display.width << ", \"height\": "
             << display.height << ", \"rotation\": " << display.rotation
             << ", \"isPrimary\": "
             << (display.is_primary ? "true" : "false") << "}";
      output << (index + 1 == chunk.displays.size() ? "\n" : ",\n");
    }
    output << "  ],\n  \"sourceChanges\": [\n";
    for (size_t index = 0; index < chunk.source_changes.size(); ++index) {
      const SourceChangeRecord& source = chunk.source_changes[index];
      output << "    {\"timestampMs\": " << source.timestamp_ms
             << ", \"offsetMs\": " << source.offset_ms
             << ", \"displayId\": \"" << JsonEscape(source.display_id)
             << "\", \"left\": " << source.left << ", \"top\": "
             << source.top << ", \"width\": " << source.width
             << ", \"height\": " << source.height << "}";
      output <<
          (index + 1 == chunk.source_changes.size() ? "\n" : ",\n");
    }
    output << "  ],\n  \"windowRecords\": [\n";
    for (size_t index = 0; index < chunk.window_records.size(); ++index) {
      const WindowRecord& record = chunk.window_records[index];
      output << "    {\"timestampMs\": " << record.timestamp_ms
             << ", \"offsetMs\": " << record.offset_ms
             << ", \"processId\": " << record.process_id
             << ", \"appName\": \"" << JsonEscape(record.app_name)
             << "\", \"processName\": \""
             << JsonEscape(record.process_name)
             << "\", \"processPath\": \""
             << JsonEscape(record.process_path)
             << "\", \"windowTitle\": \""
             << JsonEscape(record.window_title)
             << "\", \"cpuUsagePercent\": ";
      if (record.cpu_usage_percent.has_value()) {
        output << *record.cpu_usage_percent;
      } else {
        output << "null";
      }
      output << ", \"memoryCommitBytes\": ";
      if (record.memory_commit_bytes.has_value()) {
        output << *record.memory_commit_bytes;
      } else {
        output << "null";
      }
      output << "}";
      output <<
          (index + 1 == chunk.window_records.size() ? "\n" : ",\n");
    }
    output << "  ]\n}\n";
    return output.str();
  }

  void ResetChunkState(bool remove_artifacts) {
    sink_writer_.Reset();
    if (remove_artifacts) {
      if (owns_temporary_video_ && !temporary_video_path_.empty()) {
        DeleteFileW(temporary_video_path_.c_str());
      }
      if (owns_final_video_ && !final_video_path_.empty()) {
        DeleteFileW(final_video_path_.c_str());
      }
      if (owns_metadata_ && !metadata_path_.empty()) {
        DeleteFileW(metadata_path_.c_str());
      }
    }
    chunk_open_ = false;
    chunk_id_.clear();
    temporary_video_path_.clear();
    final_video_path_.clear();
    metadata_path_.clear();
    chunk_displays_.clear();
    source_changes_.clear();
    window_records_.clear();
    has_chunk_virtual_desktop_ = false;
    chunk_virtual_left_ = 0;
    chunk_virtual_top_ = 0;
    chunk_virtual_width_ = 0;
    chunk_virtual_height_ = 0;
    chunk_progress_.Reset();
    video_width_ = 0;
    video_height_ = 0;
    owns_temporary_video_ = false;
    owns_final_video_ = false;
    owns_metadata_ = false;
  }

  void EmitStateIfChanged(CaptureState state, const std::string& reason) {
    if (state_.load() != state) {
      EmitState(state, reason);
    }
  }

  void EmitState(CaptureState state, const std::string& reason) {
    state_.store(state);
    CaptureEvent event;
    event.type = CaptureEvent::Type::kState;
    event.state = state;
    event.timestamp_ms = UnixTimeMillis();
    event.session_id = config_.session_id;
    event.reason = reason;
    Emit(std::move(event));
  }

  void EmitError(const std::string& code,
                 const std::string& message,
                 HRESULT result,
                 bool recoverable) {
    CaptureEvent event;
    event.type = CaptureEvent::Type::kError;
    event.timestamp_ms = UnixTimeMillis();
    event.session_id = config_.session_id;
    event.error_code = code;
    event.error_message = message;
    event.hresult = HResultString(result);
    event.recoverable = recoverable;
    Emit(std::move(event));
  }

  void Emit(CaptureEvent event) {
    if (callback_) {
      callback_(std::move(event));
    }
  }

  CaptureEventCallback callback_;
  NativeFrameLogger* frame_logger_ = nullptr;
  mutable std::mutex lifecycle_mutex_;
  std::mutex wait_mutex_;
  std::condition_variable wake_condition_;
  std::thread worker_;
  std::atomic<CaptureState> state_{CaptureState::kStopped};
  std::atomic<bool> stop_requested_{false};
  std::atomic<bool> manual_pause_requested_{false};
  CaptureConfig config_;
  std::string session_id_;

  ComPtr<IWICImagingFactory> wic_factory_;
  std::vector<OutputCapture> output_captures_;
  int32_t virtual_left_ = 0;
  int32_t virtual_top_ = 0;
  uint32_t virtual_width_ = 0;
  uint32_t virtual_height_ = 0;

  WindowTracker window_tracker_;
  std::filesystem::path capture_directory_;
  std::filesystem::path temporary_video_path_;
  std::filesystem::path final_video_path_;
  std::filesystem::path metadata_path_;
  bool owns_temporary_video_ = false;
  bool owns_final_video_ = false;
  bool owns_metadata_ = false;
  std::string chunk_id_;
  uint64_t chunk_sequence_ = 0;
  bool chunk_open_ = false;
  int64_t chunk_start_time_ms_ = 0;
  SteadyClock::time_point chunk_start_steady_;
  bool has_chunk_virtual_desktop_ = false;
  int32_t chunk_virtual_left_ = 0;
  int32_t chunk_virtual_top_ = 0;
  int32_t chunk_virtual_width_ = 0;
  int32_t chunk_virtual_height_ = 0;
  std::vector<DisplayInfo> chunk_displays_;
  std::vector<SourceChangeRecord> source_changes_;
  std::vector<WindowRecord> window_records_;
  std::optional<ProcessCpuSample> previous_cpu_sample_;
  const uint32_t logical_processor_count_ = LogicalProcessorCount();

  ComPtr<IMFSinkWriter> sink_writer_;
  DWORD sink_stream_index_ = 0;
  uint32_t frame_rate_numerator_ = 1;
  uint32_t frame_rate_denominator_ = 1;
  LONGLONG frame_duration_ticks_ = kMediaFoundationTicksPerSecond;
  CaptureChunkProgress chunk_progress_{60};
  uint32_t video_width_ = 0;
  uint32_t video_height_ = 0;
};

bool CaptureService::ExtractVideoFrames(
    const VideoFrameExtractionConfig& config,
    std::vector<ExtractedVideoFrame>* frames,
    std::string* error) {
  if (frames == nullptr || error == nullptr) {
    return false;
  }
  frames->clear();
  error->clear();
  if (config.max_frames == 0 ||
      config.max_frames > kHardMaximumExtractedFrames ||
      config.max_width == 0 || config.max_width > kHardMaximumExtractWidth ||
      config.max_height == 0 ||
      config.max_height > kHardMaximumExtractHeight ||
      config.jpeg_quality < 25 || config.jpeg_quality > 95 ||
      config.max_frame_bytes == 0 ||
      config.max_frame_bytes > kHardMaximumFrameBytes ||
      config.max_total_bytes == 0 ||
      config.max_total_bytes > kHardMaximumTotalBytes ||
      config.max_frame_bytes > config.max_total_bytes ||
      config.expected_frame_count > 36000) {
    *error = "Frame extraction limits are invalid";
    return false;
  }
  std::filesystem::path video_path;
  if (!ValidateVideoPath(config, &video_path, error)) {
    return false;
  }

  const HRESULT com_result =
      CoInitializeEx(nullptr, COINIT_MULTITHREADED | COINIT_DISABLE_OLE1DDE);
  const bool com_initialized = SUCCEEDED(com_result);
  if (!com_initialized && com_result != RPC_E_CHANGED_MODE) {
    *error = "Unable to initialize COM (" + HResultString(com_result) + ")";
    return false;
  }
  HRESULT result = MFStartup(MF_VERSION, MFSTARTUP_FULL);
  if (FAILED(result)) {
    if (com_initialized) {
      CoUninitialize();
    }
    *error = "Unable to initialize Media Foundation (" +
             HResultString(result) + ")";
    return false;
  }

  ComPtr<IWICImagingFactory> wic_factory;
  ComPtr<IMFSourceReader> reader;
  result = CreateWicFactory(&wic_factory);
  if (SUCCEEDED(result)) {
    ComPtr<IMFAttributes> attributes;
    result = MFCreateAttributes(attributes.GetAddressOf(), 2);
    if (SUCCEEDED(result)) {
      static_cast<void>(attributes->SetUINT32(
          MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE));
      static_cast<void>(attributes->SetUINT32(
          MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE));
      result = MFCreateSourceReaderFromURL(video_path.c_str(), attributes.Get(),
                                           reader.GetAddressOf());
    }
  }
  if (SUCCEEDED(result)) {
    static_cast<void>(
        reader->SetStreamSelection(kSourceReaderAllStreams, FALSE));
    result = reader->SetStreamSelection(kSourceReaderFirstVideoStream, TRUE);
  }
  ComPtr<IMFMediaType> requested_type;
  if (SUCCEEDED(result)) {
    result = MFCreateMediaType(requested_type.GetAddressOf());
  }
  if (SUCCEEDED(result)) {
    result = requested_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  }
  if (SUCCEEDED(result)) {
    result = requested_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  }
  if (SUCCEEDED(result)) {
    result = reader->SetCurrentMediaType(kSourceReaderFirstVideoStream, nullptr,
                                         requested_type.Get());
  }

  LONGLONG duration_ticks = 0;
  PROPVARIANT duration;
  PropVariantInit(&duration);
  if (SUCCEEDED(result) &&
      SUCCEEDED(reader->GetPresentationAttribute(
          kSourceReaderMediaSource, MF_PD_DURATION, &duration)) &&
      duration.vt == VT_UI8) {
    duration_ticks = static_cast<LONGLONG>(duration.uhVal.QuadPart);
  }
  PropVariantClear(&duration);
  if (SUCCEEDED(result) && duration_ticks <= 0) {
    result = MF_E_NO_DURATION;
  }

  const uint32_t estimated_count =
      config.expected_frame_count == 0 ? config.max_frames
                                       : config.expected_frame_count;
  const uint32_t target_count =
      std::min(config.max_frames, std::max<uint32_t>(1, estimated_count));
  uint64_t total_bytes = 0;
  LONGLONG previous_timestamp = -1;
  for (uint32_t index = 0; SUCCEEDED(result) && index < target_count; ++index) {
    LONGLONG target_ticks = duration_ticks / 2;
    if (target_count > 1) {
      target_ticks = static_cast<LONGLONG>(
          static_cast<long double>(std::max<LONGLONG>(0, duration_ticks - 1)) *
          index / (target_count - 1));
    }
    PROPVARIANT position;
    PropVariantInit(&position);
    position.vt = VT_I8;
    position.hVal.QuadPart = target_ticks;
    result = reader->SetCurrentPosition(GUID_NULL, position);
    PropVariantClear(&position);
    if (FAILED(result)) {
      break;
    }

    ComPtr<IMFSample> sample;
    LONGLONG timestamp = 0;
    for (uint32_t attempts = 0; attempts < 64 && sample == nullptr; ++attempts) {
      DWORD actual_stream = 0;
      DWORD flags = 0;
      result = reader->ReadSample(kSourceReaderFirstVideoStream, 0,
                                  &actual_stream, &flags, &timestamp,
                                  sample.GetAddressOf());
      if (FAILED(result)) {
        break;
      }
      if ((flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
        result = MF_E_END_OF_STREAM;
        break;
      }
      if ((flags & MF_SOURCE_READERF_ERROR) != 0) {
        result = E_FAIL;
        break;
      }
      if (sample != nullptr && timestamp <= previous_timestamp) {
        sample.Reset();
      }
    }
    if (result == MF_E_END_OF_STREAM && !frames->empty()) {
      result = S_OK;
      break;
    }
    if (FAILED(result) || sample == nullptr) {
      if (SUCCEEDED(result)) {
        result = MF_E_END_OF_STREAM;
      }
      break;
    }

    ComPtr<IMFMediaType> current_type;
    result = reader->GetCurrentMediaType(kSourceReaderFirstVideoStream,
                                         current_type.GetAddressOf());
    std::vector<uint8_t> pixels;
    uint32_t width = 0;
    uint32_t height = 0;
    if (SUCCEEDED(result)) {
      result = CopySampleToBgra(sample.Get(), current_type.Get(), &pixels,
                                &width, &height);
    }
    ExtractedVideoFrame frame;
    if (SUCCEEDED(result)) {
      frame.offset_ms = std::clamp<int64_t>(
          timestamp / (kMediaFoundationTicksPerSecond / 1000LL), 0,
          duration_ticks / (kMediaFoundationTicksPerSecond / 1000LL));
      result = EncodeJpegToMemory(wic_factory.Get(), pixels, width, height,
                                  config, &frame.jpeg_bytes);
    }
    if (SUCCEEDED(result)) {
      total_bytes += frame.jpeg_bytes.size();
      if (total_bytes > config.max_total_bytes) {
        result = HRESULT_FROM_WIN32(ERROR_FILE_TOO_LARGE);
      } else {
        previous_timestamp = timestamp;
        frames->push_back(std::move(frame));
      }
    }
  }

  reader.Reset();
  wic_factory.Reset();
  static_cast<void>(MFShutdown());
  if (com_initialized) {
    CoUninitialize();
  }
  if (FAILED(result) || frames->empty()) {
    frames->clear();
    *error = "Unable to extract MP4 frames (" + HResultString(result) + ")";
    return false;
  }
  return true;
}

CaptureService::CaptureService(CaptureEventCallback callback,
                               NativeFrameLogger* frame_logger)
    : impl_(std::make_unique<Impl>(std::move(callback), frame_logger)) {}

CaptureService::~CaptureService() = default;

uint64_t CaptureService::GetIdleMilliseconds() {
  return GetIdleMillisecondsInternal();
}

bool CaptureService::Start(const CaptureConfig& config, std::string* error) {
  return impl_->Start(config, error);
}

bool CaptureService::Pause(std::string* error) {
  return impl_->Pause(error);
}

bool CaptureService::Resume(std::string* error) {
  return impl_->Resume(error);
}

bool CaptureService::Stop(std::string* error) {
  return impl_->Stop(error);
}

void CaptureService::Shutdown() {
  impl_->Shutdown();
}

CaptureState CaptureService::state() const {
  return impl_->state();
}

std::string CaptureService::session_id() const {
  return impl_->session_id();
}

}  // namespace qi_day_flow
