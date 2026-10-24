#include "protocol_handler.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <algorithm>
#include <cwctype>
#include <vector>

#include "utils.h"

namespace protocol_handler {
namespace {

constexpr wchar_t kMutexName[] = L"Local\\Flutify.SingleInstance";
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kMainWindowProp[] = L"Flutify.MainWindow";
constexpr ULONG_PTR kCopyDataMagic = 0x464C5459;  // 'FLTY'

constexpr wchar_t kProgId[] = L"Flutify.SpotifyURI";
constexpr wchar_t kProgIdKey[] = L"Software\\Classes\\Flutify.SpotifyURI";
constexpr wchar_t kSpotifyKey[] = L"Software\\Classes\\spotify";
constexpr wchar_t kCapabilitiesPath[] = L"Software\\Flutify\\Capabilities";
constexpr wchar_t kStateKey[] = L"Software\\Flutify\\Protocol";
constexpr wchar_t kUserChoiceKey[] =
    L"Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\"
    L"spotify\\UserChoice";
// 备份里表示「接管前 HKCU 没有 spotify 键」（恢复时删掉即可，HKLM 的官方注册重新生效）
constexpr wchar_t kNoPrevious[] = L"<none>";

std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int length = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                           static_cast<int>(utf8.size()),
                                           nullptr, 0);
  if (length <= 0) return std::wstring();
  std::wstring result(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        result.data(), length);
  return result;
}

std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return value;
}

std::wstring ExePath() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length = ::GetModuleFileNameW(
        nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0) return std::wstring();
    if (length < path.size()) {
      path.resize(length);
      return path;
    }
    path.resize(path.size() * 2);
  }
}

std::wstring OpenCommand() { return L"\"" + ExePath() + L"\" \"%1\""; }

std::optional<std::wstring> ReadString(HKEY root, const std::wstring& key,
                                       const wchar_t* value) {
  DWORD size = 0;
  if (::RegGetValueW(root, key.c_str(), value, RRF_RT_REG_SZ, nullptr, nullptr,
                     &size) != ERROR_SUCCESS) {
    return std::nullopt;
  }
  std::wstring data(size / sizeof(wchar_t), L'\0');
  if (::RegGetValueW(root, key.c_str(), value, RRF_RT_REG_SZ, nullptr,
                     data.data(), &size) != ERROR_SUCCESS) {
    return std::nullopt;
  }
  data.resize(wcsnlen(data.c_str(), data.size()));
  return data;
}

bool WriteString(const std::wstring& key, const wchar_t* value,
                 const std::wstring& data) {
  HKEY handle = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &handle,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const auto bytes =
      static_cast<DWORD>((data.size() + 1) * sizeof(wchar_t));
  const bool ok = ::RegSetValueExW(handle, value, 0, REG_SZ,
                                   reinterpret_cast<const BYTE*>(data.c_str()),
                                   bytes) == ERROR_SUCCESS;
  ::RegCloseKey(handle);
  return ok;
}

/// 命令行的可执行文件部分（带引号取引号内，否则取到第一个空格）。
std::wstring CommandExe(const std::wstring& command) {
  if (command.empty()) return std::wstring();
  if (command[0] == L'"') {
    const auto end = command.find(L'"', 1);
    return end == std::wstring::npos ? command.substr(1)
                                     : command.substr(1, end - 1);
  }
  const auto end = command.find(L' ');
  return end == std::wstring::npos ? command : command.substr(0, end);
}

bool IsOurCommand(const std::wstring& command) {
  const auto exe = CommandExe(command);
  return !exe.empty() && Lower(exe) == Lower(ExePath());
}

/// 用户在 Windows「默认应用」里选过的 ProgId（有它时 Classes\spotify 不生效）。
std::optional<std::wstring> UserChoiceProgId() {
  auto prog_id = ReadString(HKEY_CURRENT_USER, kUserChoiceKey, L"ProgId");
  if (!prog_id || prog_id->empty()) return std::nullopt;
  return prog_id;
}

/// 系统点开 `spotify:` 时实际运行的命令（HKCR 是 HKCU 覆盖 HKLM 的合并视图）。
std::wstring EffectiveCommand() {
  if (auto prog_id = UserChoiceProgId()) {
    return ReadString(HKEY_CLASSES_ROOT, *prog_id + L"\\shell\\open\\command",
                      nullptr)
        .value_or(L"");
  }
  return ReadString(HKEY_CLASSES_ROOT, L"spotify\\shell\\open\\command",
                    nullptr)
      .value_or(L"");
}

bool WriteSpotifyClass() {
  const std::wstring key = kSpotifyKey;
  return WriteString(key, nullptr, L"URL:Spotify") &&
         WriteString(key, L"URL Protocol", L"") &&
         WriteString(key + L"\\DefaultIcon", nullptr,
                     L"\"" + ExePath() + L"\",0") &&
         WriteString(key + L"\\shell\\open\\command", nullptr, OpenCommand());
}

/// 设为默认：备份 HKCU 里原来的命令（只备份一次，不会把自己备份进去），再写成 Flutify。
std::string SetDefault() {
  if (auto prog_id = UserChoiceProgId()) {
    if (*prog_id != kProgId) return "userChoice";
  }
  if (!ReadString(HKEY_CURRENT_USER, kStateKey, L"Previous")) {
    const auto previous = ReadString(
        HKEY_CURRENT_USER, std::wstring(kSpotifyKey) + L"\\shell\\open\\command",
        nullptr);
    WriteString(kStateKey, L"Previous",
                previous && !IsOurCommand(*previous) ? *previous : kNoPrevious);
  }
  return WriteSpotifyClass() ? "ok" : "failed";
}

/// 恢复：把备份的命令写回；接管前 HKCU 没有这个键就整个删掉（交还给 HKLM 的官方注册）。
std::string RestoreDefault() {
  const auto previous = ReadString(HKEY_CURRENT_USER, kStateKey, L"Previous");
  if (!previous || *previous == kNoPrevious) {
    ::RegDeleteTreeW(HKEY_CURRENT_USER, kSpotifyKey);
  } else {
    WriteString(std::wstring(kSpotifyKey) + L"\\shell\\open\\command", nullptr,
                *previous);
  }
  ::RegDeleteKeyValueW(HKEY_CURRENT_USER, kStateKey, L"Previous");
  return "ok";
}

struct FindContext {
  HWND found = nullptr;
};

BOOL CALLBACK FindMainWindow(HWND hwnd, LPARAM lparam) {
  wchar_t class_name[64] = {};
  ::GetClassNameW(hwnd, class_name, 64);
  if (wcscmp(class_name, kWindowClassName) == 0 &&
      ::GetPropW(hwnd, kMainWindowProp) != nullptr) {
    reinterpret_cast<FindContext*>(lparam)->found = hwnd;
    return FALSE;
  }
  return TRUE;
}

}  // namespace

std::string FindLinkArgument(const std::vector<std::string>& args) {
  for (const auto& arg : args) {
    if (arg.rfind("spotify:", 0) == 0 ||
        arg.find("open.spotify.com/") != std::string::npos) {
      return arg;
    }
  }
  return std::string();
}

bool ForwardToRunningInstance(const std::string& link) {
  // 句柄故意不关：进程存活期间持有，退出时由系统释放
  ::CreateMutexW(nullptr, FALSE, kMutexName);
  if (::GetLastError() != ERROR_ALREADY_EXISTS) return false;

  // 另一个实例可能还在创建窗口：最多等约 3 秒
  FindContext context;
  for (int i = 0; i < 30 && context.found == nullptr; ++i) {
    ::EnumWindows(FindMainWindow, reinterpret_cast<LPARAM>(&context));
    if (context.found == nullptr) ::Sleep(100);
  }
  if (context.found == nullptr) return false;

  DWORD target_pid = 0;
  ::GetWindowThreadProcessId(context.found, &target_pid);
  ::AllowSetForegroundWindow(target_pid);

  COPYDATASTRUCT data = {};
  data.dwData = kCopyDataMagic;
  data.cbData = static_cast<DWORD>(link.size());
  data.lpData = const_cast<char*>(link.data());
  DWORD_PTR reply = 0;
  return ::SendMessageTimeoutW(context.found, WM_COPYDATA, 0,
                               reinterpret_cast<LPARAM>(&data),
                               SMTO_ABORTIFHUNG, 5000, &reply) != 0;
}

void RegisterHandler() {
  const std::wstring prog_id = kProgIdKey;
  WriteString(prog_id, nullptr, L"URL:Spotify (Flutify)");
  WriteString(prog_id, L"URL Protocol", L"");
  WriteString(prog_id + L"\\DefaultIcon", nullptr, L"\"" + ExePath() + L"\",0");
  WriteString(prog_id + L"\\shell\\open\\command", nullptr, OpenCommand());

  WriteString(kCapabilitiesPath, L"ApplicationName", L"Flutify");
  WriteString(kCapabilitiesPath, L"ApplicationDescription",
              L"Spotify 第三方客户端");
  WriteString(std::wstring(kCapabilitiesPath) + L"\\URLAssociations",
              L"spotify", kProgId);
  WriteString(L"Software\\RegisteredApplications", L"Flutify",
              kCapabilitiesPath);

  // 已接管过（用户设为默认 / 之前没有处理程序）：路径跟着当前 exe 更新
  const auto ours = ReadString(
      HKEY_CURRENT_USER, std::wstring(kSpotifyKey) + L"\\shell\\open\\command",
      nullptr);
  if (ours && IsOurCommand(*ours)) {
    WriteSpotifyClass();
    return;
  }
  // 系统里没有可用的处理程序（从未安装 / 已卸载官方客户端）：直接接管
  const auto exe = CommandExe(EffectiveCommand());
  if (exe.empty() || ::GetFileAttributesW(exe.c_str()) == INVALID_FILE_ATTRIBUTES) {
    if (!UserChoiceProgId()) SetDefault();
  }
}

void MarkMainWindow(HWND hwnd) {
  ::SetPropW(hwnd, kMainWindowProp, reinterpret_cast<HANDLE>(1));
}

std::optional<std::string> ReadForwardedLink(UINT message, LPARAM lparam) {
  if (message != WM_COPYDATA) return std::nullopt;
  const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
  if (data == nullptr || data->dwData != kCopyDataMagic) return std::nullopt;
  if (data->cbData == 0 || data->lpData == nullptr) return std::string();
  return std::string(static_cast<const char*>(data->lpData), data->cbData);
}

void ActivateWindow(HWND hwnd) {
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else if (!::IsWindowVisible(hwnd)) {
    ::ShowWindow(hwnd, SW_SHOW);
  }
  ::SetForegroundWindow(hwnd);
}

ProtocolChannel::ProtocolChannel(flutter::BinaryMessenger* messenger,
                                 std::string initial_link)
    : initial_link_(std::move(initial_link)) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "flutify/protocol",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const std::string& method = call.method_name();
    if (method == "initialLink") {
      result->Success(flutter::EncodableValue(initial_link_));
      initial_link_.clear();
      dart_ready_ = true;
      return;
    }
    if (method == "status") {
      const auto command = EffectiveCommand();
      const bool is_default = IsOurCommand(command);
      const auto exe = CommandExe(command);
      std::string other;
      if (!is_default && !exe.empty()) {
        const auto slash = exe.find_last_of(L"\\/");
        other = Utf8FromUtf16(
            (slash == std::wstring::npos ? exe : exe.substr(slash + 1)).c_str());
      }
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("isDefault"), flutter::EncodableValue(is_default)},
          {flutter::EncodableValue("otherHandler"), flutter::EncodableValue(other)},
      }));
      return;
    }
    if (method == "setDefault") {
      const auto* enable = std::get_if<bool>(call.arguments());
      if (enable == nullptr) {
        result->Error("bad_args", "Expected a bool");
        return;
      }
      result->Success(
          flutter::EncodableValue(*enable ? SetDefault() : RestoreDefault()));
      return;
    }
    result->NotImplemented();
  });
}

void ProtocolChannel::DeliverLink(const std::string& link) {
  if (link.empty()) return;
  if (!dart_ready_) {
    initial_link_ = link;
    return;
  }
  channel_->InvokeMethod("openLink",
                         std::make_unique<flutter::EncodableValue>(link));
}

}  // namespace protocol_handler
