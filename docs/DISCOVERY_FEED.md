# 官方竖滑发现流（Discover something new / Watch Feed）

## 需求与验收

- 搜索页「浏览全部」上方出现官方「Discover something new」卡片行：2:3 竖版卡片静音循环播放 Canvas，标题即 #标签（「Music for you」「#mellow indie」…），数据来自官方接口，取不到时整行隐藏。
- 艺人页热门曲目下方出现官方「Explore {艺人}」卡片行（Songs by / Similar to …，9:16），以该艺人热门第一首为种子；没有内容时不占位。
- 点卡片进入全屏发现流：
  - 上下滑逐条浏览，下一张从底部露出 6%，相邻卡片 0.8 透明度，卡片最大 9:16、圆角 24；
  - 左右滑在主 feed 与服务端给的关联 feed 之间切换，顶栏标题随之换成对应 #标签，并显示页码点（选中为 24dp 胶囊）；
  - 有 Canvas 的条目播官方竖版视频（叠官方渐变），没有的显示「封面取色底 + 20% 压暗 + 波形动画 + 正方形封面卡」；
  - 声音是条目自带的约 30 秒副歌试听（独立播放器，按服务端要求循环 / 5 秒淡入），进入即暂停主播放；顶栏可静音；切到后台暂停、回到前台恢复；
  - 移动端 feed 为当前页时隐藏底部导航与迷你播放栏，从 feed 打开专辑等页面时恢复；
  - 底部依次为艺人行（头像、粉丝数、关注）、#标签行（点击进入该标签的 feed）、曲目行（点击进入这首歌所在的专辑，自动滚动到这首并短暂高亮；拿不到专辑时退回为直接播放；带保存）；右侧为分享、更多（曲目菜单）、保存；最下方为可拖动的试听进度条；
  - 卡片成为当前页时，叠加组件按 200ms 间隔依次上浮淡入（400ms，Cubic(0.3, 0, 0.4, 1)）；
  - 轻点暂停 / 继续，双击保存并播放彩纸动画，长按隐藏界面并放大封面；
  - 首次进入显示「上滑看更多」引导（手指动画），有关联 feed 时 5 秒后从右侧滑入「左右滑切换」提示，各只出现一次；
  - 桌面端 ↑/↓、PageUp/PageDown、滚轮翻条目，←/→ 切换 feed，空格暂停。
- 四语文案齐全；复验命令全绿。

### 桌面版（macOS / Windows / Linux 宽屏布局）

界面不沿用手机版，按官方桌面网页版（open.spotify.com 抓包，`dwp-watch-feed-view-container`）复刻：

- 入口：艺人 / 专辑 / 歌单页操作行里紧跟大播放键的小按钮（38×48，30×40 竖版缩略图，出现时描一圈边框，悬停显示播放图标）；只有该实体确实有视频流时才显示。搜索页「Discover something new」与艺人页「Explore」卡片在桌面端也打开同一个桌面界面。
- 呈现：盖住整个窗口的模态层（90% 黑底），中间 16:10 对话框（宽 = min(85% 窗宽, 1680, 85% 窗高 × 1.6)，圆角 8，1px 描边），底色为当前歌曲封面深色（0.5s 过渡）叠一层从右侧向左变暗的径向渐变。点暗区、Esc、右上角关闭按钮关闭。
- 三栏（按对话框宽度分 <778 / <1102 / 其余三档）：
  - 左栏：feed 标题；大号歌名（20 / 24 / 32，最多 3 行，按翻页方向滑入）、艺人（可点）、54×54 专辑封面（仅有 Canvas 时）+ 4px 白色试听进度；底部艺人行（32 头像、名字、• 月度听众、关注）与一行 #标签胶囊。
  - 中栏：9:16 卡片竖向轮播（卡宽 31% 对话框宽，上下各露出约 30px 的邻居）；有 Canvas 的卡片播静音循环视频，没有的只显示正方形封面（当前卡缩到 0.85）并在背后跳动均衡器竖条；不画官方那块 9:16 底色（滑动途中会在封面四周露出灰色方块）。
  - 右栏：静音 / 关闭；更多、复制链接、加入队列、保存；上一首（第一条时隐藏）/ 下一首（之后是小箭头）。首次翻页前，对话框右下角浮着会跳动的白色「下一首」胶囊（高 48、字号 16，宽度按文字自适应，不受右栏宽度限制）。
- 操作：↑ / ↓ 翻页，← 保存，→ 加入队列，M 静音，空格暂停 / 继续，Esc 关闭；滚轮一次只翻一页，触控板平移由轮播自身吸附；点非当前卡片跳过去。
- 声音：打开时暂停主播放、关闭时恢复（原本在播的话）；试听音量跟随主播放器音量；窗口切到后台时暂停。
- 跳转：点歌名或专辑封面 → 关闭本层，进入专辑并定位到这首；点艺人 → 关闭本层进入艺人页；点 #标签 → 在本层里换成该标签的 feed。
- 数据：实体 feed 走 Pathfinder `watchFeedEntity`（Web 播放器身份，不改平台头；每页 25 条，剩不足 5 条时预加载，最多加载到约 50 条）；#标签 feed 仍走 spclient `watch-feed-view`（服务端不接受 discovery-feed 作为 watchFeedEntity 的参数）。
- 对话框背景无论颜色来自服务端还是封面取色，组件结构都保持不变：结构一变，轮播会被整个重建并回到初始页（曾导致翻几首后跳回第一首、左栏与卡片对不上）。
- 未复刻：官方首页的视频卡片行、首次打开的快捷键说明气泡、卡片间的滚动视差。

## 原因

对 Spotify Android 9.2.0.26 全量反编译并对线上接口实测后确认：原版是以 #标签歌单为单位、由服务端组件驱动的音乐发现流，主入口在搜索页，素材是官方 Canvas 与 30 秒试听。完整分析（入口、协议字段、画面与动效参数、实测记录）见 `docs/DISCOVERY_FEED_ANALYSIS.md`。

## 设计约定

- 数据只走官方接口，不在本地拼装曲目列表；接口失败时入口隐藏、feed 页显示可重试的错误态，不弹错误提示。
- 平台身份：会话头沿用现有登录态（Bearer、client-token、语言），但 `app-platform` 声明为 `Android`（`spotify-app-version` 9.2.0.26）。实测保留 `WebPlayer` 时这些接口返回空内容。这是本功能最大的外部风险：Spotify 若校验 client-token 与平台一致，入口会整体隐藏（不影响其他功能）。
- 协议手写解析（`ProtoMsg` 宽松读取，未知组件跳过、损坏字节截断），不引入 protobuf 代码生成。
- 不新增依赖：视频沿用 InAppWebView `<video>`，改为直接流式播放 canvaz CDN 地址（不再整段下载转 base64），Linux 退回缩略图；试听用独立的 just_audio 播放器；官方的三段 Lottie（波形、上滑引导、保存彩纸）按关键帧用 CustomPainter / 动画组件自绘，取色复用 `ArtworkColorBuilder`。
- 曲目行与官方不同：官方点击即播放完整歌曲，这里改为打开所在专辑并定位到该曲（`AlbumDetailScreen.focusTrack`：按 id、其次按歌名匹配，定位时整张曲目表一次建好再 `ensureVisible`；只带 id / 名称的专辑进入后再补全艺人与发行信息）。从 feed 打开的页面压在 feed 之上，期间试听暂停。返回时若用户在那边开始了播放（主播放器在放），试听保持暂停、不打断，直到用户上下 / 左右翻到别的歌或轻点继续；否则 feed 重新接管声音、主播放暂停。
- feed 与其他详情页一样推入 Tab 内容区；移动端它是所在 Tab 的当前页时请求外壳隐藏底部导航与迷你播放栏（`ShellChrome`，按 Tab Navigator 记录请求），上面压了专辑等页面时撤回，那些页面照常显示边框。
- `AppRoutes._push` 在根 Navigator 上仍有全屏页（移动端设置页）时改为在其上方压栈，避免新页面被推到下面看不见。
- 暂不做：左右边缘按住 2 倍速、consumed_groups 上报、首页 / 正在播放页入口、实体页 explorer 按钮、标签云结尾页与调查问卷等其他布局。

## 代码位置

- 模型：`lib/models/watch_feed.dart`（入口卡片 / 卡片行 / 条目 / 画面 / 试听 / 艺人行 / #标签 / 曲目行 / 一页 feed）
- 协议：`lib/services/watchfeed/proto_tree.dart`（只读消息树与 Any）、`watch_feed_parser.dart`（browse / discovery-from-seed / feed 解析，`WatchFeedRequestSpec` 把 `spotify:watch-feed:…` 转成请求参数）、`watch_feed_service.dart`（HTTP、Android 身份头、请求编码）
- 试听：`lib/services/watchfeed/preview_player.dart`（`WatchFeedPreviewPlayer`）
- 入口：`lib/providers/spotify_provider.dart`（`loadDiscoverShelf` / `loadArtistSeedShelf`）、`lib/ui/screens/watchfeed/widgets/watch_feed_shelf_row.dart`（卡片行）、`lib/ui/screens/search/search_screen.dart`（搜索页）、`lib/ui/screens/detail/artist_detail_screen.dart`（艺人页）、`lib/ui/navigation/app_routes.dart`（`openWatchFeed`）
- feed 页：`lib/ui/screens/watchfeed/watch_feed_screen.dart`（横向关联 feed、顶栏、引导、竖向分页 `_FeedPager`）、`widgets/feed_item_card.dart`（单条卡片的画面、手势与叠加组件）、`widgets/feed_animations.dart`（波形、保存彩纸、上滑引导）
- 桌面版：`lib/ui/screens/watchfeed/desktop/desktop_watch_feed.dart`（`DesktopWatchFeed`：模态层、三栏、轮播、键盘）、`lib/ui/screens/watchfeed/widgets/watch_feed_entity_button.dart`（操作行入口）、`CollectionActionRow.afterPlay`、`WatchFeedService.fetchEntityFeed` / `WatchFeedParser.parseEntityFeed`、`SpotifyProvider.loadEntityFeed`
- 视频：`lib/ui/widgets/looping_video.dart`（`LoopingVideo`）
- 外壳边框开关：`lib/ui/shell/shell_chrome.dart`（`ShellChrome`）+ `lib/ui/screens/main_shell.dart`（移动端按请求去掉 bottomNavigationBar）
- 专辑定位：`lib/ui/screens/detail/album_detail_screen.dart`（`focusTrack`）、`AppRoutes.openAlbum(focusTrack:)`
- 一次性引导：`lib/services/storage_service.dart`（`watchFeedOnboardingShown` / `watchFeedPivotHintShown`）+ `lib/providers/preferences_provider.dart`
- 文案：`lib/l10n/app_zh.arb` 等四语（`watchFeedDiscoverTitle` / `watchFeedPaused` / `watchFeedMute` / `watchFeedUnmute`；复用 `likeAdd` / `likeRemove` / `commonMoreOptions` / `detailLoadFailed` / `commonRetry`）
- 测试：`test/watchfeed/desktop_watch_feed_test.dart`（实体 feed 解析、三栏、键盘、#标签、跳专辑、入口按钮）、`test/ui/album_focus_track_test.dart`（专辑定位与高亮）、`test/ui/shell_chrome_test.dart`、`test/watchfeed/`（`watch_feed_fixtures.dart` 按官方字段号合成响应；解析、请求编码、请求头、入口、feed 页交互）

## 复验命令

```sh
export PATH="$HOME/flutter/bin:$PATH"
flutter gen-l10n && git diff --stat lib/l10n/   # 生成物需与 arb 一致（提交前把 app_localizations*.dart 换回 CRLF）
flutter test --no-pub
flutter analyze --no-pub --no-fatal-infos lib test
flutter build macos --debug --no-pub
git -c core.whitespace=cr-at-eol diff --check
```
