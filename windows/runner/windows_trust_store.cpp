#include "windows_trust_store.h"

#include <windows.h>
#include <wincrypt.h>

#include <cstdint>
#include <memory>
#include <set>
#include <thread>
#include <vector>

namespace {

/// 把 [store] 里通过 Windows 校验的根证书追加到 [roots]（[seen] 跨库去重）。
void AppendRoots(HCERTSTORE store,
                 std::set<std::vector<uint8_t>>& seen,
                 flutter::EncodableList& roots) {
  PCCERT_CONTEXT cert = nullptr;
  while ((cert = CertEnumCertificatesInStore(store, cert)) != nullptr) {
    std::vector<uint8_t> der(cert->pbCertEncoded,
                             cert->pbCertEncoded + cert->cbCertEncoded);
    // Honor Windows' disabled/disallowed roots and server-auth usage policy.
    // This is a local store read: no certificate downloads on the UI thread.
    LPSTR usage = const_cast<LPSTR>(szOID_PKIX_KP_SERVER_AUTH);
    CERT_CHAIN_PARA parameters{};
    parameters.cbSize = sizeof(parameters);
    parameters.RequestedUsage.dwType = USAGE_MATCH_TYPE_AND;
    parameters.RequestedUsage.Usage.cUsageIdentifier = 1;
    parameters.RequestedUsage.Usage.rgpszUsageIdentifier = &usage;
    PCCERT_CHAIN_CONTEXT chain = nullptr;
    const BOOL built = CertGetCertificateChain(
        nullptr, cert, nullptr, store, &parameters,
        CERT_CHAIN_CACHE_ONLY_URL_RETRIEVAL |
            CERT_CHAIN_DISABLE_AUTH_ROOT_AUTO_UPDATE,
        nullptr, &chain);
    const bool trusted =
        built && chain->TrustStatus.dwErrorStatus == CERT_TRUST_NO_ERROR;
    if (chain) CertFreeCertificateChain(chain);
    if (trusted && seen.insert(der).second) {
      roots.emplace_back(std::move(der));
    }
  }
}

HCERTSTORE OpenRootStore(DWORD location) {
  return CertOpenStore(
      CERT_STORE_PROV_SYSTEM_W, 0, 0,
      location | CERT_STORE_READONLY_FLAG | CERT_STORE_OPEN_EXISTING_FLAG,
      L"ROOT");
}

using Result = flutter::MethodResult<flutter::EncodableValue>;

constexpr wchar_t kReplyClass[] = L"FlutifyTrustStoreReply";
constexpr UINT kReplyMessage = WM_APP + 1;

struct RootReply {
  std::unique_ptr<Result> result;
  std::vector<uint8_t> root;  // 空表示 Windows 不信任这条链
};

// 工作线程的结果回到平台线程再交给 Flutter（MethodResult 只能在平台线程上完成）。
LRESULT CALLBACK ReplyProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message != kReplyMessage) return DefWindowProcW(hwnd, message, wparam, lparam);
  std::unique_ptr<RootReply> reply(reinterpret_cast<RootReply*>(lparam));
  if (reply->root.empty()) {
    reply->result->Success(flutter::EncodableValue());
  } else {
    reply->result->Success(flutter::EncodableValue(std::move(reply->root)));
  }
  return 0;
}

HWND CreateReplyWindow() {
  WNDCLASSW wc{};
  wc.lpfnWndProc = ReplyProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kReplyClass;
  RegisterClassW(&wc);  // 重复注册失败无妨，窗口照样能建
  return CreateWindowExW(0, kReplyClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
}

/// 让 Windows 为 [der]（服务器发来的证书）建链：系统信任这条链时返回它的根证书，否则返回空。
///
/// Windows 的根证书是按需下载的，本机 ROOT 库里只有用过的那些；这里不带「仅缓存」标志，
/// 让系统照它自己的策略去取根（与 WebView2 / 浏览器同一套判断），可能联网，所以在工作线程上跑。
std::vector<uint8_t> TrustedRootFor(const std::vector<uint8_t>& der) {
  std::vector<uint8_t> root;
  PCCERT_CONTEXT cert =
      CertCreateCertificateContext(X509_ASN_ENCODING, der.data(), static_cast<DWORD>(der.size()));
  if (!cert) return root;
  LPSTR usage = const_cast<LPSTR>(szOID_PKIX_KP_SERVER_AUTH);
  CERT_CHAIN_PARA parameters{};
  parameters.cbSize = sizeof(parameters);
  parameters.RequestedUsage.dwType = USAGE_MATCH_TYPE_AND;
  parameters.RequestedUsage.Usage.cUsageIdentifier = 1;
  parameters.RequestedUsage.Usage.rgpszUsageIdentifier = &usage;
  PCCERT_CHAIN_CONTEXT chain = nullptr;
  if (CertGetCertificateChain(nullptr, cert, nullptr, nullptr, &parameters, 0, nullptr, &chain) && chain) {
    if (chain->TrustStatus.dwErrorStatus == CERT_TRUST_NO_ERROR && chain->cChain > 0 &&
        chain->rgpChain[0]->cElement > 0) {
      const PCERT_SIMPLE_CHAIN simple = chain->rgpChain[0];
      const PCERT_CHAIN_ELEMENT last = simple->rgpElement[simple->cElement - 1];
      // 只交出自签名的根：中间证书不能当信任锚
      if (last->TrustStatus.dwInfoStatus & CERT_TRUST_IS_SELF_SIGNED) {
        root.assign(last->pCertContext->pbCertEncoded,
                    last->pCertContext->pbCertEncoded + last->pCertContext->cbCertEncoded);
      }
    }
  }
  if (chain) CertFreeCertificateChain(chain);
  CertFreeCertificateContext(cert);
  return root;
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateWindowsTrustStoreChannel(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "flutify/windows_trust_store",
          &flutter::StandardMethodCodec::GetInstance());
  const HWND reply_window = CreateReplyWindow();
  channel->SetMethodCallHandler([reply_window](const auto& call, auto result) {
    if (call.method_name() == "rootFor") {
      const auto* der = std::get_if<std::vector<uint8_t>>(call.arguments());
      if (!der || der->empty() || !reply_window) {
        result->Success(flutter::EncodableValue());
        return;
      }
      std::thread([reply_window, der = *der, result = std::move(result)]() mutable {
        auto reply = std::make_unique<RootReply>();
        reply->root = TrustedRootFor(der);
        reply->result = std::move(result);
        // 投递失败（窗口已随进程退出销毁）时 reply 在这里释放，不再回调已关闭的引擎
        if (PostMessageW(reply_window, kReplyMessage, 0, reinterpret_cast<LPARAM>(reply.get()))) {
          reply.release();
        }
      }).detach();
      return;
    }
    if (call.method_name() != "roots") {
      result->NotImplemented();
      return;
    }
    // Both stores matter: the current-user store holds user / antivirus /
    // corporate roots, the machine store holds Windows' per-machine agents.
    // Dart's bundled roots cover neither, so import both locations.
    const DWORD locations[] = {CERT_SYSTEM_STORE_CURRENT_USER,
                               CERT_SYSTEM_STORE_LOCAL_MACHINE};
    std::set<std::vector<uint8_t>> seen;
    flutter::EncodableList roots;
    bool anyStore = false;
    for (const DWORD location : locations) {
      HCERTSTORE store = OpenRootStore(location);
      if (!store) continue;
      anyStore = true;
      AppendRoots(store, seen, roots);
      CertCloseStore(store, 0);
    }
    if (!anyStore) {
      result->Error("root_store_unavailable", "Cannot open Windows ROOT store");
      return;
    }
    result->Success(flutter::EncodableValue(std::move(roots)));
  });
  return channel;
}
