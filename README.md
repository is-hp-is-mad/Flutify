<div align="center">

<img src="assets/brand/flutify_logo_1024.png" width="112" alt="Flutify" />

# Flutify

**Flutter + Rust (`flutify_core`)** 驱动的跨平台 Spotify 第三方客户端 · Windows (x64 / ARM64) · Android · macOS · Linux

[下载安装](https://github.com/is-hp-is-mad/Flutify/releases)

[![正式版](https://img.shields.io/github/v/release/is-hp-is-mad/Flutify?label=%E6%AD%A3%E5%BC%8F%E7%89%88&color=2ea44f&cacheSeconds=300)](https://github.com/is-hp-is-mad/Flutify/releases/latest)
[![Beta 版](https://img.shields.io/github/v/release/is-hp-is-mad/Flutify?include_prereleases&sort=date&filter=*-beta&label=Beta&color=1f6feb&cacheSeconds=300)](https://github.com/is-hp-is-mad/Flutify/releases)
[![Self-Test 版](https://img.shields.io/github/v/release/is-hp-is-mad/Flutify?include_prereleases&sort=date&filter=*-selftest&label=Self-Test&color=d97706&cacheSeconds=300)](https://github.com/is-hp-is-mad/Flutify/releases)

</div>

---

## ✨ 核心功能

### 🎧 听歌与媒体库
- **无缝授权与浏览**：应用内 Spotify 官方登录页一次登录即可自动维护会话与令牌，支持主页、探索（WatchFeed）、搜索、歌单、专辑、艺人、播客节目与单集、Canvas 动态封面
- **全曲播放与边下边播**：支持 Widevine（Windows WebView2 / Android Media3 / Linux Chrome）、FairPlay（macOS / iOS）与协议流式解密，支持按文件响度数据自动音量均衡（ReplayGain）、歌曲间淡入淡出及重启断点续播
- **双层播放队列**：支持「下一首播放（手动队列）」与「来自歌单/专辑（上下文队列）」、随机、列表循环与单曲循环
- **多账号歌单备份**：支持绑定多个 Spotify 账号独立备份已点赞歌曲与收藏歌单，原子落盘并支持勾选部分条目合并导入当前账号

### 📝 歌词体验
- **多源歌词与译文对齐**：优先获取官方同步歌词，缺失时自动从 [LRCLIB](https://lrclib.net) 补全；支持可选启用 QQ 音乐 / 网易云社区译文按时间轴精准对齐，以及词组级简繁转换
- **沉浸与桌面集成**：Apple 风格流动背景与逐行焦点动效、桌面沉浸式歌词（`F11`）及 Windows 嵌入式任务栏歌词

### 📡 Spotify Connect
- **双向控制与接收端**：基于 Dealer WebSocket 与 `connect-state/v1` 协议，既可遥控同账号其他设备，也可将本机注册为可被其他设备发现和遥控的播放端，播放状态与进度双向同步
- **自定义设备名**：可在设置中自定义当前设备的 Connect 显示名称

### 🎨 外观、交互与网络
- **Material 3 Expressive 与玻璃材质**：支持柔光玻璃（Hyper Glass）、液态玻璃（Liquid Glass）、深/浅色及纯黑背景，强调色可自动跟随专辑封面
- **响应式与快捷键**：桌面三栏布局，窗口变窄自动切换为移动端悬浮底栏交互；支持系统媒体控制（SMTC / MPRIS / MediaSession / 锁屏）、应用内快捷键与自定义全局快捷键
- **网络路由与缓存管理**：支持系统代理 / 手动 HTTP 代理、按任务隔离的 Rust HTTP/2 连接池，以及可选 `FlutifyPS` HTTPS 反代与按网络出口国家/地区自动切换；桌面端支持音频、封面、歌词缓存分目录迁移与按上限自动清理
- **应用内更新**：支持检查并安装 `self-test` / `beta` / `release` 通道更新

---

## 🏗️ 技术架构

Flutify 采用 **Flutter 表现层 + 高内聚领域服务端口 + Rust 核心后端** 的分层架构：

| 层级 | 目录 | 职责说明 |
|---|---|---|
| **UI 与状态层** | `lib/ui/`、`lib/providers/`、`lib/bootstrap/` | 响应式界面、主题/玻璃渲染、播放/媒体库/Connect 状态编排与启动装配 |
| **服务与端口层** | `lib/services/` | 按存储（`storage/`）、播放控制（`playback/`）、备份（`backup/`）、EME 回环宿主页（`eme/`）、Connect 与歌词等独立模块解耦 |
| **Rust 核心层** | `rust/flutify_core/` | 通过 `flutter_rust_bridge` 提供统一 HTTP/2 客户端与按请求代理隔离、会话/TOTP 令牌单飞刷新、AP 协议（DH/Shannon/Mercury/AudioKey）、分段并发下载与 AES-CTR 解密、Protobuf/Pathfinder/WatchFeed/LRC/OpenCC 编解码及缓存/备份原子文件操作 |

---

## 📦 安装

从 [Releases](https://github.com/is-hp-is-mad/Flutify/releases) 下载对应平台安装包：

| 平台 | 安装包 / 归档 | 说明 |
|---|---|---|
| **Windows x64** | `*-windows-x64-setup.exe` 或 `*-windows-x64.zip` | 安装版或解压即用便携版；附带 MSVC 运行库，播放依赖 WebView2 运行时（Windows 11 默认自带） |
| **Windows ARM64** | `*-windows-arm64-setup.exe` 或 `*-windows-arm64.zip` | 原生 ARM64 安装版或便携版 |
| **Android** | `*-android-arm64-v8a.apk` | 绝大多数手机选此版本；不确定架构可选 `*-android-universal.apk` |
| **macOS** | `*-macos.zip` | 含 FairPlay EME 播放支持；未做 Developer ID 签名与 Apple 公证，详见 [macOS 说明](docs/MACOS.md) |
| **Linux** | `*-linux-x64.deb` 或 `*-linux-x64.tar.gz` | Debian/Ubuntu 用 `.deb`（`sudo apt install ./Flutify-*-linux-x64.deb`），运行需 `libmpv`，全曲播放调用系统 Chrome/Chromium（含 Widevine），详见 [Linux 说明](docs/LINUX.md) |

### 快速上手
1. 首次打开进入「设置 → 账号 → 登录」，在弹出的 Spotify 官方登录页完成登录。
2. 若当前网络无法直连 Spotify，可在「设置 → 网络」配置系统/手动 HTTP 代理，或开启「Spotify 反代」并配合自动地区检测（通过 `https://cloudflare.com/cdn-cgi/trace` 判断出口国家/地区）。
3. 桌面端可在「设置 → 存储」分别为音频、封面与歌词调整缓存目录（修改时支持自动迁移旧缓存）。

---

## 🌐 可选自建服务

[FlutifyPS](https://github.com/is-hp-is-mad/FlutifyPS) 是 Flutify 的可选自建 HTTPS 反代服务，覆盖 Spotify API、媒体下载与 Connect 连接。若当前网络环境可直接访问 Spotify，则无需部署。

> [!WARNING]
> **已知使用 Cloudflare 反向代理导致 Spotify 封号概率极高，请谨慎反代。**

部署方式见 [FlutifyPS 部署与接入说明](https://github.com/is-hp-is-mad/FlutifyPS#部署)，部署后在「设置 → 网络 → Spotify 反代」填入 HTTPS 地址与凭据即可。

---

## 🧪 已知注意事项

- **Android 系统差异**：已接入 Media3 与系统 Widevine 原生播放，但不同厂商 ROM 的媒体卡片与 DRM 兼容性仍可能存在差异；与旧版签名不同的安装包首次更新需卸载重装。
- **macOS**：未做 Developer ID 签名与公证，首次打开需在系统「隐私与安全性」中放行。
- **Linux**：不内置 WebView，全曲播放依赖本机已安装的 Google Chrome / Chromium（含 Widevine）及 `libmpv`，部分桌面系统托盘/任务栏扩展能力受限，详见 [Linux 说明](docs/LINUX.md)。
- **限流与账号权益**：偶发 HTTP 429 限流时稍等片刻即可恢复；免费账号可用能力以 Spotify 服务端策略为准。

遇到问题欢迎提交 [Issue](https://github.com/is-hp-is-mad/Flutify/issues)。

---

## ⚠️ 免责声明

- 本项目为非官方第三方客户端，**与 Spotify AB 没有任何关联**，`Spotify` 是 Spotify AB 的注册商标。
- 本项目仅供学习与研究交流使用。使用第三方客户端可能违反 Spotify 服务条款，**存在账号受限风险，建议使用小号**，相关后果由使用者自行承担。
- 本项目不提供、不存储任何音频或版权内容，所有数据均来自用户自己的 Spotify 账号及公开歌词源。
- 请支持正版，订阅 Spotify Premium。

---

## 📄 许可证与开发

- 许可证：[MIT License](LICENSE)，随附第三方组件声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 开发与构建指南：见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

## 🙏 致谢

感谢 <a href="https://linux.do">LINUX DO</a> 社区的反馈与支持。
