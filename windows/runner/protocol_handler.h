#ifndef RUNNER_PROTOCOL_HANDLER_H_
#define RUNNER_PROTOCOL_HANDLER_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <vector>
#include <string>

/// `spotify:` 链接（浏览器 / 其他程序唤起）与单实例。
///
/// - 启动时把 Flutify 登记为可处理 `spotify:` 的应用（HKCU Capabilities，出现在
///   Windows「默认应用」里）；只有系统里没有可用的处理程序时才直接接管 `spotify:`，
///   不抢官方客户端。用户可在设置里手动设为默认 / 恢复（MethodChannel `flutify/protocol`）。
/// - 已有实例在运行时，把链接经 WM_COPYDATA 转给它并激活窗口，本进程退出。
namespace protocol_handler {

/// 命令行里的 `spotify:` / `open.spotify.com` 链接（没有则为空）。
std::string FindLinkArgument(const std::vector<std::string>& args);

/// 已有实例在运行：把 [link]（可为空，仅激活窗口）转发过去并返回 true，调用方应直接退出。
/// 找不到可转发的窗口时返回 false，照常启动。
bool ForwardToRunningInstance(const std::string& link);

/// 登记处理程序（幂等，每次启动调用；指向当前 exe 路径，移动安装目录后自动更新）。
void RegisterHandler();

/// 标记主窗口，供第二个实例查找。
void MarkMainWindow(HWND hwnd);

/// 主窗口收到的 WM_COPYDATA 若是转发来的链接，返回其内容（可能为空串）。
std::optional<std::string> ReadForwardedLink(UINT message, LPARAM lparam);

/// 把窗口还原并切到前台。
void ActivateWindow(HWND hwnd);

/// `flutify/protocol`：
/// - `initialLink` → 启动参数里的链接（只返回一次）；
/// - `status` → {isDefault, otherHandler}；
/// - `setDefault(bool)` → 设为默认（备份原处理程序）/ 恢复原处理程序。
/// 原生侧收到转发链接时调用 Dart 的 `openLink(String)`。
class ProtocolChannel {
 public:
  ProtocolChannel(flutter::BinaryMessenger* messenger, std::string initial_link);
  void DeliverLink(const std::string& link);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::string initial_link_;
  // Dart 侧取过 initialLink 才算就绪；之前转发来的链接先存着，避免启动中丢失
  bool dart_ready_ = false;
};

}  // namespace protocol_handler

#endif
