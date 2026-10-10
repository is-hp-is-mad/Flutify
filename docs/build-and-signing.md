# 构建与固定签名

工作流：`.github/workflows/build.yml`。推送 `main` 或手动运行生成 Actions 产物；推送 `v*` 标签在所有构建成功后发布 Release。包含 `alpha`、`beta` 或 `rc` 的标签标为预发布。

## Fork 与功能分支自测

`.github/workflows/self-test.yml` 是独立的 **Self-test** 工作流，不读取任何仓库签名 Secrets，不写标签或发布 Release。它不会修改或替代上面的正式发布流程；在 fork 中手动运行原 `Build`，仍然需要正式签名配置。

- 分支推送自动触发（纯文档变更除外），目标为 `main` 的 PR 也会触发；标签推送不触发。工作流进入默认分支后，可在 Actions 页面手动选择分支运行。
- 首先分析 `lib/`、`test/`，执行全部 Flutter、Node 和 Python 测试。既有 info 级 lint 会展示但不阻断，error 和 warning 仍阻断；`tool/` 下的独立 Dart 探针不属于应用静态分析范围。没有禁用测试或放行测试失败。
- 质量检查通过后，并行构建 Android、macOS、Windows x64 / ARM64。SDK 与正式流程一致：Mac 3.44.9，其他平台 3.44.0；Mac 再执行一次该平台的 Flutter 测试。
- 独立的 **macOS native titlebar hit testing** 只在涉及 `macos/`、原生 Swift 测试、CI 工作流/复用 action 或路径判断器时随 PR/功能分支运行。只修改 Android 或共享 Dart 代码不会触发这项独立 Swift 测试，但上面的完整 Flutter 测试和各平台构建仍运行。
- `main`、仓库默认分支及手动运行始终保留原生标题栏检查。PR 比较整个 merge-base 差异，功能分支推送比较全部推送提交，删除和重命名也计算在内；新分支、历史不足或判断出错时保守地执行，不把检测失败当作无关改动。修改 CI 自身的这一轮也会运行原生检查。这是触发范围优化，不代表修复了原生全屏测试的偶发挂起。
- Android 在 runner 临时目录生成一次性 PKCS12 密钥，使用随机密码并屏蔽日志；以 **release 编译模式**生成通用包与三个 ABI 拆分包，按本次证书指纹检查签名、versionCode 和媒体图标。任务完成后删除临时私钥，不上传密钥或密码。
- Mac 输出未做 Developer ID 签名、公证的 `.app` ZIP；Windows 输出经过架构及运行库校验的便携 ZIP，不生成正式安装程序。
- 产物名称均包含 `self-test`，在该次 Actions 运行的 Artifacts 中保留 7 天；缺少产物会使任务失败。令牌仅有 `contents: read` 权限，checkout 不持久保存凭据。

**不要把 Android 自测包当成升级包。** 每次运行的签名都不同，基础 versionCode 固定为 1，不能直接覆盖正式版本、现有本机签名版本或上次 CI 自测版本。建议在独立测试设备/模拟器使用，不要为安装自测包卸载当前日常使用版本而丢失应用数据。CI 不自动安装到用户设备，自动化通过也不能替代真机登录和播放验证。

工作流边界和一次性签名的回归测试：

```sh
node --test tool/test_self_test_workflow.cjs tool/test_self_test_scope.cjs tool/test_self_test_signing.cjs
```

签名测试在临时目录使用 Bash、OpenSSL 与 JDK 17 的 `keytool`，验证可用证书、每次重新生成以及拒绝覆盖现有密钥；不使用本地正式签名文件。

## Android

正式发布的 release APK 必须使用同一把 beta 密钥；缺失配置时直接失败，不回退到 debug 或自测签名。调试构建不需要 release 密钥。

正式发布仓库需要配置下列 Actions Secrets（不会随 fork 复制）：

| Secret | 用途 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | JKS 文件的 Base64 内容 |
| `ANDROID_KEYSTORE_PASSWORD` | JKS 密码 |
| `ANDROID_KEY_ALIAS` | 签名别名 |
| `ANDROID_KEY_PASSWORD` | 私钥密码 |
| `ANDROID_SIGNING_CERT_SHA256` | 构建后验证的证书指纹 |

固定 beta 证书 SHA-256：

```text
f342b46d13f500863b6ed4987ae78e5e57d6f8f53690e6e79fa33f17871f2715
```

此次创建的本机备份是仓库目录下的 `.signing/flutify-beta.jks` 和 `.signing/signing.json`。后者包含密码；两者均被 Git 忽略，必须一起保存到可靠的私密备份中。GitHub Secrets 不能导出原值。不要重新生成或轮换密钥来处理普通构建故障。

此前 beta 的旧密钥没有备份，因此旧签名不同的安装需要卸载后安装一次。从这把固定密钥签署的版本开始，后续版本可覆盖升级。

本地 release 构建可以配置环境变量 `ANDROID_KEYSTORE_PATH`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`；也可以在已被忽略的 `android/key.properties` 中设置 `storeFile`、`storePassword`、`keyAlias`、`keyPassword`。`storeFile` 相对 `android/` 解析，或使用绝对路径；Windows 属性文件中的路径建议使用 `/`。

工作流临时解码密钥，完成后无论成功失败均删除临时文件。每次构建输出通用包及 armeabi-v7a、arm64-v8a、x86_64 三个拆分包。`tool/verify_android_apks.py` 用 `apksigner` 验证全部四个包的签名和固定指纹，用 `aapt` 检查 versionCode 和媒体通知图标资源，并输出 APK SHA-256。

基础 versionCode 为 `(100 + GITHUB_RUN_NUMBER) * 10000 + GITHUB_RUN_ATTEMPT`。Flutter 为三个拆分包分别增加 1000、2000、4000；批次间隔确保下一批通用包的版本号也高于上一批拆分包。同一运行重试增加 attempt；重跑较早运行不会成为较新发布版本的升级包。

## Windows x64 与 ARM64

工作流分别使用 `windows-latest` 和 `windows-11-arm` runner，生成 `windows-x64`、`windows-arm64` 两份独立产物。打包前使用 `tool/verify_windows_arch.py` 检查所有 EXE/DLL 的 PE 架构，包括 libmpv，防止把 x64 依赖装入 ARM64 包。

Flutter 固定为 3.44.0。官方发布清单没有该版本的整套 Windows ARM64 SDK ZIP，所以 ARM64 runner 从官方 Flutter 仓库的 3.44.0 标签启动，校验提交 `559ffa3f75e7402d65a8def9c28389a9b2e6fe42`，再由官方启动脚本下载原生 ARM64 Dart。工作流同时验证 runner 和 Dart 架构；Flutter 根据宿主 Dart 架构选择 Windows 构建目标。

上游 `media_kit_libs_windows_audio` 包只提供 x64 下载配置，因此 `packages/media_kit_libs_windows_audio/` 保留一份 MIT 授权的 CMake 适配，分别下载并校验 x64／ARM64 libmpv。来源、版本、许可证见该目录 README 和根目录 `THIRD_PARTY_NOTICES.md`。Windows ZIP 附带项目许可证和第三方声明。

本地 x64 构建成功不能替代 ARM64 runner 或 Android CI 验证；CI 构建成功也不能替代真机登录、DRM 播放、媒体键和 WebView 检查。
