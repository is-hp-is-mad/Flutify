# 文案与多语言约定

## 流程
- 新增文案先写 `lib/l10n/app_zh.arb`（模板，含 `@` 描述与占位符类型），再同步 `app_zh_Hant.arb`、`app_en.arb`、`app_ja.arb`，运行 `flutter gen-l10n`。
- 提交前运行 `python3 tool/check_l10n.py`（CI 也会跑）：检查键齐全、占位符一致、en 不含中文、zh_Hant 不含简体写法。
- 组件里不写硬编码文案，统一 `context.l10n.xxx`；Provider / 服务层不依赖 `BuildContext`，错误文案在 UI 层转换。
- 带数量的文案：英文用 ICU `plural`（`=1{1 song} other{{count} songs}`）；一句话里有多个数量时，把各自已格式化好的短语（`songCount` / `playlistCount` / `likedSongCount`）作为 String 占位符传入。

## 术语表
| 概念 | zh | zh_Hant | en | ja |
|---|---|---|---|---|
| 歌单 | 歌单 | 歌單 | playlist | プレイリスト |
| 已点赞的歌曲 | 已点赞的歌曲 | 已點贊的歌曲 | Liked Songs | お気に入りの曲 |
| 收藏（歌单 / 专辑） | 收藏 | 收藏 | save | 保存 |
| 备份 | 备份 | 備份 | back up | バックアップ |
| 同步（写入账号） | 同步 | 同步 | sync | 同期 |
| 导入（从备份取回） | 导入 | 匯入 | import | 取り込む |
| 反代 / 网关 | 反代 | 反代 | gateway | ゲートウェイ |
| 自测版 | 自测版 | 自測版 | self-test build | セルフテスト版 |

## 繁体（台湾用语）
伺服器、音訊、預設、透過、資訊、程式、資料、支援、選單、自訂、使用者（用戶端除外）。简体字和「后 / 于 / 里 / 余」等常见混入写法由 `check_l10n.py` 拦截。
