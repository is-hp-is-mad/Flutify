# 官方「Discover something new」竖滑发现流：逆向分析

> 依据：Spotify Android 9.2.0.26 全量 jadx 反编译（反编译产物路径下文简写 `J/`，未入库）、apktool 资源（`R/`）、以及 2026-11-02 用 Flutify 自身登录态对线上接口的实测。
> 原版是**以 #标签歌单为单位的音乐发现流**，主入口在**搜索页**，素材是**官方 Canvas + 30 秒试听**，画面与动效由服务端组件驱动。本文记录完整分析结论，作为复刻依据。

## 1. 入口在哪里

| 入口 | 证据 | 形态 |
|---|---|---|
| **搜索页 Browse「Discover something new」**（主入口） | `GET browsita/v1/browse`（`J/p/s9c.java`）；Section oneof `WatchFeed`=4（`J/com/spotify/browsita/v1/resolved/Section.java`）；组件 `watch-feed-entrypoint-card-browse-client-native` | 横滑卡片行，卡片 2:3，静音循环播放 Canvas，标题即标签：「Music for you」「#mellow indie」「#uptown vibes」「#mandopop」… |
| 首页 Home | casita `Section.WatchFeed`（`J/p/uqs.java:963`） | 同款卡片行 |
| 正在播放页下滑 | `GET watch-feed-entrypoints/v1/discovery-from-seed`（种子 = 当前曲目） | 「Explore {艺人}」卡片行：Songs by X / Similar to X / Similar to {歌名} |
| 艺人页 | `WatchFeedCarousel` 区块（`J/p/w2r0.java:90`） | 同款卡片行（服务端下发，不是主入口） |
| 曲目 / 艺人 / 专辑页头 | `EntityExplorerButton`（`R/layout/explorer_entrypoint_layout.xml`） | 32×40dp 竖版迷你视频缩略图 + Lottie 描边动画 |
| feed 内 #标签 | `Hashtag.navigation_uri` | 点标签进入该标签的 discovery feed（嵌套） |

实测（Flutify Web 令牌 + Android 平台头）`browsita/v1/browse` 第 3 个 section 即「Discover something new」，每张卡 = `DecoratedEntrypointMetadata{uri, firstItemUri, title(=#标签), thumbnail(video 首帧), videoFile(canvaz mp4), navigationUri, cover, decisionId}`。

## 2. 协议

- 通用：`https://spclient.wg.spotify.com/`，`Authorization: Bearer`、`client-token`、`Accept/Content-Type: application/protobuf`。
- **关键实测**：用 Flutify 现有的 Web 播放器令牌 + client-token，但把 `app-platform` 换成 `Android`（并带 `spotify-app-version: 9.2.0.26`、Android UA）后，所有接口返回真实内容；保留 `WebPlayer` 平台头时 discovery-from-seed 回 204、artist-clips 回空 200、tab-feed 400。
- `POST watch-feed-view/v1/feed`：`WatchFeedRequest{1 feed_id, 2 entity_id, 99 map parameters, 100 consumed_groups, 101 pagination{1 bytes token}}` → `WatchFeedResponse{1 Any header, 2 repeated Any items, 3 Any onboarding, 4 decision_id, 6 is_fullscreen, 99 pivoting{1 repeated additional_pages_uris}, 100 pagination{1 prev, 2 next token(bytes)}}`。
- feed URI → 请求（`J/p/twa.java:200-249`）：`spotify:watch-feed:<feedId>[:<entityId>][:k:v…]?query` → `feed_id`=第 2 段，剩余段数为奇数时下一段为 `entity_id`，其余 k/v 与 query 全进 `parameters`（`presentAsOverlay` 除外）。首页不需要 token；之后把响应 `pagination.next` 原样回填。实测一页 5 条。
- `GET watch-feed-entrypoints/v1/discovery-from-seed?entityUri&creatorUri&contextUri&isTablet` → `{1 Any WatchFeedVideoCarouselComponent{1 title, 2 repeated Any WatchFeedVideoCardComponent{1 title, 2 subtitle, 3 thumbnail_image_url, 4 navigate_uri, 8 entity_uri, 9 video_file{1 uri}, 10 accessibility_text, 11 overline, 12 decision_id}}}`。
- `GET browsita/v1/browse?timezone=` → ResolvedBrowse；Section 字段 4 = WatchFeed：`{1 header{1 title}, 2 repeated item{1 {uri, uri}, 2 DecoratedEntrypointMetadata{1 uri, 2 first_item_uri, 4 title, 6 thumbnail{1 url}, 7 video_file{1 url}, 8 navigation_uri, 9 accessibility, 10 cover{1 url}, 11 decision_id}}}`。
- `GET watch-feed-entrypoints/v1/pivots/explore` → 「Discover something new」bento（只有 feed uri + 首曲，无标题），不作为主数据源。

### 2.1 一条音乐条目（实测 `discovery-feed`，布局 = `WatchFeedTwoColumnsLayout`）

```
WatchFeedTwoColumnsLayout{1 item_id, 2 content(Any), 4 main_content_overlays[], 5 action_overlays[],
                          6 bottom_container_overlays[], 8 uri, 11 separated_bottom_container_overlays[]}
content  = CanvasContent{1 track_uri, 2 video_file{1 mp4 url}, 3 audio_file{1 cdn_url, 2 file_id}, 4 thumbnail{1 url}, 5 should_loop, 7 increase_volume_gradually}
         | TrackPreviewContent{1 entity_uri, 2 audio_file, 3 thumbnail(专辑封面), 4 animation_url(=playback-animation.json), 5 should_loop, 7 increase_volume_gradually}
main     = CallToActionRow(可选：即将发行) / CreatorRowComponent{1 artist uri, 2 visuals(头像), 3 title, 4 subtitle(粉丝数), 5 follow_action}
           / HashtagRowComponent{1 repeated Any<Hashtag{1 id, 2 title("#chamber pop"), 3 seed_item_uri, 4 navigation_uri, 5 decision_id}>}
           / BoxedEntityRowComponentV2{1 title, 2 subtitle, 3 image, 6 tap_action{play uri}, 7 a11y, 8 Any AddToCollectionButton}
action   = EntityShareButton、TrackContextMenuButton、AddToCollectionButton
bottom   = ProgressBarComponent
```

- 试听音频 = `cdn_url + file_id`（如 `https://p.scdn.co/mp3-preview/<id>`），公开 mp3，约 30 秒的副歌片段，无需鉴权。
- feed 头 `FeedHeaderComponent{5 MuteButton, 6 PivotingHeaderBody{1 repeated TextHeaderBody{2 title}}}`：标题依次为「Similar to {歌名}」「#folk」「#sad」…，对应横向可切换的关联 feed。
- `pivoting.additional_pages_uris`：实测 30 个 `spotify:watch-feed:discovery-feed:<id>?isAssociatedFeed=true`，**左右滑在这些 feed 之间切换**。
- `onboarding`：`VerticalOnboarding{"Swipe up to see more", delay 500ms, animation_url=fex.spotifycdn.com/vertical-onboarding-animation.json}` + `AssociatedFeedsOnboarding{"Swipe for more feeds", delay 5000ms, number_of_swipes 4}`。

## 3. 画面构成（反编译渲染器）

- **卡片**：整页最大 9:16，圆角 24dp；下一张从底部露出 6%（`discovery_feed_card_peek_percent`=0.06），页间距 8dp；相邻页透明度 `0.8 + 0.2 × (1 − |offset|)`；翻页弹簧 stiffness 400。
- **Canvas 条目**：缩略图垫底 + 视频层（循环、静音，声音另由试听播放）+ 叠加渐变 `#36000000@0 → 透明@20% → 透明@56% → #29000000@75% → #99000000@100%`。
- **无视频条目（TrackPreview）**，由后往前：① 整卡填专辑封面的取色（Palette MUTED → VIBRANT → 默认）；② 20% 黑色压暗；③ 波形 Lottie（全宽、左右 5dp、循环、仅当前页播放）；④ 正方形专辑封面卡，圆角 8dp、阴影 16dp，左右边距 70dp，长按隐藏 UI 时弹簧动画放大到 12dp。没有模糊、没有 Ken Burns。
- **波形动画**（`playback-animation.json`，已下载解析）：106×15、60fps、40 帧（0.67s）循环；20 根白色圆头竖条，宽 1.5、间距 5.5、垂直居中；每根高度在第 0/10/20/30/40 帧取关键值（ease in-out），例如第 1 根 5→12→8→10→5。
- **底部主列**（左，16dp 起始内边距、12dp 行距）：艺人行（头像 + 名字 + 粉丝数 + 关注按钮）→ #标签行（横滑、无底色、加粗 14sp、间距 16dp）→ 曲目行（半透明圆角 16dp 盒子，56dp 封面圆角 8dp、歌名 / 艺人、右侧 + 保存按钮；点击播放完整歌曲）。
- **右侧操作列**（64dp 宽，居中）：分享、更多（曲目菜单）、保存（+ / ✓ 动画，`save_now_positive_white`）、静音。
- **底部**：细进度条（可拖动，拖动时显示拇指）。
- **顶栏**：返回键 + 当前 feed 标题（随横向页切换）+ 页码指示点（选中为 24dp 宽胶囊、其余 6dp 点、`#33FFFFFF`）。

## 4. 动效

- 叠加层入场：条目变为当前页时，第 i 个叠加组件延迟 200ms × i，`translateY 8dp → 0` + 透明度 0 → 1，400ms，`Cubic(0.3, 0, 0.4, 1)`；离开当前页时复位。
- 手势：单击暂停 / 继续；双击 = 保存 + 中心 162dp 彩纸动画（`plus_selected_confetti`）；长按隐藏 UI（300ms 淡出）并放大封面；左右 20% 边缘区按住 2 倍速（本次不做）。
- 试听：`increase_volume_gradually` 时 5 秒淡入；`should_loop` 循环；不走主播放器。点曲目行 → 主播放器播放完整歌曲（PlayOrigin "watch-feed"），并暂停 feed。
- 竖滑引导：70% 黑罩 + 手指上滑动画（3s 循环：按下圆点放大 → 手指上移 → 拖尾）+ 加粗标题。横滑引导：屏幕 33% 高处「Swipe for more feeds」从右侧滑入（500ms），拖动 16dp 后 250ms 淡出。

## 5. Flutify 复刻取舍

- 数据走官方接口（新 `WatchFeedService`，手写 proto，复用 `proto_codec.dart` 与现有会话头，仅覆盖平台头为 Android）；接口失败则入口整体隐藏。
- 视频沿用 InAppWebView `<video>` 方案，但直接用 canvaz CDN 地址流式播放（不再整段下载转 base64）；Linux 退回缩略图。
- 试听用独立的 just_audio 播放器（与主播放器分离，进入 feed 时暂停主播放）。
- Lottie 不引入依赖：波形、手指引导、保存彩纸均按上面的关键帧用 CustomPainter / 动画组件自绘。
- 2 倍速、consumed_groups 上报、首页 / 正在播放页入口、实体页 explorer 按钮暂不做。

## 6. 桌面版（网页版抓包，2026-11-02）

依据用户提供的 open.spotify.com HAR（艺人页 → 打开视频流 → 翻看数条），网页版 1.3.9.137。

- 数据：Pathfinder `watchFeedEntity`（sha256 `d1a805f8…ac5c`），变量 `{watchFeedUri, limit: 25, offset}`，返回 `getWatchFeedForEntity{items[TrackResponseWrapper{data: Track}], totalCount, pagingInfo.nextOffset}`；Track 带 `canvas`、`previews.audioPreviews`、`discoveryFeedHashtags[{title, uri}]`（标题不带 #，界面用 CSS 补）、`albumOfTrack.coverArt.extractedColors.colorDark`、首位艺人的 `stats.monthlyListeners`。
- 实测：Flutify 的 Web 会话可直接调用，但必须带浏览器 User-Agent（缺 UA 返回 403 "Client/request not allowed"）；只接受实体 feed（artist / album / playlist），`discovery-feed` 报类型不符。艺人页入口数据为 `queryArtistOverview` 的 `artistUnion.watchFeedEntrypoint{entrypointUri, thumbnailImage}`；歌单页 `fetchPlaylistMetadata` 带 `enableWatchFeedEntrypoint: true`。
- 界面（`dwp-watch-feed-view-container` JS/CSS）：整窗模态，背景 `#000000e6`；对话框 `aspect-ratio 16/10; width: min(85%, min(1680px, 85vh*16/10))`，圆角 8，底色为封面深色 + `radial-gradient(circle at center right, #0000, base 35%)`；三栏（左右栏宽 86/128/160、内边距 16/24/32，断点 778 / 1102）；轮播 `width 41%; padding 0 5%; scroll-snap y mandatory; gap 15px`，卡片 9:16 圆角 12；无 Canvas 时封面 `scale(.85)` + 均衡器竖条；歌名切换 `y ±50%` 0.2s；「下一首」胶囊 0.8s 跳动；键盘 ↑↓←→ M Esc；关闭时恢复主播放。

