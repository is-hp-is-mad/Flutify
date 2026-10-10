#ifndef RUNNER_SYSTEM_PROXY_WINDOWS_H_
#define RUNNER_SYSTEM_PROXY_WINDOWS_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

/// Windows 系统代理的自动配置（PAC / 自动检测）解析通道
/// （MethodChannel `flutify/system_proxy`，与 macOS 的通道同名）。
///
/// 静态代理（注册表 ProxyEnable / ProxyServer）由 Dart 侧读取；这里只负责
/// 浏览器 / WebView2 会用、而 Dart 无法执行的自动配置：
/// - `autoProxyInfo`：系统是否启用了 PAC 或自动检测；
/// - `resolveProxyForUrl`：按 URL 用 WinHTTP 求值 PAC / 自动检测，返回
///   `host:port`（可能带 `PROXY` 前缀或多项），空串表示直连。
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateSystemProxyChannel(flutter::BinaryMessenger* messenger);

#endif
