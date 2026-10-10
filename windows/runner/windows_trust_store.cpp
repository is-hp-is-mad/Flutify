#include "windows_trust_store.h"

#include <windows.h>
#include <wincrypt.h>

#include <cstdint>
#include <set>
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

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateWindowsTrustStoreChannel(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "flutify/windows_trust_store",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
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
