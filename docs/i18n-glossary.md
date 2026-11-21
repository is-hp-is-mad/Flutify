# 文案与多语言约定

## 流程
- 新增文案先写 `lib/l10n/app_zh.arb`（模板，含 `@` 描述与占位符类型），再同步 `app_zh_Hant.arb`、`app_en.arb`、`app_ja.arb`，运行 `flutter gen-l10n`。
- 提交前运行 `python3 tool/check_l10n.py`（CI 也会跑）：键齐全、占位符一致、en 不含中文、zh_Hant 不含简体字、不使用下面「禁用写法」。
- 组件里不写硬编码文案，统一 `context.l10n.xxx`；Provider / 服务层不依赖 `BuildContext`：异常带 `kind` / `detail`（中文 `message` 只作日志兜底），界面按 `kind` 显示 ARB 文案。**不要拿文案去判断类型**（用 `identical` / 枚举）。
- 带数量的文案：英文用 ICU `plural`（`=1{1 song} other{{count} songs}`）；一句话里有多个数量时，把各自已格式化好的短语（`songCount` / `playlistCount` / `likedSongCount`）作为 String 占位符传入。
- Spotify 账号语言不一定和界面语言相同：请求头 `Accept-Language` 统一取 `AppLocale.spotifyLanguage`；**不要依赖响应里的中文文案做判断**。

## 术语表（依据 open.spotify.com 前端的官方用词）
词条取自 2026-11 的 web-player 语言包（`zh-CN` / `zh-TW` / `ja` / `en`，可从 `open.spotify.com` 页面里的 `locales/web-player/<lang>.<hash>.json` 取得，需带对应 `Accept-Language`）。「不用」列带 ⚠ 的由 `tool/check_l10n.py` 拦截。

### Spotify 概念
| 概念 | zh | zh_Hant | en | ja | 不用 |
|---|---|---|---|---|---|
| 歌单 | 歌单 | 播放清單 | Playlist | プレイリスト | ⚠ 歌單（繁体） |
| 已点赞的歌曲 | 已点赞的歌曲 | 已按讚的歌曲 | Liked Songs | お気に入りの曲 | ⚠ 已點贊 |
| 点赞（按钮） | 点赞 | 讚 | Like | いいね！ | ⚠ 點贊 |
| 音乐库 | 音乐库 | 你的音樂庫（导航项）/ 音樂庫 | Your Library | マイライブラリ | ⚠ 媒体库、资料库、媒體庫 |
| 保存到音乐库 | 收藏至音乐库 | 儲存至你的音樂庫 | Save to Your Library | マイライブラリに保存 | |
| 队列 | 队列 | 佇列 | Queue | 次に再生 | ⚠ 隊列；日文不用「キュー」 |
| 加入队列 | 加入播放队列 | 新增至佇列 | Add to queue | [次に再生] に追加 | |
| 关注 / 关注中 | 关注 / 关注中 | 追蹤 / 追蹤中 | Follow / Following | フォローする / フォロー中 | 已关注、關注 |
| 歌曲 | 歌曲 | 歌曲 | Song | 曲 | |
| 艺人 | 艺人 | 藝人 | Artist | アーティスト | |
| 专辑 | 专辑 | 專輯 | Album | アルバム | |
| 播客 / 单集 | 播客 / 单集 | Podcast / 單集 | Podcast / Episode | ポッドキャスト / エピソード | ⚠ 播客（繁体） |
| 帐号 | 帐号 | 帳戶 | Account | アカウント | ⚠ 账号、帳號 |
| 登录 / 登出 | 登录 / 退出 | 登入 / 登出 | Log in / Log out | ログイン / ログアウト | ⚠ en 不用 Sign in / Sign out |
| 当前播放 | 当前播放 | 現正播放 | Now playing | 再生中 | 正在播放（作为标签时） |
| Spotify Connect | Spotify 畅联功能 | Spotify Connect | Spotify Connect | Spotify Connect | |
| 连接到设备 | 连接到设备 | 連接至裝置 | Connect to a device | デバイスに接続 | |
| 转至专辑 / 艺人 | 转至专辑 / 转至艺人 | 前往專輯 / 前往藝人頁面 | Go to album / artist | アルバムに移動 / アーティストに移動 | 前往专辑 |
| 查看制作人员 | 查看制作人 | 查看製作人員名單 | View credits | 楽曲クレジットを表示 | |
| 加入歌单 | 加入歌单 | 新增至播放清單 | Add to playlist | プレイリストに追加 | ⚠ 添加（繁体）|
| 删除 | 删除 | 移除 | Remove / Delete | 削除 | |
| 唱片目录 | 唱片目录 | 音樂作品 | Discography | ディスコグラフィ | |

### 应用功能（Spotify 没有对应词，本项目自定）
| 概念 | zh | zh_Hant | en | ja | 不用 |
|---|---|---|---|---|---|
| 备份 | 备份 | 備份 | back up | バックアップ | |
| 同步（写入账号） | 同步 | 同步 | sync | 同期 | |
| 导入（从备份取回） | 导入 | 匯入 | import | 取り込む | |
| 反代 | 反代 | 反代 | gateway | ゲートウェイ | 网关 |
| 代理 | 代理 | 代理 | proxy | プロキシ | |
| 缓存 | 缓存 | 快取 | cache | キャッシュ | |
| 译词（歌词翻译） | 译词 / 译文 | 譯詞 / 譯文 | translation | 訳詞 | |
| 小组件 | 小组件 | 小工具 | widget | ウィジェット | ⚠ 小部件 |
| 任务栏（Windows） | 任务栏 | 工作列 | taskbar | タスクバー | ⚠ 任務欄 |
| 自测版 / 测试版 / 正式版 | 自测版 / 测试版 / 正式版 | 自測版 / 測試版 / 正式版 | Self-test / Beta / Release | セルフテスト版 / ベータ版 / 正式版 | |

### 有意不跟官方的地方
- **接下来播放**（`queueNextUp`）：官方 zh 是「下一首」，会和「下一首」按钮重名，保留「接下来播放」。
- **语言自称**（English / 简体中文 / 日本語）保持各自语言，不随界面语言变。

## 繁体（台湾用语）
伺服器、音訊、預設、透過、資訊、程式、資料、支援、選單、自訂、使用者（用戶端除外）、可攜式、驗證，以及上表中的官方用词。简体字和「后 / 于 / 里 / 余」等常见混入写法由 `check_l10n.py` 拦截。
