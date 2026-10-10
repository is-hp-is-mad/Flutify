#include "system_proxy_windows.h"

#include <windows.h>
#include <winhttp.h>

#include <string>
#include <variant>

// Older SDK headers predate the automatic-proxy session type; value is stable.
#ifndef WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY
#define WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY 4
#endif

namespace {

constexpr DWORD kConfigTtlMs = 30 * 1000;

struct AutoProxyState {
  bool loaded = false;
  DWORD loaded_at = 0;
  bool auto_detect = false;
  std::wstring pac_url;
  HINTERNET session = nullptr;
};

AutoProxyState g_state;

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return std::string();
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                       static_cast<int>(value.size()), nullptr,
                                       0, nullptr, nullptr);
  if (size <= 0) return std::string();
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), result.data(), size,
                      nullptr, nullptr);
  return result;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return std::wstring();
  const int size =
      MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                          static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) return std::wstring();
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}

void RefreshConfig() {
  WINHTTP_CURRENT_USER_IE_PROXY_CONFIG config = {};
  if (WinHttpGetIEProxyConfigForCurrentUser(&config)) {
    g_state.auto_detect = config.fAutoDetect != FALSE;
    g_state.pac_url =
        config.lpszAutoConfigUrl != nullptr ? config.lpszAutoConfigUrl : L"";
    if (config.lpszProxy != nullptr) GlobalFree(config.lpszProxy);
    if (config.lpszProxyBypass != nullptr) GlobalFree(config.lpszProxyBypass);
    if (config.lpszAutoConfigUrl != nullptr) {
      GlobalFree(config.lpszAutoConfigUrl);
    }
  }
  g_state.loaded = true;
  g_state.loaded_at = GetTickCount();
}

bool UsesAutoConfig() {
  if (!g_state.loaded ||
      GetTickCount() - g_state.loaded_at > kConfigTtlMs) {
    RefreshConfig();
  }
  return g_state.auto_detect || !g_state.pac_url.empty();
}

/// 按 URL 求值自动配置；空串表示直连（也用于没有自动配置 / 求值失败）。
std::string ResolveProxy(const std::wstring& url) {
  if (!UsesAutoConfig()) return std::string();
  if (g_state.session == nullptr) {
    g_state.session =
        WinHttpOpen(L"Flutify/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (g_state.session == nullptr) return std::string();
  }
  WINHTTP_AUTOPROXY_OPTIONS options = {};
  if (!g_state.pac_url.empty()) {
    options.dwFlags = WINHTTP_AUTOPROXY_CONFIG_URL;
    options.lpszAutoConfigUrl = g_state.pac_url.c_str();
  } else {
    options.dwFlags = WINHTTP_AUTOPROXY_AUTO_DETECT;
    options.dwAutoDetectFlags =
        WINHTTP_AUTO_DETECT_TYPE_DHCP | WINHTTP_AUTO_DETECT_TYPE_DNS_A;
  }
  WINHTTP_PROXY_INFO info = {};
  std::string result;
  if (WinHttpGetProxyForUrl(g_state.session, url.c_str(), &options, &info) &&
      info.lpszProxy != nullptr) {
    result = WideToUtf8(info.lpszProxy);
  }
  if (info.lpszProxy != nullptr) GlobalFree(info.lpszProxy);
  if (info.lpszProxyBypass != nullptr) GlobalFree(info.lpszProxyBypass);
  return result;
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateSystemProxyChannel(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "flutify/system_proxy",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    const std::string& method = call.method_name();
    if (method == "autoProxyInfo") {
      result->Success(flutter::EncodableValue(UsesAutoConfig()));
      return;
    }
    if (method == "resolveProxyForUrl") {
      const auto* url = std::get_if<std::string>(call.arguments());
      if (url == nullptr) {
        result->Error("bad_args", "Expected a URL string");
        return;
      }
      result->Success(flutter::EncodableValue(ResolveProxy(Utf8ToWide(*url))));
      return;
    }
    result->NotImplemented();
  });
  return channel;
}
