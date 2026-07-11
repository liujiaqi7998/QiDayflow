#ifndef RUNNER_NATIVE_BRIDGE_H_
#define RUNNER_NATIVE_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <deque>
#include <functional>
#include <memory>
#include <mutex>

#include "capture_service.h"
#include "native_frame_logger.h"
#include "tray_menu_state.h"

namespace qi_day_flow {

class NativeBridge {
 public:
  static constexpr UINT kDrainEventsMessage = WM_APP + 0x41;

  NativeBridge(flutter::BinaryMessenger* messenger,
               HWND window,
               std::function<void()> show_window,
               std::function<void()> hide_window,
               std::function<void()> request_exit,
               std::function<void(TrayCaptureState)> update_tray_capture_state);
  ~NativeBridge();

  NativeBridge(const NativeBridge&) = delete;
  NativeBridge& operator=(const NativeBridge&) = delete;

  void DrainEvents();
  void NotifyExitRequested();
  void NotifyTrayCommand(TrayCaptureCommand command);
  void Shutdown();

 private:
  void HandleCaptureEvent(CaptureEvent event);
  void QueueEvent(flutter::EncodableValue event);
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND window_ = nullptr;
  std::function<void()> show_window_;
  std::function<void()> hide_window_;
  std::function<void()> request_exit_;
  std::function<void(TrayCaptureState)> update_tray_capture_state_;
  NativeFrameLogger frame_logger_;
  CaptureService capture_service_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::mutex event_mutex_;
  std::deque<flutter::EncodableValue> pending_events_;
  bool shutting_down_ = false;
};

}  // namespace qi_day_flow

#endif  // RUNNER_NATIVE_BRIDGE_H_
