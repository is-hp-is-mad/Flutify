#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "media_identity.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Bind the HWND before either plugins or native SMTC create a media session.
  media_identity::RegisterWindow(GetHandle());

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  auto* messenger = flutter_controller_->engine()->messenger();
  trust_store_ = CreateWindowsTrustStoreChannel(messenger);
  system_proxy_ = CreateSystemProxyChannel(messenger);
  media_controls_ = std::make_unique<MediaControls>(GetHandle(), messenger);
  snap_layout_ = std::make_unique<SnapLayout>(GetHandle(), flutter_controller_->view()->GetNativeWindow(), messenger);
  taskbar_lyrics_ = std::make_unique<TaskbarLyrics>(GetHandle(), messenger);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // 先于引擎释放：它们持有引擎的 MethodChannel
  taskbar_lyrics_ = nullptr;
  trust_store_ = nullptr;
  system_proxy_ = nullptr;
  snap_layout_ = nullptr;
  media_controls_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 分屏布局的命中测试须先于插件（window_manager）处理
  if (snap_layout_) {
    if (auto result = snap_layout_->HandleTopLevel(hwnd, message, wparam, lparam)) {
      return *result;
    }
  }
  if (media_controls_ && media_controls_->HandleMessage(message, wparam, lparam)) {
    return 0;
  }
  if (taskbar_lyrics_ && taskbar_lyrics_->HandleMessage(message, wparam, lparam)) {
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
