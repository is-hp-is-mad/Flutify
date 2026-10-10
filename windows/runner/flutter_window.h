#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "media_controls.h"
#include "snap_layout.h"
#include "system_proxy_windows.h"
#include "taskbar_lyrics.h"
#include "win32_window.h"
#include "windows_trust_store.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 系统媒体控制（SMTC）。
  std::unique_ptr<MediaControls> media_controls_;

  // Windows 11 分屏布局：自绘最大化按钮的命中测试。
  std::unique_ptr<SnapLayout> snap_layout_;

  // 任务栏歌词（嵌入 Windows 任务栏的歌词窗口）。
  std::unique_ptr<TaskbarLyrics> taskbar_lyrics_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> trust_store_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      system_proxy_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
