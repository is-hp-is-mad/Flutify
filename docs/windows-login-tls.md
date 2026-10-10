# Windows 登录时证书校验失败

表现：WebView 已收到 OAuth 授权回调，但 Web token 和桌面令牌请求报
`CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`。
回调成功只表示取得授权码，不代表令牌交换已经成功。

Windows 上 Dart 的默认信任库使用内置 CA，WebView2 使用系统信任设置。
因此，部分机器使用系统已信任的企业代理或 HTTPS 检查软件时，可能出现
网页正常、Dart HTTPS 请求失败的差异。

应用启动时通过 Windows CryptoAPI 读取**用户与机器两个物理 ROOT 存储**，
把通过本机链验证且允许服务器认证的根证书补充到 Dart 默认 SecurityContext，
并按 DER 去重。不导入个人证书或中间证书存储，不安装证书，不绕过 TLS 校验。
读取失败时保留 Dart 原有信任库；显式创建的自定义 SecurityContext 不受影响。
系统信任库变更后需重启应用。

Windows 的 ROOT 存储是按需补全的：精简版或更新受限的系统（如 LTSC）可能缺少
Spotify 服务器证书链所指向的根（Starfield G2、DigiCert G2 / G3），直到有程序
触发 CryptoAPI 联网获取。WebView2 会触发这次获取，Dart 只读取已有内容，所以
网页能登录而 Dart 请求报 `unable to get local issuer certificate`。部分用户
安装官方 Spotify 客户端后恢复正常，就是因为它触发了这次补全（[#20](https://github.com/is-hp-is-mad/Flutify/issues/20)）。
应用因此内置这三个公开根证书，作为额外信任锚补充到 Dart 的信任库
（见 `lib/services/network/spotify_fallback_roots.dart`）。服务器仍须出示有效证书链
与匹配的主机名，不关闭任何校验，也不向系统证书库写入任何内容。

证书被拒绝时，诊断日志会记录对端证书的信息（`[TLS]` 行）：
subject、issuer 与 SHA-1。证书依旧被拒绝，这条日志只用于定位是哪一方在
替换 HTTPS 证书（安全软件、公司代理、自建网关等）。登录页遇到 TLS 失败时
会明确提示可能存在 HTTPS 拦截。

Windows 系统代理的 PAC / 自动检测由原生 WinHTTP 逐 URL 求值（见
`windows/runner/system_proxy_windows.cpp`），SOCKS 代理由 `ProxyTunnel`
自建握手，二者与浏览器 / WebView2 的选路保持一致。

回归测试使用本地测试证书验证：未信任时拒绝连接，加载根证书后成功，
主机名不匹配仍被拒绝，回环连接继续绕过代理。

反馈用户仍需用新构建复测。如果仍失败，可收集应用日志中的 `[TLS]` 行、
系统版本、应用代理模式及是否启用 HTTPS 检查；不要收集 Cookie 或令牌。
此修复不补全服务器漏发的中间证书，也不会信任系统本身未信任的证书。
