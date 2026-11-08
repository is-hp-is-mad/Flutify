# Flutify 移动端原生 API 替换与对齐设计规范
## （基于 Spotify Android APK 9.1.98.621 最新版本）

> **生效版本**：Spotify Android **`9.1.98.621`**（最新发布版，17 个 DEX 分包，全新 Jam v3 与 Sneaktables 流媒体架构）。  
> **核心目标**：将 `D:\Flutify\app` 原有依赖的 **Web API (api.spotify.com)** 与部分 **桌面端 GraphQL (Pathfinder)**，全量升级替换为 **Spotify 官方移动端原生协议（SpClient WebGate + Login5 + Protobuf）**。  
> **核心收益**：
> 1. **彻底解除 Web API 限制**：不再受 429 Too Many Requests 限流，免除对 Spotify 开发者应用的依赖；
> 2. **原生无缝登录**：实现原生表单帐密登录，支持 `StoredCredentials` 凭据持久化，实现冷启动 **0ms 无感秒登**；
> 3. **响应性能倍增**：媒体库分页由 50 条/页提升至 300 条/页，歌单树单次请求完整输出，批量元数据支持一次性聚合多实体。

---

## 0. 全局调用规范与网络层改造

### 0.1 统一网关与协议基底
所有移动端业务 API（除主认证与 ClientToken 外）统一收口于 **SpClient WebGate** 网关：

```
Base URL: https://spclient.wg.spotify.com
```

每次请求的 HTTP Header 必须严格模拟 Android 9.1.98.621 原生客户端指纹：

| 请求头 (Header) | 取值 / 规范 | 说明 |
|---|---|---|
| `Authorization` | `Bearer <access_token>` | 登录态令牌（Login5 签发，寿命约 60 分钟） |
| `client-token` | `<client_token>` | 设备会话绑定令牌（由 `clienttoken.spotify.com` 签发） |
| `App-Platform` | `Android` | 平台标识（必须为 `Android`） |
| `Spotify-App-Version` | `9.1.98.621` | 最新官方版本号（对齐 APK 构建） |
| `User-Agent` | `Spotify/9.1.98.621 Android/34 (Pixel 7)` | 移动端原生 User-Agent |
| `Accept` | `application/x-protobuf, application/json` | 服务端优先返回 protobuf 压缩二进制 |
| `Accept-Language` | `zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7` | 用户当前本地化语言 |

---

## 1. 原生认证与会话管理 (Authentication & Login5)

### 现有实现 (`lib/services/auth/web_login_flow.dart`)
- 依赖 `accounts.spotify.com/authorize` + `/api/token`，需弹浏览器授权跳转，且无官方移动端权限。

### 9.1.98 原生对齐实现 (Native Login5 & ClientToken)

#### 1.1 获取客户端设备令牌 (ClientToken)
- **端点**：`POST https://clienttoken.spotify.com/v1/clienttoken`
- **请求类型**：Protobuf (`ClientDataRequest`)
- **载荷关键字段**：
  ```protobuf
  client_version: "9.1.98.621"
  client_id: "65b708073fc0480ea92a077233ca87bd"  // 移动端 ClientId
  connectivity_sdk_data {
    brand: "Google"
    model: "Pixel 7"
    os_version: "34"
    device_id: "<本地持久化 40位 hex device_id>"
  }
  ```
- **响应**：提取 `token`（即 `client-token`），持久化供后续请求使用。

#### 1.2 原生认证主请求 (Login5 v4)
- **端点**：`POST https://login5.spotify.com/v4/login`
- **请求体**：`spotify.login5.v4.LoginRequest`（Protobuf）
  - `ClientInfo`：包含 `client_id` 与绑定的 `device_id`。
  - `flow_id`：UUID v4。
  - `credentials`：
    1. **原生帐密登录（首次）**：
       ```protobuf
       credentials {
         password {
           id: "用户账号/邮箱",
           password: "用户密码"
         }
       }
       ```
    2. **免密凭据秒登（后续启动，推荐）**：
       ```protobuf
       credentials {
         stored_credential {
           username: "canonical_username",
           data: <本地加密保存的凭据字节串>
         }
       }
       ```
- **状态机与挑战处理**：
  - **`LoginOk`**：直接返回 `access_token` 与用户基础信息（昵称、邮箱、生日等）。
  - **`HashcashChallenge`**：后台使用 SHA-256 碰撞符合 `prefix` 的 `suffix`，0.1 秒内自动重发完成挑战。
  - **`CodeRequired`**：无缝切换至原生 6 位数字验证码 PIN 框，提交 `CodeSolution`。
  - **`Recaptcha`**：降级弹出轻量透明 BottomSheet 网页完成勾选。

#### 1.3 凭据持久化（StoredCredentials）
- 登录成功后将返回的凭据 blob 保存在本地安全存储（如 `credentials.json`）。
- 第二次打开 App 时直接走 `stored_credential` 换票，无需用户再次输入密码，**冷启动 150ms 内进入主页**。

---

## 2. 首页与内容发现 (Home Feed & Browse)

### 现有实现 (`SpotifyApiService.getHome()`)
- 调用 Web API 多个碎片接口（`/browse/featured-playlists`、`/browse/new-releases`）拼接，或依赖桌面 GraphQL `home`。

### 9.1.98 原生对齐实现 (Casita & Browsita)

#### 2.1 移动端原生首页信息流 (Casita)
- **端点**：`GET https://spclient.wg.spotify.com/casita/v1/home/{feedId}`
- **参数支持**：
  - `feedId` 为空：默认首页综合推荐。
  - `feedId=music-following-chip`：仅展示关注艺人与纯音乐流。
  - `feedId=podcasts-following-chip`：仅展示播客与有声书流。
- **返回模型**：`ResolvedHome`
  - `shortcuts`: 顶部 6 个最常用最近播放卡片（历史、日推、最常听歌单）。
  - `shelves`: 横向滑动推荐栏（每栏含标题、副标题、封面图、跳转 URI `spotify:playlist:xxx`）。
- **异步卡片内容加载**：`GET https://spclient.wg.spotify.com/casita/v1-beta/slot-content`

#### 2.2 发现与全部分类 (Browsita)
- **端点**：`GET https://spclient.wg.spotify.com/browsita/v1/browse`
- **功能**：替代 Web API 的 `/browse/categories` 与 `/browse/categories/{id}/playlists`。
- **返回体**：`ResolvedBrowse`，下发原生分类卡片、官方设计的代表渐变色值及 Hub 节点。

---

## 3. 搜索与即时联想 (Search & Autocomplete)

### 现有实现 (`SpotifyApiService.search()`)
- 调用 Web API `/search` 或桌面端 `searchDesktop`。

### 9.1.98 原生对齐实现 (SearchView v3)

#### 3.1 移动端原生聚合搜索
- **端点**：`GET https://spclient.wg.spotify.com/searchview/v3/search`
- **查询参数**：
  - `query`: 搜索关键词（如 `Daft Punk`）
  - `limit`: 单类条目数（默认 20）
  - `catalogue`: `premium` 或 `free`
  - `entity_types`: `tracks,albums,artists,playlists,podcasts`
- **返回模型**：`MainViewResponse`
  - 自动输出 **Top Result**（最佳匹配大卡片），并按单曲、专辑、歌手、歌单进行分层排列。

#### 3.2 搜索毫秒级联想 (Autocomplete)
- **端点**：`GET https://spclient.wg.spotify.com/searchview/v3/autocomplete`
- **查询参数**：`query={prefix}`
- **返回模型**：`AutocompleteViewResponse`，在用户每输入一个字符时即时返回搜索候选词列表。

#### 3.3 搜索首页默认推荐热词
- **端点**：`GET https://spclient.wg.spotify.com/recommended-searches/v1/recommendations`
- **返回模型**：`RecommendedSearches`，展示未输入状态下的探索卡片和热搜词。

---

## 4. 媒体库管理 (Your Library)

### 现有实现 (`WebApiLibrarySource` & `DesktopLibrarySource`)
- 分页受限于 50 条/页；桌面版会话走 `collection/v2/paging` 但需额外并发补全详情。

### 9.1.98 原生对齐实现 (Collection v2 & Rootlist)

#### 4.1 全量歌单树一次性拉取 (Rootlist)
- **端点**：`GET https://spclient.wg.spotify.com/playlist/v2/user/{username}/rootlist`
- **查询参数**：`decorate=attributes,owner`
- **优势**：单次请求返回用户自建歌单、收藏歌单、文件夹层级及排序信息，无需反复分页。

#### 4.2 已赞歌曲 / 收藏专辑 / 关注歌手 (Collection v2 Paging)
- **端点**：`GET https://spclient.wg.spotify.com/collection/v2/paging`
- **查询参数**：
  - `collection`: `tracks`（已点赞单曲）、`albums`（已收藏唱片）、`artists`（已关注歌手）
  - `limit`: 单页最大 300 条
  - `offset`: 偏移量
- **特性**：轻量 URI 数组，拉取效率较 Web API 提升 10 倍。

#### 4.3 收藏 / 点赞写入 (Collection v2 Write)
- **端点**：`POST https://spclient.wg.spotify.com/collection/v2/write`
- **请求体（JSON）**：
  ```json
  {
    "items": [
      {
        "uri": "spotify:track:69kOkLUCkxIZYexIgSG8rq",
        "action": "ADD"  // 取消点赞传 "REMOVE"
      }
    ]
  }
  ```

#### 4.4 歌单曲目增删改排 (Playlist4Api)
- **提交变更**：`POST https://spclient.wg.spotify.com/playlist/v2/playlist/{playlist_id}/changes`
- **更新项列表**：`PUT https://spclient.wg.spotify.com/playlist/v2/playlist/{playlist_id}/items`
- **请求体**：`Playlist4ApiProto.ListChanges`（支持添加曲目、指定插入索引、调整排序、删除曲目）。

---

## 5. 实体详情与元数据 (Catalog & Metadata)

### 现有实现 (`SpotifyApiService.getTrack/getAlbum/getArtist`)
- 逐个调 `/tracks/{id}`、`/albums/{id}` 等 Web API。

### 9.1.98 原生对齐实现 (Extended Metadata & Track View)

#### 5.1 批量实体扩展元数据 (Extended Metadata)
- **端点**：`POST https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata`
- **特性**：支持单次请求打包查询数十首歌曲、专辑与艺人的全套属性（时长、可用格式、文件指纹、专辑信息）。
- **请求体（Protobuf）**：
  ```protobuf
  message BatchedEntityRequest {
    repeated EntityHeader header = 1; // 填充 uri, 如 "spotify:track:xxx"
  }
  ```

#### 5.2 制作人员名单 (Track Entity View)
- **端点**：`GET https://spclient.wg.spotify.com/track-entity-view/v2/track/{id}`
- **功能**：替代 Pathfinder 的 `queryTrackCreditsGroupedModal`，完整返回词曲作者、制作人、工程师及录音版权信息。

---

## 6. 歌词与短视频背景 (Lyrics & Canvas)

### 现有实现 (`LyricsService` & `CanvasService`)
- 歌词调用 `/color-lyrics/v2`；Canvas 依赖桌面 GraphQL `canvas`。

### 9.1.98 原生对齐与升级 (Color Lyrics v2/v3 & Canvaz)

#### 6.1 官方逐字同步歌词 (Color Lyrics v2/v3)
- **主歌词端点**：`GET https://spclient.wg.spotify.com/color-lyrics/v2/track/{track_id}`
- **最新逐字时间轴端点**：`GET https://spclient.wg.spotify.com/color-lyrics/v3/track/{track_id}`
- **时间同步文本**：`GET https://spclient.wg.spotify.com/timesynced-text-distribution/v1/get-timesynced-text/spotify:track:{track_id}`
- **查询参数**：`format=json&clientLanguage=all&market=from_token`
- **字段解析**：
  - `lines`: 包含每一行的 `startTimeMs`, `words`，以及 `syllables`（字级别时间偏移）。
  - `colors`: 官方提取的背景色 `background` 与高亮色 `highlightText`，可直接用于毛玻璃背景渐变着色。

#### 6.2 移动端短视频背景 (Canvaz)
- **端点**：`GET https://spclient.wg.spotify.com/canvaz-view/v1/image/{track_uri}`
- **返回体**：包含直链 MP4 视频地址（`canvaz_url`），可直接用 VideoPlayer 循环无缝播放。

---

## 7. 播放控制、设备与 Spotify Connect

### 现状 (`ConnectService` & `ConnectStateClient`)
- 已具备 Dealer + ConnectState 雏形。

### 9.1.98 原生对齐规范

#### 7.1 WebSocket Dealer 长连接
- **连接 URL**：`wss://dealer.spotify.com/?access_token=<access_token>`
- **建立握手**：提取握手返回的 `X-Spotify-Connection-Id`。

#### 7.2 集群注册与设备状态 (Connect State)
- **注册移动端观察者**：
  `PUT https://spclient.wg.spotify.com/connect-state/v1/devices/hobs_{device_id}`
  - Header: `X-Spotify-Connection-Id: <connection_id>`
  - Body: 声明设备类型为 `SMARTPHONE`，启用双向音量与队列同步。
- **设备迁移切换 (Transfer)**：
  `POST https://spclient.wg.spotify.com/connect-state/v1/connect/transfer`
- **播控指令派发 (Player Command)**：
  `POST https://spclient.wg.spotify.com/connect-state/v1/player/command`
  - 支持指令：`play`, `pause`, `skip_next`, `skip_prev`, `seek_to`, `set_options`。

#### 7.3 Jam 一起听协议升级 (Social Connect v3 - 9.1.98 新增)
- **创建 Jam 房间**：`POST https://spclient.wg.spotify.com/social-connect/v3/sessions/new`
- **加入 Jam 房间**：`POST https://spclient.wg.spotify.com/social-connect/v3/sessions/join`
- **房间状态轮询/监听**：`GET https://spclient.wg.spotify.com/social-connect/v3/sessions/{sessionId}`

---

## 8. 协议音频流直接收听链路 (Native Audio Streaming)

在 9.1.98.621 中，Spotify 官方客户端同时支持**传统 AES-128-CTR 直链**与**新版 Sneaktables HLS 流**：

```
                    ┌─────────────────────────────────┐
                    │  1. 获取文件 ID (file_id)        │
                    │  extended-metadata: TRACK_V4    │
                    └────────────────┬────────────────┘
                                     │
           ┌─────────────────────────┴─────────────────────────┐
           ▼                                                   ▼
[模式 A：标准 AES-128-CTR 整轨下载]                 [模式 B：Sneaktables HLS 切片流]
1. storage-resolve 获取 CDN 直链                    1. 请求 sneaktables/v2/hls/4/{file_id}/audio.m3u8
2. 请求 playplay/v1/key/{file_id} 获得混淆密钥       2. 解析 HLS m3u8 分段
3. 本地 OVM 白盒解包 ──> 16B AES Key                3. 逐片下载播放（支持断点与动态码率）
4. AES-128-CTR (固定 IV) 解密
5. 剥离 167B 响度头 ──> 输出 Ogg Vorbis
```

- **音频解密固定 IV**：`72e067fbddcbcf77ebe8bc643f630d93`
- **响度元数据剥离**：解密后跳过前 `0xA7`（167 字节）Ogg 响度包，直接从 `OggS@0xA7` 交付音频解码器。

---

## 9. 接口替换速查全表 (Web API vs. 9.1.98 原生 API)

| 业务场景 | 原使用接口 (Web / GraphQL) | 9.1.98.621 原生接口 (SpClient / Login5) | 核心改进 |
|---|---|---|---|
| **用户登录** | `accounts.spotify.com/authorize` | `https://login5.spotify.com/v4/login` | 原生 UI、免网页弹窗、支持免密凭据秒登 |
| **设备令牌** | 无 | `https://clienttoken.spotify.com/v1/clienttoken` | 原生设备级会话绑定 |
| **主页推荐** | `/browse/featured-playlists` | `GET casita/v1/home/{feedId}` | 官方移动端 Feeds 流，支持多 Facet 分类 |
| **全部分类** | `/browse/categories` | `GET browsita/v1/browse` | 原生色彩方案与 Hub 聚合节点 |
| **全量搜索** | `/search?type=...` | `GET searchview/v3/search` | 移动端原生 Top Result 最佳匹配分层 |
| **搜索联想** | 无 | `GET searchview/v3/autocomplete` | 毫秒级即时输入自动补全 |
| **全量歌单** | `/me/playlists` (多次分页) | `GET playlist/v2/user/{username}/rootlist` | 一次性输出完整自建与收藏歌单树 |
| **已赞歌曲** | `/me/tracks` (限50条) | `GET collection/v2/paging?collection=tracks` | 单次拉取 300 条，性能提升 10 倍 |
| **点赞/收藏**| `PUT/DELETE /me/tracks` | `POST collection/v2/write` | 批量原子操作 (`ADD` / `REMOVE`) |
| **歌单操作** | `/playlists/{id}/tracks` | `POST playlist/v2/playlist/{id}/changes` | 原生批量事务变更，支持重排与移动 |
| **实体元数据**| `/tracks/{id}`, `/albums/{id}` | `POST extended-metadata/v0/extended-metadata`| 批量并发聚合查询单曲/专辑/歌手 |
| **制作人员** | Pathfinder 复杂查询 | `GET track-entity-view/v2/track/{id}` | 原生分角色词曲编曲与厂牌信息 |
| **逐字歌词** | `/color-lyrics/v2/track/{id}` | `GET color-lyrics/v3/track/{id}` | 逐字发音切片时间轴 + 原生背景渐变色 |
| **短视频背景**| Pathfinder `canvas` | `GET canvaz-view/v1/image/{track_uri}` | 直取竖屏 MP4 视频直链 |
| **播控与设备**| `/me/player/*` | `connect-state/v1/*` + Dealer WebSocket | 双向长连接实时状态推送与低延迟遥控 |
| **一起听** | 无 | `social-connect/v3/sessions/*` | 9.1.98 全新 Jam v3 多人同步收听 |
