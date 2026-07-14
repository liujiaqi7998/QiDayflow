#include "native_bridge.h"

#include "capture_runtime.h"
#include "startup_behavior.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincrypt.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cwctype>
#include <filesystem>
#include <limits>
#include <optional>
#include <sstream>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

namespace qi_day_flow {
namespace {

using EncodableList = flutter::EncodableList;
using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;
using MethodResult = flutter::MethodResult<EncodableValue>;
using Microsoft::WRL::ComPtr;

constexpr char kMethodChannelName[] = "qi_day_flow/platform";
constexpr char kEventChannelName[] = "qi_day_flow/capture_events";
constexpr char kEntropy[] = "QiDayFlow.DPAPI.v1";
constexpr wchar_t kRunRegistryPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValueName[] = L"QiDayFlow";

std::wstring WideFromUtf8(const std::string& value);

LSTATUS CanonicalExecutablePath(std::wstring* path) {
  if (path == nullptr) {
    return ERROR_INVALID_PARAMETER;
  }
  std::vector<wchar_t> buffer(32768);
  const DWORD length = GetModuleFileNameW(
      nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (length == 0) {
    const DWORD error = GetLastError();
    return error == ERROR_SUCCESS ? ERROR_BAD_PATHNAME : error;
  }
  if (length >= buffer.size()) {
    return ERROR_INSUFFICIENT_BUFFER;
  }
  std::error_code path_error;
  const std::filesystem::path canonical = std::filesystem::canonical(
      std::filesystem::path(std::wstring(buffer.data(), length)), path_error);
  if (path_error || canonical.empty()) {
    return ERROR_BAD_PATHNAME;
  }
  *path = canonical.native();
  return ERROR_SUCCESS;
}

LSTATUS ReadLaunchAtLoginCommand(HKEY key, bool* exists,
                                 std::wstring* command) {
  if (key == nullptr || exists == nullptr || command == nullptr) {
    return ERROR_INVALID_PARAMETER;
  }
  *exists = false;
  command->clear();
  DWORD type = 0;
  DWORD byte_count = 0;
  LSTATUS status = RegQueryValueExW(key, kRunValueName, nullptr, &type,
                                    nullptr, &byte_count);
  if (status == ERROR_FILE_NOT_FOUND) {
    return ERROR_SUCCESS;
  }
  if (status != ERROR_SUCCESS) {
    return status;
  }
  *exists = true;
  if (type != REG_SZ || byte_count == 0 ||
      byte_count % sizeof(wchar_t) != 0 ||
      byte_count > 32768 * sizeof(wchar_t)) {
    return ERROR_INVALID_DATA;
  }
  std::vector<wchar_t> value(byte_count / sizeof(wchar_t) + 1, L'\0');
  DWORD loaded_type = 0;
  DWORD loaded_bytes = byte_count;
  status = RegQueryValueExW(
      key, kRunValueName, nullptr, &loaded_type,
      reinterpret_cast<BYTE*>(value.data()), &loaded_bytes);
  if (status != ERROR_SUCCESS) {
    return status;
  }
  if (loaded_type != REG_SZ || loaded_bytes == 0 ||
      loaded_bytes % sizeof(wchar_t) != 0) {
    return ERROR_INVALID_DATA;
  }
  command->assign(value.data(), loaded_bytes / sizeof(wchar_t));
  if (!command->empty() && command->back() == L'\0') {
    command->pop_back();
  }
  return ERROR_SUCCESS;
}

LSTATUS QueryLaunchAtLogin(bool* enabled) {
  if (enabled == nullptr) {
    return ERROR_INVALID_PARAMETER;
  }
  *enabled = false;
  std::wstring executable_path;
  const LSTATUS path_status = CanonicalExecutablePath(&executable_path);
  if (path_status != ERROR_SUCCESS) {
    return path_status;
  }

  HKEY key = nullptr;
  LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, kRunRegistryPath, 0,
                                 KEY_QUERY_VALUE, &key);
  if (status == ERROR_FILE_NOT_FOUND) {
    return ERROR_SUCCESS;
  }
  if (status != ERROR_SUCCESS) {
    return status;
  }

  bool exists = false;
  std::wstring command;
  status = ReadLaunchAtLoginCommand(key, &exists, &command);
  RegCloseKey(key);
  if (status == ERROR_INVALID_DATA) {
    return ERROR_SUCCESS;
  }
  if (status != ERROR_SUCCESS) {
    return status;
  }
  *enabled = exists &&
             IsExpectedLaunchAtLoginCommand(command, executable_path);
  return ERROR_SUCCESS;
}

LSTATUS SetLaunchAtLogin(bool enabled) {
  if (!enabled) {
    HKEY key = nullptr;
    LSTATUS status = RegOpenKeyExW(HKEY_CURRENT_USER, kRunRegistryPath, 0,
                                   KEY_QUERY_VALUE | KEY_SET_VALUE, &key);
    if (status == ERROR_FILE_NOT_FOUND) {
      return ERROR_SUCCESS;
    }
    if (status != ERROR_SUCCESS) {
      return status;
    }
    bool exists = false;
    std::wstring command;
    status = ReadLaunchAtLoginCommand(key, &exists, &command);
    if (status == ERROR_INVALID_DATA) {
      RegCloseKey(key);
      return ERROR_REVISION_MISMATCH;
    }
    if (status != ERROR_SUCCESS || !exists) {
      RegCloseKey(key);
      return status;
    }
    std::wstring executable_path;
    status = CanonicalExecutablePath(&executable_path);
    if (status != ERROR_SUCCESS) {
      RegCloseKey(key);
      return status;
    }
    const LaunchAtLoginRemovalDecision decision = DecideLaunchAtLoginRemoval(
        true, command, executable_path);
    if (decision == LaunchAtLoginRemovalDecision::kConflict) {
      RegCloseKey(key);
      return ERROR_REVISION_MISMATCH;
    }
    if (decision == LaunchAtLoginRemovalDecision::kAlreadyAbsent) {
      RegCloseKey(key);
      return ERROR_SUCCESS;
    }
    status = RegDeleteValueW(key, kRunValueName);
    RegCloseKey(key);
    return status == ERROR_FILE_NOT_FOUND ? ERROR_SUCCESS : status;
  }

  std::wstring executable_path;
  LSTATUS status = CanonicalExecutablePath(&executable_path);
  if (status != ERROR_SUCCESS) {
    return status;
  }
  const std::wstring command = BuildLaunchAtLoginCommand(executable_path);
  if (command.empty()) {
    return ERROR_INVALID_DATA;
  }
  HKEY key = nullptr;
  status = RegCreateKeyExW(HKEY_CURRENT_USER, kRunRegistryPath, 0, nullptr, 0,
                           KEY_QUERY_VALUE | KEY_SET_VALUE, nullptr, &key,
                           nullptr);
  if (status != ERROR_SUCCESS) {
    return status;
  }
  bool exists = false;
  std::wstring current_command;
  status = ReadLaunchAtLoginCommand(key, &exists, &current_command);
  if (status == ERROR_INVALID_DATA) {
    RegCloseKey(key);
    return ERROR_REVISION_MISMATCH;
  }
  if (status != ERROR_SUCCESS) {
    RegCloseKey(key);
    return status;
  }
  const LaunchAtLoginWriteDecision decision = DecideLaunchAtLoginWrite(
      exists, current_command, executable_path);
  if (decision == LaunchAtLoginWriteDecision::kConflict) {
    RegCloseKey(key);
    return ERROR_REVISION_MISMATCH;
  }
  if (decision == LaunchAtLoginWriteDecision::kAlreadyExpected) {
    RegCloseKey(key);
    return ERROR_SUCCESS;
  }
  const DWORD bytes =
      static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t));
  status = RegSetValueExW(key, kRunValueName, 0, REG_SZ,
                          reinterpret_cast<const BYTE*>(command.c_str()), bytes);
  RegCloseKey(key);
  return status;
}

bool ValidateExecutablePath(const std::string& utf8_path,
                            std::filesystem::path* canonical_path,
                            std::string* error) {
  if (canonical_path == nullptr || utf8_path.empty()) {
    if (error != nullptr) *error = "Executable path is required";
    return false;
  }
  const std::filesystem::path input(WideFromUtf8(utf8_path));
  if (input.empty() || !input.is_absolute()) {
    if (error != nullptr) *error = "Executable path must be absolute";
    return false;
  }
  std::wstring extension = input.extension().wstring();
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](wchar_t value) {
                   return static_cast<wchar_t>(std::towlower(value));
                 });
  if (extension != L".exe" && extension != L".com") {
    if (error != nullptr) *error = "Unsupported executable extension";
    return false;
  }
  std::error_code path_error;
  const std::filesystem::path resolved =
      std::filesystem::canonical(input, path_error);
  if (path_error || resolved.empty() ||
      !std::filesystem::is_regular_file(resolved, path_error) || path_error) {
    if (error != nullptr) *error = "Executable file does not exist";
    return false;
  }
  *canonical_path = resolved;
  return true;
}

bool EncodeIconAsPng(HICON icon, uint32_t size,
                     std::vector<uint8_t>* png_bytes, std::string* error) {
  if (icon == nullptr || png_bytes == nullptr ||
      (size != 32 && size != 48)) {
    if (error != nullptr) *error = "Icon encoding arguments are invalid";
    return false;
  }
  ComPtr<IWICImagingFactory> factory;
  HRESULT result = CoCreateInstance(
      CLSID_WICImagingFactory2, nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(factory.GetAddressOf()));
  if (FAILED(result)) {
    result = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(factory.GetAddressOf()));
  }
  ComPtr<IWICBitmap> bitmap;
  if (SUCCEEDED(result)) {
    result = factory->CreateBitmapFromHICON(icon, bitmap.GetAddressOf());
  }
  ComPtr<IWICBitmapScaler> scaler;
  if (SUCCEEDED(result)) {
    result = factory->CreateBitmapScaler(scaler.GetAddressOf());
  }
  if (SUCCEEDED(result)) {
    result = scaler->Initialize(bitmap.Get(), size, size,
                                WICBitmapInterpolationModeFant);
  }
  ComPtr<IStream> stream;
  if (SUCCEEDED(result)) {
    result = CreateStreamOnHGlobal(nullptr, TRUE, stream.GetAddressOf());
  }
  ComPtr<IWICBitmapEncoder> encoder;
  if (SUCCEEDED(result)) {
    result = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                    encoder.GetAddressOf());
  }
  if (SUCCEEDED(result)) {
    result = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  }
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> properties;
  if (SUCCEEDED(result)) {
    result = encoder->CreateNewFrame(frame.GetAddressOf(),
                                     properties.GetAddressOf());
  }
  if (SUCCEEDED(result)) result = frame->Initialize(properties.Get());
  if (SUCCEEDED(result)) result = frame->SetSize(size, size);
  WICPixelFormatGUID pixel_format = GUID_WICPixelFormat32bppBGRA;
  if (SUCCEEDED(result)) result = frame->SetPixelFormat(&pixel_format);
  if (SUCCEEDED(result)) result = frame->WriteSource(scaler.Get(), nullptr);
  if (SUCCEEDED(result)) result = frame->Commit();
  if (SUCCEEDED(result)) result = encoder->Commit();

  HGLOBAL memory = nullptr;
  if (SUCCEEDED(result)) {
    result = GetHGlobalFromStream(stream.Get(), &memory);
  }
  const SIZE_T byte_count = memory == nullptr ? 0 : GlobalSize(memory);
  const void* data = memory == nullptr ? nullptr : GlobalLock(memory);
  if (FAILED(result) || data == nullptr || byte_count == 0 ||
      byte_count > 2 * 1024 * 1024) {
    if (data != nullptr) GlobalUnlock(memory);
    if (error != nullptr) *error = "Failed to encode executable icon";
    return false;
  }
  const auto* begin = static_cast<const uint8_t*>(data);
  png_bytes->assign(begin, begin + byte_count);
  GlobalUnlock(memory);
  return true;
}

bool LoadExecutableIcon(const std::filesystem::path& executable_path,
                        uint32_t size, std::vector<uint8_t>* png_bytes,
                        std::string* error) {
  SHFILEINFOW file_info{};
  const UINT flags = SHGFI_ICON | SHGFI_LARGEICON;
  if (SHGetFileInfoW(executable_path.c_str(), 0, &file_info,
                     sizeof(file_info), flags) == 0 ||
      file_info.hIcon == nullptr) {
    if (error != nullptr) *error = "Windows did not return a file icon";
    return false;
  }
  const bool encoded = EncodeIconAsPng(file_info.hIcon, size, png_bytes, error);
  DestroyIcon(file_info.hIcon);
  return encoded;
}

int64_t CurrentTimeMillis() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

void Put(EncodableMap* map, const char* key, EncodableValue value) {
  map->insert_or_assign(EncodableValue(key), std::move(value));
}

const EncodableMap* AsMap(const EncodableValue* value) {
  if (value == nullptr || !std::holds_alternative<EncodableMap>(*value)) {
    return nullptr;
  }
  return &std::get<EncodableMap>(*value);
}

const EncodableValue* Find(const EncodableMap* map, const char* key) {
  if (map == nullptr) {
    return nullptr;
  }
  const auto iterator = map->find(EncodableValue(key));
  return iterator == map->end() ? nullptr : &iterator->second;
}

const EncodableValue* FindAny(const EncodableMap* map,
                              std::initializer_list<const char*> keys) {
  for (const char* key : keys) {
    const EncodableValue* value = Find(map, key);
    if (value != nullptr && !value->IsNull()) {
      return value;
    }
  }
  return nullptr;
}

std::string StringValue(const EncodableMap* map,
                        std::initializer_list<const char*> keys,
                        const std::string& fallback = {}) {
  const EncodableValue* value = FindAny(map, keys);
  if (value != nullptr && std::holds_alternative<std::string>(*value)) {
    return std::get<std::string>(*value);
  }
  return fallback;
}

int64_t IntegerValue(const EncodableMap* map,
                     std::initializer_list<const char*> keys,
                     int64_t fallback) {
  const EncodableValue* value = FindAny(map, keys);
  if (value == nullptr) {
    return fallback;
  }
  const std::optional<int64_t> integer = value->TryGetLongValue();
  if (integer.has_value()) {
    return integer.value();
  }
  if (std::holds_alternative<double>(*value)) {
    return static_cast<int64_t>(std::get<double>(*value));
  }
  return fallback;
}

std::optional<int64_t> ExactIntegerValue(const EncodableMap* map,
                                         const char* key) {
  const EncodableValue* value = Find(map, key);
  if (value == nullptr || value->IsNull()) {
    return std::nullopt;
  }
  if (std::holds_alternative<int32_t>(*value)) {
    return std::get<int32_t>(*value);
  }
  if (std::holds_alternative<int64_t>(*value)) {
    return std::get<int64_t>(*value);
  }
  return std::nullopt;
}

bool BoolValue(const EncodableMap* map,
               std::initializer_list<const char*> keys,
               bool fallback) {
  const EncodableValue* value = FindAny(map, keys);
  if (value != nullptr && std::holds_alternative<bool>(*value)) {
    return std::get<bool>(*value);
  }
  return fallback;
}

int32_t Int32Clamped(int64_t value, int32_t minimum, int32_t maximum) {
  return static_cast<int32_t>(std::clamp<int64_t>(value, minimum, maximum));
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

std::filesystem::path PathFromUtf8(const std::string& value) {
  return std::filesystem::path(WideFromUtf8(value));
}

std::wstring DefaultDataDirectory() {
  PWSTR local_app_data = nullptr;
  std::wstring result;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                     nullptr, &local_app_data)) &&
      local_app_data != nullptr) {
    result = local_app_data;
    CoTaskMemFree(local_app_data);
  } else {
    wchar_t fallback[MAX_PATH] = {};
    const DWORD length = GetEnvironmentVariableW(
        L"LOCALAPPDATA", fallback, static_cast<DWORD>(std::size(fallback)));
    if (length > 0 && length < std::size(fallback)) {
      result.assign(fallback, length);
    }
  }
  if (result.empty()) {
    result = L".";
  }
  std::filesystem::path path(result);
  path /= L"QiDayFlow";
  std::error_code error;
  std::filesystem::create_directories(path, error);
  return path.wstring();
}

std::string NewSessionId() {
  std::ostringstream result;
  result << CurrentTimeMillis() << '_' << GetCurrentProcessId();
  return result.str();
}

std::string NormalizedState(CaptureState state) {
  switch (state) {
    case CaptureState::kStarting:
      return "starting";
    case CaptureState::kRecording:
      return "capturing";
    case CaptureState::kSystemPaused:
    case CaptureState::kManualPaused:
    case CaptureState::kIdlePaused:
      return "paused";
    case CaptureState::kStopping:
      return "stopping";
    case CaptureState::kError:
      return "error";
    case CaptureState::kStopped:
    default:
      return "stopped";
  }
}

EncodableMap StateMap(CaptureState state,
                      const std::string& reason,
                      const std::string& session_id) {
  EncodableMap map;
  Put(&map, "type", EncodableValue("state"));
  Put(&map, "state", EncodableValue(NormalizedState(state)));
  Put(&map, "sessionId", EncodableValue(session_id));
  Put(&map, "reason", EncodableValue(reason));
  Put(&map, "idleSeconds",
      EncodableValue(static_cast<int64_t>(
          CaptureService::GetIdleMilliseconds() / 1000ULL)));
  Put(&map, "timestampMs", EncodableValue(CurrentTimeMillis()));
  return map;
}

EncodableMap WindowMap(const WindowRecord& record) {
  EncodableMap map;
  Put(&map, "timestampMs", EncodableValue(record.timestamp_ms));
  Put(&map, "offsetMs", EncodableValue(record.offset_ms));
  Put(&map, "processId",
      EncodableValue(static_cast<int64_t>(record.process_id)));
  Put(&map, "appName", EncodableValue(record.app_name));
  Put(&map, "processName", EncodableValue(record.process_name));
  Put(&map, "processPath", EncodableValue(record.process_path));
  Put(&map, "windowTitle", EncodableValue(record.window_title));
  if (record.cpu_usage_percent.has_value()) {
    Put(&map, "cpuUsagePercent",
        EncodableValue(*record.cpu_usage_percent));
  } else {
    Put(&map, "cpuUsagePercent", EncodableValue());
  }
  if (record.memory_commit_bytes.has_value()) {
    Put(&map, "memoryCommitBytes",
        EncodableValue(
            static_cast<int64_t>(*record.memory_commit_bytes)));
  } else {
    Put(&map, "memoryCommitBytes", EncodableValue());
  }
  return map;
}

EncodableMap SourceChangeMap(const SourceChangeRecord& source) {
  EncodableMap map;
  Put(&map, "timestampMs", EncodableValue(source.timestamp_ms));
  Put(&map, "offsetMs", EncodableValue(source.offset_ms));
  Put(&map, "displayId", EncodableValue(source.display_id));
  Put(&map, "left", EncodableValue(source.left));
  Put(&map, "top", EncodableValue(source.top));
  Put(&map, "width", EncodableValue(source.width));
  Put(&map, "height", EncodableValue(source.height));
  return map;
}

EncodableMap DisplayMap(const DisplayInfo& display) {
  EncodableMap map;
  Put(&map, "index", EncodableValue(display.index));
  Put(&map, "id", EncodableValue(display.id));
  Put(&map, "name", EncodableValue(display.name));
  Put(&map, "adapterName", EncodableValue(display.adapter_name));
  Put(&map, "left", EncodableValue(display.left));
  Put(&map, "top", EncodableValue(display.top));
  Put(&map, "width", EncodableValue(display.width));
  Put(&map, "height", EncodableValue(display.height));
  Put(&map, "rotation", EncodableValue(display.rotation));
  Put(&map, "isPrimary", EncodableValue(display.is_primary));
  return map;
}

EncodableMap ChunkMap(const CaptureEvent& event) {
  const ChunkResult& chunk = event.chunk;
  EncodableMap map;
  Put(&map, "type", EncodableValue("chunkCompleted"));
  Put(&map, "sessionId", EncodableValue(chunk.session_id));
  Put(&map, "chunkId", EncodableValue(chunk.chunk_id));
  Put(&map, "schemaVersion", EncodableValue(4));
  Put(&map, "captureScope", EncodableValue("active-window-display"));
  Put(&map, "captureIntervalSeconds",
      EncodableValue(static_cast<int64_t>(
          chunk.capture_interval_seconds)));
  Put(&map, "directoryPath", EncodableValue(chunk.directory_path));
  Put(&map, "videoPath", EncodableValue(chunk.video_path));
  Put(&map, "metadataPath", EncodableValue(chunk.metadata_path));
  Put(&map, "startTimeMs", EncodableValue(chunk.start_time_ms));
  Put(&map, "endTimeMs", EncodableValue(chunk.end_time_ms));
  Put(&map, "durationMs", EncodableValue(chunk.duration_ms));
  Put(&map, "frameCount",
      EncodableValue(static_cast<int64_t>(chunk.video_frame_count)));
  Put(&map, "videoWidth",
      EncodableValue(static_cast<int64_t>(chunk.video_width)));
  Put(&map, "videoHeight",
      EncodableValue(static_cast<int64_t>(chunk.video_height)));
  Put(&map, "videoFrameRateNumerator",
      EncodableValue(static_cast<int64_t>(
          chunk.video_frame_rate_numerator)));
  Put(&map, "videoFrameRateDenominator",
      EncodableValue(static_cast<int64_t>(
          chunk.video_frame_rate_denominator)));
  Put(&map, "videoFrameDurationTicks",
      EncodableValue(chunk.video_frame_duration_ticks));

  EncodableMap virtual_desktop;
  Put(&virtual_desktop, "left", EncodableValue(chunk.virtual_left));
  Put(&virtual_desktop, "top", EncodableValue(chunk.virtual_top));
  Put(&virtual_desktop, "width", EncodableValue(chunk.virtual_width));
  Put(&virtual_desktop, "height", EncodableValue(chunk.virtual_height));
  Put(&map, "virtualDesktop",
      EncodableValue(std::move(virtual_desktop)));

  EncodableList displays;
  displays.reserve(chunk.displays.size());
  for (const DisplayInfo& display : chunk.displays) {
    displays.emplace_back(DisplayMap(display));
  }
  Put(&map, "displays", EncodableValue(std::move(displays)));

  EncodableList source_changes;
  source_changes.reserve(chunk.source_changes.size());
  for (const SourceChangeRecord& source : chunk.source_changes) {
    source_changes.emplace_back(SourceChangeMap(source));
  }
  Put(&map, "sourceChanges", EncodableValue(std::move(source_changes)));

  EncodableList window_records;
  window_records.reserve(chunk.window_records.size());
  for (const WindowRecord& record : chunk.window_records) {
    window_records.emplace_back(WindowMap(record));
  }
  Put(&map, "windowRecords", EncodableValue(std::move(window_records)));

  EncodableMap counts;
  Put(&counts, "capturedFrames",
      EncodableValue(static_cast<int64_t>(chunk.video_frame_count)));
  Put(&map, "counts", EncodableValue(std::move(counts)));
  return map;
}

EncodableMap ExtractedFrameMap(ExtractedVideoFrame frame) {
  EncodableMap map;
  Put(&map, "offsetMs", EncodableValue(frame.offset_ms));
  Put(&map, "jpegBytes", EncodableValue(std::move(frame.jpeg_bytes)));
  return map;
}

bool Base64Encode(const std::vector<uint8_t>& bytes, std::string* output) {
  if (output == nullptr || bytes.size() > std::numeric_limits<DWORD>::max()) {
    return false;
  }
  DWORD character_count = 0;
  const BYTE* data = bytes.empty() ? nullptr : bytes.data();
  if (!CryptBinaryToStringA(data, static_cast<DWORD>(bytes.size()),
                            CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                            nullptr, &character_count)) {
    return false;
  }
  std::string encoded(character_count, '\0');
  if (!CryptBinaryToStringA(data, static_cast<DWORD>(bytes.size()),
                            CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                            encoded.data(), &character_count)) {
    return false;
  }
  while (!encoded.empty() && encoded.back() == '\0') {
    encoded.pop_back();
  }
  *output = std::move(encoded);
  return true;
}

bool Base64Decode(const std::string& encoded, std::vector<uint8_t>* output) {
  if (output == nullptr || encoded.empty() ||
      encoded.size() > std::numeric_limits<DWORD>::max()) {
    return false;
  }
  DWORD byte_count = 0;
  if (!CryptStringToBinaryA(encoded.c_str(), static_cast<DWORD>(encoded.size()),
                            CRYPT_STRING_BASE64, nullptr, &byte_count, nullptr,
                            nullptr)) {
    return false;
  }
  output->resize(byte_count);
  if (!CryptStringToBinaryA(encoded.c_str(),
                            static_cast<DWORD>(encoded.size()),
                            CRYPT_STRING_BASE64, output->data(), &byte_count,
                            nullptr, nullptr)) {
    output->clear();
    return false;
  }
  output->resize(byte_count);
  return true;
}

bool ProtectBytes(const std::vector<uint8_t>& plaintext,
                  std::vector<uint8_t>* ciphertext,
                  std::string* error) {
  if (ciphertext == nullptr || error == nullptr ||
      plaintext.size() > std::numeric_limits<DWORD>::max()) {
    return false;
  }
  DATA_BLOB input = {};
  input.cbData = static_cast<DWORD>(plaintext.size());
  input.pbData =
      plaintext.empty() ? nullptr : const_cast<BYTE*>(plaintext.data());
  DATA_BLOB entropy = {};
  entropy.cbData = static_cast<DWORD>(sizeof(kEntropy) - 1);
  entropy.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(kEntropy));
  DATA_BLOB output = {};
  if (!CryptProtectData(&input, L"Qi Day Flow API secret", &entropy, nullptr,
                        nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    *error = "Windows DPAPI protect failed: " +
             std::to_string(GetLastError());
    return false;
  }
  ciphertext->assign(output.pbData, output.pbData + output.cbData);
  LocalFree(output.pbData);
  return true;
}

bool UnprotectBytes(const std::vector<uint8_t>& ciphertext,
                    std::vector<uint8_t>* plaintext,
                    std::string* error) {
  if (plaintext == nullptr || error == nullptr || ciphertext.empty() ||
      ciphertext.size() > std::numeric_limits<DWORD>::max()) {
    if (error != nullptr) {
      *error = "DPAPI ciphertext is empty or too large";
    }
    return false;
  }
  DATA_BLOB input = {};
  input.cbData = static_cast<DWORD>(ciphertext.size());
  input.pbData = const_cast<BYTE*>(ciphertext.data());
  DATA_BLOB entropy = {};
  entropy.cbData = static_cast<DWORD>(sizeof(kEntropy) - 1);
  entropy.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(kEntropy));
  DATA_BLOB output = {};
  LPWSTR description = nullptr;
  if (!CryptUnprotectData(&input, &description, &entropy, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    *error = "Windows DPAPI unprotect failed: " +
             std::to_string(GetLastError());
    return false;
  }
  if (output.cbData == 0) {
    plaintext->clear();
  } else {
    plaintext->assign(output.pbData, output.pbData + output.cbData);
    SecureZeroMemory(output.pbData, output.cbData);
  }
  if (description != nullptr) {
    LocalFree(description);
  }
  LocalFree(output.pbData);
  return true;
}

struct SecretInput {
  std::vector<uint8_t> bytes;
  bool return_bytes = false;
};

bool ReadSecretInput(const EncodableValue* arguments,
                     bool decrypting,
                     SecretInput* input,
                     std::string* error) {
  if (arguments == nullptr || input == nullptr || error == nullptr) {
    return false;
  }
  const EncodableValue* value = arguments;
  const EncodableMap* map = AsMap(arguments);
  if (map != nullptr) {
    value = decrypting
                ? FindAny(map, {"protectedData", "ciphertext", "data"})
                : FindAny(map, {"plaintext", "data"});
  }
  if (value == nullptr) {
    *error = "Secret value is missing";
    return false;
  }
  if (std::holds_alternative<std::vector<uint8_t>>(*value)) {
    input->bytes = std::get<std::vector<uint8_t>>(*value);
    input->return_bytes = true;
    return true;
  }
  if (!std::holds_alternative<std::string>(*value)) {
    *error = "Secret value must be a string or byte array";
    return false;
  }
  const std::string& text = std::get<std::string>(*value);
  if (decrypting) {
    if (!Base64Decode(text, &input->bytes)) {
      *error = "DPAPI ciphertext is not valid Base64";
      return false;
    }
  } else {
    input->bytes.assign(text.begin(), text.end());
  }
  return true;
}

void ReturnSecret(std::unique_ptr<MethodResult> result,
                  const SecretInput& input,
                  std::vector<uint8_t> bytes,
                  bool decrypting) {
  if (input.return_bytes) {
    result->Success(EncodableValue(std::move(bytes)));
    return;
  }
  std::string text;
  if (decrypting) {
    text.assign(bytes.begin(), bytes.end());
    if (!bytes.empty()) {
      SecureZeroMemory(bytes.data(), bytes.size());
    }
  } else if (!Base64Encode(bytes, &text)) {
    result->Error("dpapi_encoding_failed", "Unable to encode DPAPI output");
    return;
  }
  result->Success(EncodableValue(std::move(text)));
}

HRESULT PickDirectory(HWND owner,
                      const std::wstring& initial_directory,
                      std::wstring* selected_path) {
  if (selected_path == nullptr) {
    return E_POINTER;
  }
  selected_path->clear();
  ComPtr<IFileOpenDialog> dialog;
  HRESULT result = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(dialog.GetAddressOf()));
  if (FAILED(result)) {
    return result;
  }
  DWORD options = 0;
  result = dialog->GetOptions(&options);
  if (FAILED(result)) {
    return result;
  }
  result = dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                              FOS_PATHMUSTEXIST | FOS_DONTADDTORECENT);
  if (FAILED(result)) {
    return result;
  }
  static_cast<void>(dialog->SetTitle(L"Select Qi Day Flow capture folder"));

  if (!initial_directory.empty()) {
    ComPtr<IShellItem> initial_item;
    if (SUCCEEDED(SHCreateItemFromParsingName(
            initial_directory.c_str(), nullptr,
            IID_PPV_ARGS(initial_item.GetAddressOf())))) {
      static_cast<void>(dialog->SetFolder(initial_item.Get()));
    }
  }

  result = dialog->Show(owner);
  if (FAILED(result)) {
    return result;
  }
  ComPtr<IShellItem> item;
  result = dialog->GetResult(item.GetAddressOf());
  if (FAILED(result)) {
    return result;
  }
  PWSTR path = nullptr;
  result = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
  if (FAILED(result) || path == nullptr) {
    return FAILED(result) ? result : E_FAIL;
  }
  *selected_path = path;
  CoTaskMemFree(path);
  return S_OK;
}

HRESULT PickMarkdownSavePath(HWND owner,
                             const std::wstring& suggested_file_name,
                             std::wstring* selected_path) {
  if (selected_path == nullptr) {
    return E_POINTER;
  }
  selected_path->clear();
  ComPtr<IFileSaveDialog> dialog;
  HRESULT result = CoCreateInstance(CLSID_FileSaveDialog, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(dialog.GetAddressOf()));
  if (FAILED(result)) {
    return result;
  }
  DWORD options = 0;
  result = dialog->GetOptions(&options);
  if (FAILED(result)) {
    return result;
  }
  result = dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST |
                              FOS_OVERWRITEPROMPT | FOS_DONTADDTORECENT);
  if (FAILED(result)) {
    return result;
  }
  const COMDLG_FILTERSPEC filters[] = {
      {L"Markdown files", L"*.md"},
      {L"All files", L"*.*"},
  };
  result = dialog->SetFileTypes(static_cast<UINT>(std::size(filters)), filters);
  if (FAILED(result)) {
    return result;
  }
  static_cast<void>(dialog->SetFileTypeIndex(1));
  static_cast<void>(dialog->SetDefaultExtension(L"md"));
  static_cast<void>(dialog->SetTitle(L"Export Qi Day Flow daily report"));
  static_cast<void>(dialog->SetFileName(suggested_file_name.c_str()));

  result = dialog->Show(owner);
  if (FAILED(result)) {
    return result;
  }
  ComPtr<IShellItem> item;
  result = dialog->GetResult(item.GetAddressOf());
  if (FAILED(result)) {
    return result;
  }
  PWSTR path = nullptr;
  result = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
  if (FAILED(result) || path == nullptr) {
    return FAILED(result) ? result : E_FAIL;
  }
  *selected_path = path;
  CoTaskMemFree(path);
  return S_OK;
}

bool IsSafeMarkdownFileName(const std::wstring& file_name) {
  if (file_name.empty() || file_name.size() > 120 || file_name == L"." ||
      file_name == L".." || file_name.find_first_of(L"<>:\"/\\|?*") !=
                                   std::wstring::npos) {
    return false;
  }
  for (const wchar_t character : file_name) {
    if (character < 0x20) {
      return false;
    }
  }
  if (file_name.size() < 3) {
    return false;
  }
  std::wstring extension = file_name.substr(file_name.size() - 3);
  std::transform(extension.begin(), extension.end(), extension.begin(), towlower);
  return extension == L".md";
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

bool PathsEqual(const std::filesystem::path& left,
                const std::filesystem::path& right) {
  return _wcsicmp(left.c_str(), right.c_str()) == 0;
}

bool HasExtension(const std::filesystem::path& path,
                  const wchar_t* extension) {
  return _wcsicmp(path.extension().c_str(), extension) == 0;
}

bool DeleteChunkArtifacts(const EncodableMap* arguments, std::string* error) {
  if (arguments == nullptr || error == nullptr) {
    return false;
  }
  const std::string root_value = StringValue(arguments, {"captureRoot"});
  const std::string directory_value =
      StringValue(arguments, {"directoryPath"});
  if (root_value.empty() || directory_value.empty()) {
    *error = "captureRoot and directoryPath are required";
    return false;
  }
  std::error_code filesystem_error;
  const std::filesystem::path root = std::filesystem::weakly_canonical(
      PathFromUtf8(root_value), filesystem_error);
  if (filesystem_error || root.empty() ||
      !std::filesystem::is_directory(root, filesystem_error)) {
    *error = "captureRoot is not an accessible directory";
    return false;
  }
  const std::filesystem::path directory = std::filesystem::weakly_canonical(
      PathFromUtf8(directory_value), filesystem_error);
  const bool flat_layout = !filesystem_error && PathsEqual(root, directory);
  if (filesystem_error || directory.empty() ||
      (!flat_layout && !IsPathWithin(root, directory))) {
    *error = "directoryPath must be captureRoot or a directory inside it";
    return false;
  }

  std::vector<std::filesystem::path> artifacts;
  const auto add_artifact = [&](const std::string& value,
                                const wchar_t* expected_extension) -> bool {
    if (value.empty()) {
      return true;
    }
    std::error_code path_error;
    const std::filesystem::path path = std::filesystem::weakly_canonical(
        PathFromUtf8(value), path_error);
    if (path_error || path.empty() || !IsPathWithin(directory, path) ||
        !HasExtension(path, expected_extension) ||
        (flat_layout && !PathsEqual(path.parent_path(), root))) {
      *error = "Every artifact must be inside directoryPath";
      return false;
    }
    path_error.clear();
    if (std::filesystem::exists(path, path_error) &&
        !std::filesystem::is_regular_file(path, path_error)) {
      *error = "Every existing artifact must be a regular file";
      return false;
    }
    if (path_error) {
      *error = path_error.message();
      return false;
    }
    if (std::find_if(artifacts.begin(), artifacts.end(),
                     [&](const std::filesystem::path& existing) {
                       return PathsEqual(existing, path);
                     }) != artifacts.end()) {
      *error = "Artifact paths must be unique";
      return false;
    }
    artifacts.push_back(path);
    return true;
  };

  const std::string video_value = StringValue(arguments, {"videoPath"});
  const std::string metadata_value =
      StringValue(arguments, {"metadataPath", "sidecarPath"});
  if (metadata_value.empty() ||
      !add_artifact(video_value, L".mp4") ||
      !add_artifact(metadata_value, L".json")) {
    return false;
  }
  const std::filesystem::path video_path = PathFromUtf8(video_value);
  const std::filesystem::path metadata_path = PathFromUtf8(metadata_value);
  if (flat_layout &&
      (video_value.empty() ||
       _wcsicmp(video_path.stem().c_str(), metadata_path.stem().c_str()) != 0 ||
       _wcsnicmp(video_path.filename().c_str(), L"chunk_", 6) != 0)) {
    *error = "Flat MP4 and JSON artifacts must be a matching chunk pair";
    return false;
  }
  const EncodableValue* frame_paths_value = Find(arguments, "framePaths");
  if (frame_paths_value != nullptr && !frame_paths_value->IsNull()) {
    if (!std::holds_alternative<EncodableList>(*frame_paths_value)) {
      *error = "framePaths must be a list";
      return false;
    }
    for (const EncodableValue& frame_path :
         std::get<EncodableList>(*frame_paths_value)) {
      if (flat_layout) {
        *error = "Flat MP4 chunks cannot contain persisted frame files";
        return false;
      }
      if (!std::holds_alternative<std::string>(frame_path)) {
        if (error->empty()) {
          *error = "framePaths must contain strings";
        }
        return false;
      }
      const std::string value = std::get<std::string>(frame_path);
      const std::filesystem::path path = PathFromUtf8(value);
      if ((!HasExtension(path, L".jpg") && !HasExtension(path, L".jpeg")) ||
          !add_artifact(value, path.extension().c_str())) {
        if (error->empty()) {
          *error = "framePaths must contain JPEG files";
        }
        return false;
      }
    }
  }

  for (const std::filesystem::path& artifact : artifacts) {
    static_cast<void>(std::filesystem::remove(artifact, filesystem_error));
    if (filesystem_error) {
      *error = filesystem_error.message();
      return false;
    }
  }
  if (!flat_layout) {
    filesystem_error.clear();
    static_cast<void>(std::filesystem::remove(directory, filesystem_error));
    if (filesystem_error) {
      *error = filesystem_error.message();
      return false;
    }
  }
  return true;
}

}  // namespace

NativeBridge::NativeBridge(flutter::BinaryMessenger* messenger,
                           HWND window,
                           std::function<void()> show_window,
                           std::function<void()> hide_window,
                           std::function<void()> request_exit,
                           std::function<void(TrayCaptureState)>
                               update_tray_capture_state)
    : window_(window),
      show_window_(std::move(show_window)),
      hide_window_(std::move(hide_window)),
      request_exit_(std::move(request_exit)),
      update_tray_capture_state_(std::move(update_tray_capture_state)),
      capture_service_([this](CaptureEvent event) {
        HandleCaptureEvent(std::move(event));
      }, &frame_logger_) {
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
  method_channel_ =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, kMethodChannelName, codec);
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<MethodResult> result) {
        HandleMethodCall(call, std::move(result));
      });

  event_channel_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, kEventChannelName, codec);
  event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [this](const EncodableValue*,
                 std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink) {
            event_sink_ = std::move(sink);
            QueueEvent(EncodableValue(StateMap(capture_service_.state(),
                                                "listen",
                                                capture_service_.session_id())));
            return std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>();
          },
          [this](const EncodableValue*) {
            event_sink_.reset();
            return std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>();
          }));
}

NativeBridge::~NativeBridge() {
  Shutdown();
  if (method_channel_) {
    method_channel_->SetMethodCallHandler(nullptr);
  }
  if (event_channel_) {
    event_channel_->SetStreamHandler(nullptr);
  }
}

void NativeBridge::SetSessionLocked(bool locked) {
  capture_service_.SetSessionLocked(locked);
}

void NativeBridge::HandleCaptureEvent(CaptureEvent event) {
  if (event.type == CaptureEvent::Type::kState) {
    QueueEvent(
        EncodableValue(StateMap(event.state, event.reason, event.session_id)));
    return;
  }
  if (event.type == CaptureEvent::Type::kChunkFinalized) {
    QueueEvent(EncodableValue(ChunkMap(event)));
    return;
  }
  EncodableMap error;
  Put(&error, "type", EncodableValue("error"));
  Put(&error, "code", EncodableValue(event.error_code));
  Put(&error, "message", EncodableValue(event.error_message));
  Put(&error, "recoverable", EncodableValue(event.recoverable));
  Put(&error, "hresult", EncodableValue(event.hresult));
  Put(&error, "sessionId", EncodableValue(event.session_id));
  Put(&error, "timestampMs", EncodableValue(event.timestamp_ms));
  QueueEvent(EncodableValue(std::move(error)));
}

void NativeBridge::QueueEvent(EncodableValue event) {
  {
    std::lock_guard<std::mutex> lock(event_mutex_);
    if (shutting_down_) {
      return;
    }
    if (pending_events_.size() >= 256) {
      pending_events_.pop_front();
    }
    pending_events_.push_back(std::move(event));
  }
  if (window_ != nullptr && IsWindow(window_)) {
    static_cast<void>(PostMessageW(window_, kDrainEventsMessage, 0, 0));
  }
}

void NativeBridge::DrainEvents() {
  if (!event_sink_) {
    return;
  }
  std::deque<EncodableValue> events;
  {
    std::lock_guard<std::mutex> lock(event_mutex_);
    events.swap(pending_events_);
  }
  for (const EncodableValue& event : events) {
    event_sink_->Success(event);
  }
}

void NativeBridge::NotifyExitRequested() {
  EncodableMap event;
  Put(&event, "type", EncodableValue("quitRequested"));
  Put(&event, "timestampMs", EncodableValue(CurrentTimeMillis()));
  QueueEvent(EncodableValue(std::move(event)));
}

void NativeBridge::NotifyTrayCommand(TrayCaptureCommand command) {
  EncodableMap event;
  Put(&event, "type", EncodableValue("trayCommand"));
  Put(&event, "command",
      EncodableValue(std::string(TrayCommandValue(command))));
  Put(&event, "timestampMs", EncodableValue(CurrentTimeMillis()));
  QueueEvent(EncodableValue(std::move(event)));
}

void NativeBridge::Shutdown() {
  ShutdownAsync(nullptr);
  if (shutdown_thread_.joinable() &&
      shutdown_thread_.get_id() != std::this_thread::get_id()) {
    shutdown_thread_.join();
  }
}

bool NativeBridge::ShutdownAsync(std::function<void()> completion) {
  bool complete_immediately = false;
  bool already_shutting_down = false;
  {
    std::lock_guard<std::mutex> lock(event_mutex_);
    if (shutting_down_) {
      already_shutting_down = true;
      if (completion) {
        if (shutdown_complete_) {
          complete_immediately = true;
        } else {
          shutdown_completions_.push_back(std::move(completion));
        }
      }
    } else {
      shutting_down_ = true;
      if (completion) {
        shutdown_completions_.push_back(std::move(completion));
      }
      update_tray_capture_state_ = nullptr;
      show_window_ = nullptr;
      hide_window_ = nullptr;
      request_exit_ = nullptr;
      pending_events_.clear();
    }
  }
  if (already_shutting_down) {
    if (complete_immediately) completion();
    return false;
  }
  event_sink_.reset();
  if (method_channel_) {
    method_channel_->SetMethodCallHandler(nullptr);
  }
  if (event_channel_) {
    event_channel_->SetStreamHandler(nullptr);
  }
  shutdown_thread_ = std::thread([this]() {
    capture_service_.Shutdown();
    frame_logger_.Close();
    std::vector<std::function<void()>> completions;
    {
      std::lock_guard<std::mutex> lock(event_mutex_);
      shutdown_complete_ = true;
      completions.swap(shutdown_completions_);
    }
    for (const auto& callback : completions) {
      callback();
    }
  });
  return true;
}

void NativeBridge::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<MethodResult> result) {
  const std::string& method = call.method_name();
  const EncodableMap* arguments = AsMap(call.arguments());

  if (method == "getCapabilities") {
    EncodableMap capabilities;
    Put(&capabilities, "backend",
        EncodableValue("dxgiActiveWindowDisplay"));
    Put(&capabilities, "captureScope",
        EncodableValue("active-window-display"));
    Put(&capabilities, "videoEncoder",
        EncodableValue("mediaFoundationH264"));
    Put(&capabilities, "frameExtractor",
        EncodableValue("mediaFoundationWicMemoryJpeg"));
    Put(&capabilities, "rawPixelsSentToDart", EncodableValue(false));
    Put(&capabilities, "dpapi", EncodableValue(true));
    Put(&capabilities, "foregroundWindowTracking", EncodableValue(true));
    Put(&capabilities, "idleDetection", EncodableValue("GetLastInputInfo"));
    Put(&capabilities, "defaultCaptureIntervalSeconds",
        EncodableValue(static_cast<int32_t>(kDefaultCaptureIntervalSeconds)));
    Put(&capabilities, "defaultFps",
        EncodableValue(kDefaultCaptureFramesPerSecond));
    Put(&capabilities, "defaultChunkDurationSeconds", EncodableValue(60));
    Put(&capabilities, "videoWidth", EncodableValue(1920));
    Put(&capabilities, "videoHeight", EncodableValue(1080));
    Put(&capabilities, "regularChunkFrameCount",
        EncodableValue(static_cast<int32_t>(kDefaultRegularChunkFrameCount)));
    Put(&capabilities, "chunkFormat", EncodableValue("h264-mp4+json"));
    Put(&capabilities, "maximumExtractedFrames", EncodableValue(8));
    result->Success(EncodableValue(std::move(capabilities)));
    return;
  }

  if (method == "configureLogging") {
    if (arguments == nullptr) {
      result->Error("invalid_arguments", "configureLogging requires a map");
      return;
    }
    const std::string level_value = StringValue(arguments, {"level"}, "INFO");
    const NativeLogLevel level =
        level_value == "DEBUG"
            ? NativeLogLevel::kDebug
            : level_value == "INFO"
                  ? NativeLogLevel::kInfo
                  : level_value == "WARNING"
                        ? NativeLogLevel::kWarning
                        : level_value == "ERROR" ? NativeLogLevel::kError
                                                   : NativeLogLevel::kInfo;
    if (level_value != "DEBUG" && level_value != "INFO" &&
        level_value != "WARNING" && level_value != "ERROR") {
      result->Error("invalid_arguments", "Unknown native log level");
      return;
    }
    const std::string directory_value =
        StringValue(arguments, {"logDirectory"});
    const std::filesystem::path directory(WideFromUtf8(directory_value));
    const int64_t max_bytes =
        IntegerValue(arguments, {"maxBytes"}, 1024 * 1024);
    const int64_t max_backups = IntegerValue(arguments, {"maxBackups"}, 3);
    if (directory.empty() || !directory.is_absolute() ||
        max_bytes < 64 * 1024 || max_bytes > 100 * 1024 * 1024 ||
        max_backups < 0 || max_backups > 10) {
      result->Error("invalid_arguments", "Native log configuration is invalid");
      return;
    }
    if (!frame_logger_.Configure(
            {directory, level, static_cast<uint64_t>(max_bytes),
             static_cast<uint32_t>(max_backups)})) {
      result->Error("logging_configuration_failed",
                    "Native logging could not be configured");
      return;
    }
    result->Success(EncodableValue(true));
    return;
  }

  if (method == "closeLogging") {
    frame_logger_.Close();
    result->Success();
    return;
  }

  if (method == "queryLaunchAtLogin") {
    if (call.arguments() != nullptr && !call.arguments()->IsNull()) {
      result->Error("invalid_arguments",
                    "queryLaunchAtLogin does not accept arguments");
      return;
    }
    bool enabled = false;
    const LSTATUS status = QueryLaunchAtLogin(&enabled);
    if (status != ERROR_SUCCESS) {
      result->Error("launch_at_login_query_failed",
                    "The launch-at-login registry value could not be read",
                    EncodableValue(static_cast<int64_t>(status)));
      return;
    }
    result->Success(EncodableValue(enabled));
    return;
  }

  if (method == "queryApplicationVersion") {
    if (call.arguments() != nullptr && !call.arguments()->IsNull()) {
      result->Error("invalid_arguments",
                    "queryApplicationVersion does not accept arguments");
      return;
    }
    result->Success(EncodableValue(std::string(FLUTTER_VERSION)));
    return;
  }

  if (method == "openExternalUrl") {
    const EncodableValue* url_value = Find(arguments, "url");
    if (arguments == nullptr || arguments->size() != 1 ||
        url_value == nullptr ||
        !std::holds_alternative<std::string>(*url_value)) {
      result->Error("invalid_arguments",
                    "openExternalUrl requires one string url field");
      return;
    }
    const std::string& url = std::get<std::string>(*url_value);
    if (url.find('\0') != std::string::npos || url.rfind("https://", 0) != 0) {
      result->Error("invalid_url", "Only HTTPS URLs may be opened");
      return;
    }
    const std::wstring wide_url = WideFromUtf8(url);
    if (wide_url.empty()) {
      result->Error("invalid_url", "URL must be valid non-empty UTF-8");
      return;
    }
    const HINSTANCE shell_result =
        ShellExecuteW(window_, L"open", wide_url.c_str(), nullptr, nullptr,
                      SW_SHOWNORMAL);
    const INT_PTR shell_code = reinterpret_cast<INT_PTR>(shell_result);
    if (shell_code <= 32) {
      result->Error("url_open_failed", "The URL could not be opened",
                    EncodableValue(static_cast<int64_t>(shell_code)));
      return;
    }
    result->Success(EncodableValue(true));
    return;
  }

  if (method == "setLaunchAtLogin") {
    const EncodableValue* enabled_value = Find(arguments, "enabled");
    if (arguments == nullptr || arguments->size() != 1 ||
        enabled_value == nullptr || enabled_value->IsNull() ||
        !std::holds_alternative<bool>(*enabled_value)) {
      result->Error("invalid_arguments",
                    "setLaunchAtLogin requires one boolean enabled field");
      return;
    }
    const LSTATUS status =
        SetLaunchAtLogin(std::get<bool>(*enabled_value));
    if (status != ERROR_SUCCESS) {
      const bool conflict = status == ERROR_REVISION_MISMATCH;
      result->Error(conflict ? "launch_at_login_conflict"
                             : "launch_at_login_update_failed",
                    conflict
                        ? "The launch-at-login value is owned by another command"
                        : "The launch-at-login registry value could not be updated",
                    EncodableValue(static_cast<int64_t>(status)));
      return;
    }
    result->Success();
    return;
  }

  if (method == "updateTrayCaptureState") {
    TrayCaptureState state = TrayCaptureState::kStopped;
    if (arguments == nullptr ||
        !ParseTrayCaptureState(StringValue(arguments, {"state"}), &state)) {
      result->Error("invalid_arguments", "Unknown tray capture state");
      return;
    }
    if (!update_tray_capture_state_) {
      result->Error("tray_state_unavailable",
                    "Tray capture state is no longer available");
      return;
    }
    update_tray_capture_state_(state);
    result->Success();
    return;
  }

  if (method == "getExecutableIcon" ||
      method == "revealExecutableInExplorer") {
    if (arguments == nullptr) {
      result->Error("invalid_arguments", "Executable path arguments are required");
      return;
    }
    const std::string executable_path =
        StringValue(arguments, {"executablePath"});
    std::filesystem::path canonical_path;
    std::string validation_error;
    if (!ValidateExecutablePath(executable_path, &canonical_path,
                                &validation_error)) {
      result->Error("invalid_executable_path", validation_error);
      return;
    }
    if (method == "getExecutableIcon") {
      const int64_t requested_size = IntegerValue(arguments, {"size"}, 32);
      if (requested_size != 32 && requested_size != 48) {
        result->Error("invalid_arguments", "Icon size must be 32 or 48");
        return;
      }
      std::vector<uint8_t> png_bytes;
      std::string icon_error;
      if (!LoadExecutableIcon(canonical_path,
                              static_cast<uint32_t>(requested_size),
                              &png_bytes, &icon_error)) {
        result->Error("icon_extraction_failed", icon_error);
        return;
      }
      result->Success(EncodableValue(std::move(png_bytes)));
      return;
    }

    PIDLIST_ABSOLUTE item = nullptr;
    HRESULT shell_result = SHParseDisplayName(
        canonical_path.c_str(), nullptr, &item, 0, nullptr);
    PIDLIST_ABSOLUTE parent = nullptr;
    if (SUCCEEDED(shell_result) && item != nullptr) {
      parent = ILCloneFull(item);
      if (parent == nullptr || !ILRemoveLastID(parent)) {
        shell_result = E_FAIL;
      }
    }
    if (SUCCEEDED(shell_result) && parent != nullptr) {
      PCUITEMID_CHILD child = ILFindLastID(item);
      shell_result = SHOpenFolderAndSelectItems(parent, 1, &child, 0);
    }
    if (parent != nullptr) ILFree(parent);
    if (item != nullptr) ILFree(item);
    if (FAILED(shell_result)) {
      result->Error("explorer_failed", "Explorer could not select the file");
      return;
    }
    result->Success(EncodableValue(true));
    return;
  }

  if (method == "startCapture") {
    if (arguments == nullptr) {
      result->Error("invalid_arguments", "startCapture requires a map");
      return;
    }
    CaptureConfig config;
    std::string output_directory = StringValue(arguments, {"outputDirectory"});
    if (output_directory.empty()) {
      output_directory = Utf8FromWide(
          (std::filesystem::path(DefaultDataDirectory()) / L"captures")
              .wstring());
    }
    config.output_root = WideFromUtf8(output_directory);
    if (config.output_root.empty()) {
      result->Error("invalid_arguments", "outputDirectory is invalid");
      return;
    }
    config.session_id = StringValue(arguments, {"sessionId"}, NewSessionId());
    if (config.session_id.empty()) {
      config.session_id = NewSessionId();
    }
    const std::optional<int64_t> capture_interval =
        ExactIntegerValue(arguments, "captureIntervalSeconds");
    if (!capture_interval.has_value() || *capture_interval < 0 ||
        *capture_interval > std::numeric_limits<uint32_t>::max() ||
        !IsSupportedCaptureIntervalSeconds(
            static_cast<uint32_t>(*capture_interval))) {
      result->Error(
          "invalid_capture_spec",
          "captureIntervalSeconds must be the integer 1, 10, 20, or 30");
      return;
    }
    config.capture_interval_seconds =
        static_cast<uint32_t>(*capture_interval);
    config.chunk_duration_seconds = Int32Clamped(
        IntegerValue(arguments, {"chunkDurationSeconds"}, 60), 10, 3600);
    config.max_width = static_cast<uint32_t>(Int32Clamped(
        IntegerValue(arguments, {"maxWidth"}, 1920), 320, 7680));
    config.max_height = static_cast<uint32_t>(Int32Clamped(
        IntegerValue(arguments, {"maxHeight"}, 1080), 180, 4320));
    config.idle_pause_enabled =
        BoolValue(arguments, {"idlePauseEnabled"}, true);
    config.idle_timeout_seconds = static_cast<uint32_t>(Int32Clamped(
        IntegerValue(arguments, {"idleTimeoutSeconds"}, 600), 1, 86400));

    if (config.chunk_duration_seconds != 60 ||
        config.max_width != 1920 || config.max_height != 1080) {
      result->Error("invalid_capture_spec",
                    "Capture requires 1920x1080 and 60-second chunks");
      return;
    }

    std::error_code directory_error;
    std::filesystem::create_directories(config.output_root, directory_error);
    if (directory_error) {
      result->Error("output_directory_failed", directory_error.message());
      return;
    }
    std::string error;
    if (!capture_service_.Start(config, &error)) {
      result->Error("capture_start_failed", error);
      return;
    }
    result->Success();
    return;
  }
  if (method == "extractVideoFrames") {
    if (arguments == nullptr) {
      result->Error("invalid_arguments",
                    "extractVideoFrames requires a map");
      return;
    }
    const std::string video_path = StringValue(arguments, {"videoPath"});
    const std::string capture_root = StringValue(arguments, {"captureRoot"});
    VideoFrameExtractionConfig config;
    config.video_path = WideFromUtf8(video_path);
    config.capture_root = WideFromUtf8(capture_root);
    config.expected_frame_count = static_cast<uint32_t>(Int32Clamped(
        IntegerValue(arguments, {"expectedFrameCount"}, 0), 0, 36000));
    config.max_frames = static_cast<uint32_t>(Int32Clamped(
        IntegerValue(arguments, {"maxFrames"}, 8), 1, 8));
    config.max_width = static_cast<uint32_t>(Int32Clamped(
        IntegerValue(arguments, {"maxWidth"}, 1920), 1, 1920));
    config.max_height = static_cast<uint32_t>(Int32Clamped(
        IntegerValue(arguments, {"maxHeight"}, 1080), 1, 1080));
    config.jpeg_quality = static_cast<uint32_t>(Int32Clamped(
        IntegerValue(arguments, {"jpegQuality"}, 85), 25, 95));
    config.max_frame_bytes = static_cast<uint32_t>(Int32Clamped(
        IntegerValue(arguments, {"maxFrameBytes"}, 2 * 1024 * 1024), 1024,
        2 * 1024 * 1024));
    config.max_total_bytes = static_cast<uint32_t>(Int32Clamped(
        IntegerValue(arguments, {"maxTotalBytes"}, 12 * 1024 * 1024),
        1024, 12 * 1024 * 1024));
    if (video_path.empty() || capture_root.empty() ||
        config.max_frame_bytes > config.max_total_bytes) {
      result->Error("invalid_arguments",
                    "Video extraction arguments are invalid");
      return;
    }
    std::vector<ExtractedVideoFrame> frames;
    std::string extraction_error;
    if (!CaptureService::ExtractVideoFrames(config, &frames,
                                            &extraction_error)) {
      result->Error("video_frame_extraction_failed", extraction_error);
      return;
    }
    EncodableList encoded_frames;
    encoded_frames.reserve(frames.size());
    for (ExtractedVideoFrame& frame : frames) {
      encoded_frames.emplace_back(ExtractedFrameMap(std::move(frame)));
    }
    result->Success(EncodableValue(std::move(encoded_frames)));
    return;
  }

  if (method == "pauseCapture") {
    std::string error;
    if (!capture_service_.Pause(&error)) {
      result->Error("capture_pause_failed", error);
      return;
    }
    result->Success();
    return;
  }
  if (method == "resumeCapture") {
    std::string error;
    if (!capture_service_.Resume(&error)) {
      result->Error("capture_resume_failed", error);
      return;
    }
    result->Success();
    return;
  }
  if (method == "stopCapture") {
    if (capture_service_.state() == CaptureState::kStopped) {
      result->Success();
      return;
    }
    std::string error;
    if (!capture_service_.Stop(&error)) {
      result->Error("capture_stop_failed", error);
      return;
    }
    DrainEvents();
    result->Success();
    return;
  }
  if (method == "getCaptureState") {
    result->Success(EncodableValue(StateMap(capture_service_.state(), "query",
                                             capture_service_.session_id())));
    return;
  }

  if (method == "protectSecret") {
    SecretInput input;
    std::string error;
    if (!ReadSecretInput(call.arguments(), false, &input, &error)) {
      result->Error("invalid_secret", error);
      return;
    }
    std::vector<uint8_t> protected_bytes;
    if (!ProtectBytes(input.bytes, &protected_bytes, &error)) {
      result->Error("dpapi_protect_failed", error);
      return;
    }
    if (!input.bytes.empty()) {
      SecureZeroMemory(input.bytes.data(), input.bytes.size());
    }
    ReturnSecret(std::move(result), input, std::move(protected_bytes), false);
    return;
  }
  if (method == "unprotectSecret") {
    SecretInput input;
    std::string error;
    if (!ReadSecretInput(call.arguments(), true, &input, &error)) {
      result->Error("invalid_secret", error);
      return;
    }
    std::vector<uint8_t> plaintext;
    if (!UnprotectBytes(input.bytes, &plaintext, &error)) {
      result->Error("dpapi_unprotect_failed", error);
      return;
    }
    ReturnSecret(std::move(result), input, std::move(plaintext), true);
    return;
  }

  if (method == "selectMarkdownExportPath") {
    if (arguments == nullptr) {
      result->Error("invalid_arguments", "Markdown export arguments are required");
      return;
    }
    const std::string suggested_utf8 =
        StringValue(arguments, {"suggestedFileName"});
    if (suggested_utf8.find('\0') != std::string::npos) {
      result->Error("invalid_markdown_file_name",
                    "Markdown file name must not contain an embedded NUL");
      return;
    }
    const std::wstring suggested_file_name = WideFromUtf8(suggested_utf8);
    if (!IsSafeMarkdownFileName(suggested_file_name)) {
      result->Error("invalid_markdown_file_name",
                    "Markdown file name is invalid");
      return;
    }
    std::wstring selected;
    const HRESULT pick_result =
        PickMarkdownSavePath(window_, suggested_file_name, &selected);
    if (pick_result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
      result->Success(EncodableValue());
    } else if (FAILED(pick_result)) {
      result->Error("markdown_export_picker_failed",
                    "Windows Markdown save dialog failed",
                    EncodableValue(static_cast<int64_t>(pick_result)));
    } else if (!std::filesystem::path(selected).is_absolute() ||
               !IsSafeMarkdownFileName(
                   std::filesystem::path(selected).filename().wstring())) {
      result->Error("invalid_markdown_export_path",
                    "Selected Markdown export path is invalid");
    } else {
      result->Success(EncodableValue(Utf8FromWide(selected)));
    }
    return;
  }
  if (method == "selectDirectory") {
    const std::wstring initial_directory =
        WideFromUtf8(StringValue(arguments, {"initialDirectory"}));
    std::wstring selected;
    const HRESULT pick_result =
        PickDirectory(window_, initial_directory, &selected);
    if (pick_result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
      result->Success(EncodableValue());
    } else if (FAILED(pick_result)) {
      result->Error("directory_picker_failed",
                    "Windows folder picker failed",
                    EncodableValue(static_cast<int64_t>(pick_result)));
    } else {
      result->Success(EncodableValue(Utf8FromWide(selected)));
    }
    return;
  }
  if (method == "openDirectoryInExplorer") {
    const EncodableValue* directory_value = Find(arguments, "directoryPath");
    if (directory_value == nullptr ||
        !std::holds_alternative<std::string>(*directory_value)) {
      result->Error("invalid_arguments",
                    "directoryPath must be a UTF-8 string");
      return;
    }
    const std::string& utf8_path = std::get<std::string>(*directory_value);
    if (utf8_path.find('\0') != std::string::npos) {
      result->Error("invalid_directory_path",
                    "Directory path must not contain an embedded NUL");
      return;
    }
    const std::wstring wide_path = WideFromUtf8(utf8_path);
    const std::filesystem::path input(wide_path);
    if (wide_path.empty()) {
      result->Error("invalid_directory_path",
                    "Directory path must be valid non-empty UTF-8");
      return;
    }
    if (!input.is_absolute()) {
      result->Error("invalid_directory_path",
                    "Directory path must be absolute");
      return;
    }
    std::error_code path_error;
    if (!std::filesystem::exists(input, path_error) || path_error) {
      result->Error("directory_not_found", "Directory path does not exist");
      return;
    }
    const std::filesystem::path canonical_path =
        std::filesystem::canonical(input, path_error);
    if (path_error || canonical_path.empty()) {
      result->Error("directory_canonicalization_failed",
                    "Directory path could not be canonicalized");
      return;
    }
    if (!std::filesystem::is_directory(canonical_path, path_error) ||
        path_error) {
      result->Error("not_a_directory",
                    "Directory path must identify a directory");
      return;
    }
    const HINSTANCE shell_result =
        ShellExecuteW(window_, L"open", canonical_path.c_str(), nullptr,
                      nullptr, SW_SHOWNORMAL);
    const INT_PTR shell_code = reinterpret_cast<INT_PTR>(shell_result);
    if (shell_code <= 32) {
      result->Error("explorer_failed", "Explorer could not open the directory",
                    EncodableValue(static_cast<int64_t>(shell_code)));
      return;
    }
    EncodableMap response;
    Put(&response, "opened", EncodableValue(true));
    result->Success(EncodableValue(std::move(response)));
    return;
  }
  if (method == "getDefaultDataDirectory") {
    result->Success(EncodableValue(Utf8FromWide(DefaultDataDirectory())));
    return;
  }
  if (method == "deleteChunk") {
    std::string error;
    if (!DeleteChunkArtifacts(arguments, &error)) {
      result->Error("chunk_delete_failed", error);
      return;
    }
    EncodableMap response;
    Put(&response, "deleted", EncodableValue(true));
    result->Success(EncodableValue(std::move(response)));
    return;
  }

  if (method == "showWindow") {
    if (show_window_) {
      show_window_();
    }
    result->Success();
    return;
  }
  if (method == "hideWindow") {
    if (hide_window_) {
      hide_window_();
    }
    result->Success();
    return;
  }
  if (method == "quitApplication" || method == "requestExit") {
    result->Success();
    if (request_exit_) {
      request_exit_();
    }
    return;
  }
  if (method == "shutdown") {
    result->Success();
    ShutdownAsync(nullptr);
    return;
  }

  result->NotImplemented();
}

}  // namespace qi_day_flow
