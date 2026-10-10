# Flutify 🎵 - Spotify-Style Music Player (Google Material 3 Expressive)

> **当前版本：[最新发布（含 Beta）](https://github.com/is-hp-is-mad/Flutify/releases)** · 支持 Windows x64、Windows ARM64 与 Android；macOS 源码自测见 [MACOS.md](MACOS.md)
>
> 下载：[Releases](../../releases) 页面。Windows 解压后运行 `Flutify.exe`（需要 WebView2 运行时，Win11 自带）；
> Android 一般选 `arm64-v8a`，不确定时选 `universal`。
> 安装包由 GitHub Actions 自动构建（`.github/workflows/build.yml`），支持标签发布与手动指定版本发布。
>
> Android 使用 Media3 / 系统 Widevine 原生播放，Windows 播放使用 WebView2；
> 全曲播放可能遇到 Spotify 的许可证限流（HTTP 429），稍候再试即可。

Flutify 是一个采用 **Google Material 3 Expressive (MD3E)** 设计语言打造的高保真 Spotify 风格在线音乐播放器。专为**逆向 Spotify 移动端/桌面端协议与 API** 而设计，提供完整解耦的 API 数据层、真实曲目播放、账号媒体库、歌词同步与播放队列管理。

---

## 🌟 核心设计与特性

### 1. Google Material 3 Expressive (MD3E) 设计语言
* **富有张力的表面色阶 (Tonal Surface Hierarchy)**：采用 MD3E 深层色阶（`surfaceContainerLowest` 到 `surfaceContainerHighest`），搭配 Spotify 标志性高饱和度极光绿（`#1ED760`）与动感曲风渐变。
* **极具表现力的对比形态 (Expressive Shapes & Radii)**：
  - 胶囊药丸（Stadium Pill / 999dp）：用于分类过滤器、顶部药丸、播放按钮和搜索栏。
  - 宽圆角容器（24dp ~ 28dp）：用于流派卡片、专辑卡片及模态底栏。
* **MiSans 中英文统一字体 (Expressive Typography)**：内置小米 MiSans（400 / 500 / 600 / 700 四档字重，全量中日韩字形），中文放宽行高、取消负字距，大字重标题与正文同样清晰；不再运行时拉取网络字体。
* **界面语言**：支持简体中文、繁體中文、English、日本語和跟随系统；系统组件同步切换。部分历史登录及账号文案仍为硬编码中文，尚待迁入本地化资源。
* **动感反馈与波形动效**：正在播放的曲目带有实时跃动的均衡器波形动画（Waveform Visualizer）。

### 2. 全面适配 Spotify 核心业务与交互
* **主页 (Home)**：
  - 与官方客户端同一个 home 查询，按服务端分区原样还原（顺序、标题、条目都来自 Spotify）：
    吸顶筛选标签（全部 / 音乐 / 播客，选中后出现二级标签）→ 快捷入口（最多 8 个，宽屏 4 列、手机 2 列）
    → 普通卡架（可带艺人头像，条目多于已显示时有「显示全部」）→ 最近播放 → 推荐流网格（每张卡上方标注推荐理由）。
   - 请求的 `Accept-Language` 跟随界面：简体 `zh-CN`、繁体 `zh-TW`、英文 `en`、日语 `ja`，用于服务端分区标题与标签。
   - 支持下拉刷新及顶部刷新按钮，保留当前筛选；短列表和空列表也可下拉。刷新直接重新请求主页，并发操作合并，失败提示且保留旧内容；旧请求不得覆盖新筛选结果。浏览等实体缓存按语言区分。
  - 手机端标签栏左侧为头像（点按打开设置）；未登录时主页提示登录，而不是显示「加载失败」。
  - 播客可打开详情并播放单集；保留 `spotify:episode:` URI，支持外部 HTTPS 音频的 Range 按需读取与跳转，并保留受保护 MP4 播放路径。外部源须提供可靠长度；无长度的 chunked 响应暂不支持。
* **搜索与浏览 (Search & Browse)**：
  - 实时歌曲、艺人、歌单多类型搜索。
  - Spotify 经典 45° 倾斜封面的彩色流派分类卡（Pop、Hip-Hop、Rock、Dance、Chill 等）。
* **音乐库 (Your Library)**：
  - 置顶 "Liked Songs" 收藏歌单。
  - 标签式分类过滤（歌单 / 艺人 / 专辑 / 已下载）。
  - 排序及列表/网格视图切换。
  - 新建歌单快捷弹窗。
* **播放器系统 (Player Experience)**：
  - **Mini Player (悬浮胶囊)**：悬浮在毛玻璃底部导航之上，底色取封面主色，圆形封面 + 歌名 / 艺人 + 收藏与播放键，胶囊底边一条细进度线。
  - **Full Screen Player (全屏播放器)**：支持下拉收起、封面主色渐变（始终深色，状态栏浅色图标）、高灵敏度滑动进度条（Scrubber）、随机/单曲/列表循环三态切换。
    Android 从迷你播放器的实际边界连续扩大至全屏，上沿快、下沿慢并同时完成；共享封面从圆形平滑移动并变为圆角方形，小窗信息上移淡出，大窗信息与控件从底部升起。展开 600ms、收起 480ms，使用非线性曲线，支持中途反向与减弱动效；本机和 Connect 远程模式一致，其他平台与桌面对话框保持原有呈现方式。
    每次收起时，小窗标题独立重置到开头，完成收起后重新停留 4 秒再滚动，不恢复展开前的滚动位置或计时；按钮、系统返回和下拉收起共用此行为。
    中间区域可在「封面 / 歌词 / 播放队列」间切换（底部按钮，再点一次回到封面）；**左右滑动封面切歌**，小幅拖动松手回弹；内嵌歌词右上角可进入全屏歌词。
  - **播放失败提示**：未登录（带「登录」按钮）、曲目不可播放（说明已自动跳过）、网络错误（带「重试」按钮）均以统一的 MD3E 悬浮提示（`AppToast`，见下）告知，连续失败只保留最新一条。
    连续 3 首无法播放时自动暂停、不再跳过（设置 →「播放」可关闭），提示带「下一首」按钮。
  - **Spotify Connect 遥控**：观察端通过 dealer / connect-state 跟踪其他设备；本机播放端另通过 track-playback 注册到同账号设备列表（`services/connect/receiver/`）。可用操作取决于账号与服务端策略。
    - 设备面板（`device_picker_sheet.dart`）：桌面端贴在播放栏右下方，移动端为底部面板；
      顶部「当前收听设备」卡片（跳动音柱、远程音量滑块），下方其他设备，点按转移播放；
      远程在用时提供「此设备」：暂停远程，本机从同一首、同一进度继续。
    - 别的设备在出声（或远程已暂停而本机没有曲目）时，桌面播放栏与手机迷你播放器切换为远程模式
      （`widgets/connect/`）：曲目、进度按服务端快照推算、播放暂停 / 切歌 / 拖动进度 / 随机 / 循环 / 音量都发给远程设备；
      桌面播放栏下方多一条强调色「正在 {设备} 上播放」。
    - 远程模式下在本机点歌（单曲、详情页大播放按钮、搜索结果）默认在那台设备上播放（Connect `play` 命令）：
      歌单 / 专辑 / 艺人 / 已点赞的歌曲交给远程展开上下文，其余以临时列表播放（`services/connect/connect_play_request.dart`，
      经 `PlaybackProvider.remotePlay` 接管）；命令失败时回到本机播放。
    - 远程模式下歌词照常可用：右栏「正在播放」与其中的歌词卡、手机歌词面板（点远程迷你播放器打开）、沉浸式歌词都展示远程曲目，
      歌词按远程进度滚动（`ConnectProvider.position`），点行跳转与玻璃控制台作用于远程设备（`widgets/connect/now_playing_source.dart`）。
    - 命令被拒（免费账号部分操作）时弹出提示；Jam（一起听）需要 Premium，未实现。
    - 快捷键（空格、Ctrl+← / → / ↑ / ↓ / S / R）、键盘媒体键与系统媒体卡片（任务栏 / 锁屏 / 通知栏）同样跟随远程模式：
      卡片显示远程曲目与进度，按键发给远程设备（`widgets/connect/playback_shortcuts.dart`、`media_controls/connect_media_source.dart`）。
      控制权跟随「最后出声的一方」：暂停远程后再按空格仍继续远程，本机开始播放才交回本机。
  - **实时同步歌词 (Synced Lyrics)**：Apple Music iOS 风格——流动封面背景（`LyricsBackdrop`）、顶部信息胶囊与底部控制台采用液态玻璃（`LiquidGlass`），当前行清晰、上下句按行距逐级模糊变暗；手动滚动时全部变清晰，停手 3 秒后自动回到当前行；点击任意行跳转。
    **所有歌词界面同一套液态玻璃观感**：全屏歌词面板、全屏播放器的歌词视图（背景交叉淡入流动封面、控件收进玻璃）、桌面右栏歌词。
  - **桌面沉浸式歌词**（`immersive_lyrics_screen.dart`）：左侧大封面 + 玻璃控制台、右侧大字号歌词；鼠标静止 3 秒隐藏光标与按钮。
    两种铺满方式，右上角按钮或 F11 切换并记住选择：默认**只铺满窗口**（保留深色窗口按钮，顶部可拖动窗口），或进入系统全屏铺满整个屏幕；Esc 退出。
    入口：播放栏右侧、右栏歌词右上角、全屏播放器歌词、F11。
  - **歌词补全（LRCLIB）**（`services/lyrics/`，移植自原「任务栏歌词」项目）：Spotify 没有逐行同步歌词（只有纯文本或完全没有）时，
    从 [LRCLIB](https://lrclib.net) 开放歌词库补全，歌词底部注明来源。查询顺序：`/api/get` 精确匹配 → `/api/search` 曲名 + 第一位艺人 → 只按曲名 →
    全文 `q` 搜索（含简繁互换的曲名），请求间隔 600ms、429 / 5xx / 断网退避重试两次。
    **歌手对不上的同名歌直接排除**（LRCLIB 上同名歌很多，配错歌比没有歌词更糟；多位艺人拆开逐一比对，中文先统一简繁，本地化译名与原名文字不同时不判断），
    选词按**原唱语言**投票（同一首歌占多数的语言即原词，曲名 / 歌手只算小票，避免英文歌配上日文译词），翻译版 / 罗马音 / 双语对照降为备选，
    中文歌按曲名与歌手的字形对齐简繁（对照表 `zh_script_table.dart` 由 `tool/gen_zh_script_table.ps1` 调 Windows `LCMapStringEx` 生成）。
    结果按曲目 ID 存进应用数据目录 `lyrics_lrc/`；补全请求因网络失败时不缓存，下次再试。设置 → 歌词 →「补全歌词」可关闭。
  - **歌词译文**：保留完整官方 / 内嵌译词；需要外部中文译词时优先 QQ 音乐，其次网易云，启用补全时最后查 LRCLIB。部分译词只由不丢失已译行的更完整结果替换；预加载、手动与自动翻译共用规则，详见 [QQ_LYRICS.md](QQ_LYRICS.md)。没有调用机器翻译服务。
    目标语言跟随界面，简体和繁体分别匹配；默认跳过与界面同语言的原词，可配置额外排除语言（`zh` 排除两种中文，`zh-Hans` / `zh-Hant` 分别排除），也可关闭自动显示、手动显示或取消。
    Spotify 译词按原始行索引对齐并保留空行；LRCLIB 记录须通过曲名、艺人、时长与时间轴校验，双语记录还校验原文锚点。没有可靠匹配时显示无该语言译文，原词保留；LRCLIB 译文标明来源。
  - **Spotify Canvas**：全屏播放器和桌面详情封面支持官方 Canvas 视频、图片和 GIF，维持现有 MD3E 布局；视频静音循环，暂停、离开页面及减弱动效时停止。无 Canvas、加载失败或超限时使用静态封面。
    当前支持接口返回的 HTTPS 直接媒体 URL，单个媒体上限 12 MB、内存缓存最多 3 个；只返回 manifest / fileId 的记录尚未支持。原生 WebView 视频显示仍需实机验证。
  - **任务栏歌词（Windows）**：原「任务栏歌词」项目的原生 C++ 重写，嵌在 Win11 任务栏天气小组件右侧（`windows/runner/taskbar_lyrics*.cpp`），
    不需要单独的 exe。当前句大字、下一句小字，切句时上滚（300ms）；放不下时缩小或折成两行；无同步歌词时显示封面 + 歌名 + 播放控制。
    没取到歌词（网络抖动 / 限流）时 10 秒、30 秒、90 秒后各重试一次；App 内歌词页先取到时立即同步到任务栏（`SpotifyProvider.lyricsCached`）。
    悬停显示上一首 / 播放暂停 / 下一首，点击打开 Flutify，右键菜单「打开 Flutify / 重新获取歌词 / 关闭任务栏歌词」。
    它作为第二个系统媒体控制端挂在 `MediaControlsSync` 上（`MultiMediaControls`），因此和 SMTC 一样自动跟随本机 / Connect 远程播放，按键路由也相同。
    窗口跑在独立线程（跨进程子窗口会与 explorer 共享输入队列，不能占用 Flutter 主线程），UIA 定位小组件按钮，explorer 重启后自动重新嵌入。
    设置 → 任务栏歌词：开关（默认关闭）、文字颜色（自动按任务栏背景取黑 / 白、白、黑、跟随 Flutify 强调色、自定义）、不透明度，顶部带实时预览。
  - **播放队列管理器 (Queue)**：与 Spotify 一致的双层队列——"Next in queue"（用户手动添加，优先播放）+ "Next from: 上下文"，两段均支持拖拽排序、滑动删除、点击跳播、一键清空。
  - **播放上下文 (Playback Context)**：记录"正在从哪个歌单 / 专辑 / 艺人 / 搜索播放"，全屏播放器顶部显示「正在播放歌单」等，详情页播放键可在"播放整个上下文 / 暂停 / 继续"间切换。
  - **真随机与循环**：随机模式基于打乱的播放顺序表，切换时以当前曲目为起点重建；列表循环在末尾回绕，单曲循环重播。
  - **恢复上次播放**：重启后播放栏 / 迷你播放器直接显示上次的曲目，暂停在上次的进度；播放队列、播放来源、随机 / 循环一并还原，
    点播放从断点继续（还原后先拖进度条也会从拖到的位置开始）。启动时不下载音频。
    会话存在应用数据目录的 `playback_session.json`（`services/playback_session_store.dart`），只保存播放顺序中当前曲目前 20 首、后 200 首；
    切歌、排队、暂停、拖动时保存，播放中每 15 秒保存一次进度，桌面端关窗（含 Alt+F4）与手机切到后台时再保存一次。
* **详情页**：歌单（本地歌单可删除 / 滑动移除曲目）、专辑（发行信息、"More by"）、艺人（关注、热门曲目、唱片目录）。
  - 歌单曲目表格（桌面，`widgets/track_table/`）：吸顶列表头「# · 标题 · 专辑 · 添加日期 · 🕒」，列随宽度从右向左收起；
    点列名排序（再点反向、第三次回到自定义顺序），操作行右侧 🔍 歌单内搜索（歌名 / 艺人 / 专辑）与「排序方式 / 查看方式」菜单；
    紧凑视图去掉封面、艺人单独成列（偏好会记住）。播放按排序后的顺序；添加日期来自歌单条目 `attributes.timestamp`
    与收藏的 `added_at`，自动生成的歌单（daylist 等）没有该列。
  - 大头图（`CollectionHero`）：封面主色铺满头部并一直渐隐到操作行，没有硬边；宽屏为 232px 封面 + 自适应字号大标题（放不下时逐档缩小），手机为居中封面。
  - 向上滚动后收起为吸顶标题栏，带小号播放键。
  - 拿不到数据时显示「登录后即可查看」或「暂时无法加载」，带登录 / 重试按钮，不会一直转圈。
* **悬停与右键（桌面端）**：卡片悬停浮出绿色播放键（按下时由圆变圆角方形）；曲目行悬停时序号变 ▶、露出收藏与「⋯」；右键曲目弹出上下文菜单（加入歌单[二级菜单] / 收藏 / 加入队列 / 前往歌曲电台 / 前往艺人 / 前往专辑 / 查看制作人员 / 分享）。移动端长按曲目打开底部菜单（另含睡眠定时器）。
  - **歌曲电台**（`widgets/track_actions/song_radio.dart`）：spclient `inspiredby-mix/v2/seed_to_playlist` 取以该曲为种子的电台歌单，打开歌单详情页；没有电台时提示。
  - **制作人员**（`widgets/track_actions/track_credits_view.dart`）：Pathfinder `queryTrackCreditsGroupedModal`，按「艺人 / 作曲和作词 / 制作兼工程」等分组（分组与角色名由服务端按界面语言返回），同一人多个角色合并一行，有艺人页的可点进；桌面为对话框，移动端为底部面板。
  - 「从个人喜好资料中移除」暂未实现：未找到可靠的接口证据，不对账号做猜测性的写操作。
* **分享面板**（`ui/widgets/share/`）：曲目、歌单、专辑、艺人共用；桌面端为居中对话框，移动端为底部面板。
  快捷操作：复制网页链接、复制 Spotify URI、网页打开（失败时退回复制链接）；嵌入代码：标准 352 / 紧凑 152 高度、深色主题，
  预览为真实嵌入页（`embed_web_view.dart`，flutter_inappwebview；Windows 用 WebView2，缺运行时 / 加载失败 / 测试中退回示意预览），
  附可选中的 iframe 代码。Windows 构建需要 nuget，`windows/CMakeLists.txt` 在找不到时自动下载到 `build/`。复制反馈就地完成（按钮变为对勾 +「已复制」，徽章由圆形形变为圆角方形），不再弹底部提示。
  本地歌单、已点赞的歌曲没有公开链接，不显示分享入口（`models/share_target.dart`）。
* **深浅色**：默认跟随系统；浅色模式下药丸、播放键、详情页头部与状态栏图标都单独调过对比度。
* **自定义外观（设置页，修改即时生效并自动保存）**：手机为 iOS 分组样式；桌面端嵌在主框架内容区（保留顶栏、侧栏与播放栏），
  大标题 + 横向设置行（标题在左、控件在右），内容区 ≥ 1040px 时分左右两栏。滑杆拖动时只做局部预览、松手才应用到全局，主题切换不做插值动画（单帧完成）。
  - 主题模式（跟随系统 / 浅色 / 深色）、纯黑背景（OLED）；
  - 强调色：7 个预设 + HSV 自定义（十六进制输入），或「跟随封面取色」——强调色随正在播放的封面变化，并自动保证与背景的对比度（WCAG ≥ 3:1）；
  - 液态玻璃模糊强度 / 不透明度（带实时预览）、字号（85% – 130%）、圆角风格（圆润 / 标准 / 方正）、减弱动效（同时尊重系统设置）。
  - 实现：`AppearanceProvider` 生成主题，主题之外的参数通过 ThemeExtension `FlutifyTokens` 下发（`context.tokens`、`context.motion()`）。
* **其他设置项**（全部免费账号可用；非外观偏好统一存在 `AppPreferences`，由 `PreferencesProvider` 持久化，播放类偏好由 `PlaybackProvider` 持有）：
  - 语言：跟随系统 / 简体中文 / 繁體中文 / English / 日本語，切换后同时用新语言重新拉取主页等 Spotify 文案；窄屏或大字号时语言选项可横向滚动；
  - 歌词：字号（80% – 140%）、左对齐 / 居中、其他行模糊强度（可关）、LRCLIB 补全歌词、自动显示源译文及排除语言、全屏歌词默认铺满屏幕还是窗口；
  - 任务栏歌词（仅 Windows）：开关、文字颜色、不透明度；
  - 播放：音量均衡（读取 Spotify 文件头里的响度数据，只衰减偏响的歌）、歌曲间淡入淡出（0 – 12 秒，单播放器实现，两首不重叠）、Spotify Canvas；
  - 启动：打开主页 / 音乐库 / 上次位置；桌面端记住窗口大小、位置与最大化状态（显示器变化导致不可见时回到居中，`screen_retriever` 枚举显示器）；
    启动阶段不显示加载动画，基础初始化成功后直接进入应用（默认主页）；失败或超过 60 秒显示原因。存储、网络与窗口等基础初始化仍需完成，桌面 DRM WebView 延迟到首次受保护音频播放时创建。
  - Spotify Connect：总开关、设备名称（可一键使用本机设备名）、启动时同步播放状态、远程歌词提前量（±2 秒，只影响歌词切行）；
    本机同时作为 **Connect 播放端**（track-playback 协议，`services/connect/receiver/`）出现在同账号其他设备的设备列表里，
    可被手机 / 桌面版选中并遥控（播放、暂停、切歌、循环、随机、音量），本机的播放状态也会同步给其他设备；
  - 网络：代理「系统代理 / 不使用 / 手动」，即时生效、无需重启；「测试连接」请求一次 apresolve 显示耗时。
    全局 `HttpOverrides` 接管所有 HTTP / WebSocket，接入点的 TCP 连接经 HTTP CONNECT 隧道（`services/network/`）；
    系统代理在 Windows 读注册表 `Internet Settings`（含绕过列表，30 秒重读，Clash 等开关系统代理后自动跟随），其他平台读 `https_proxy` 等环境变量；
    只支持 HTTP 代理（不支持 SOCKS / PAC），本机回环地址始终直连，登录 WebView 跟随系统设置；
  - 存储：音频缓存占用、上限（256 MB – 5 GB，超出按最久未播放淘汰，正在播放与预取的下一首始终保留）、一键清除；
  - 隐私：清除搜索记录、清除歌词缓存（含 LRCLIB 本地缓存）；关于：版本、键盘快捷键一览（桌面端）、开源许可。
* **桌面端快捷键**：Space 播放/暂停、Ctrl+←/→ 切歌、Ctrl+↑/↓ 音量、Ctrl+S 随机、Ctrl+R 循环、Ctrl+K / Ctrl+L 聚焦搜索、Alt+←/→ 后退 / 前进、F11 沉浸式歌词、Esc 关闭浮层右栏 / 退出沉浸式歌词。
* **桌面鼠标交互**：鼠标侧键（后退 / 前进）与顶栏 ‹ ›、Alt+←/→、⌘[ / ⌘] 共用当前 Tab 的内容历史（`main.dart` 根部 `Listener` 捕获 `kBackMouseButton` / `kForwardMouseButton`，经 `AppRoutes.navigateBack / navigateForward` 派发）。
  根级弹窗、全屏播放器或沉浸歌词覆盖主界面时，历史导航回调不执行后退 / 前进；关闭覆盖页面后恢复，保留原内容页和前进栈。
  macOS 上 Logi Options+ 等驱动会把 MX 系列侧键作为「页面滑动」(swipe) 事件发送，Flutter 引擎不处理：由 `macos/Runner/MainFlutterWindow.swift` 的 `MouseNavigationChannel` 原生监听并消费 swipe，经 `flutify/mouse_navigation` 通道（`services/input/mouse_navigation_channel.dart`）接入同一历史桥；触控板双指左右滑同样生效。
  **鼠标指针约定**：可点击控件必须显示手型——自绘 `GestureDetector` 需包 `MouseRegion(cursor: SystemMouseCursors.click)`；`InkWell` / `InkResponse` 需显式传 `mouseCursor`（Material 3 桌面默认 `adaptiveClickable` 是箭头，仅 Web 为手型）；
  Material 按钮 / 菜单 / 弹出菜单 / 分段按钮由 `md3e_theme.dart` 主题统一覆盖为 `WidgetStateMouseCursor.clickable`；禁用态、拖拽把手（grab）、resize 把手与窗口标题栏按钮保持系统惯例。

### 3. 响应式外壳（桌面三栏 / 移动端）
* **窗口外框**（`window_frame.dart`，位于所有路由之上）：Win11 风格窗口按钮在任何页面（设置、登录、对话框）都可见；窗口最小可缩到 360×600，
  窄于 800px 时切换为移动端布局，顶部多一条 32px 标题条（拖动 + 窗口按钮），可直接在桌面上调试手机界面；沉浸式全屏时隐藏。
  退出系统全屏后强制刷新一次窗口尺寸（`DesktopWindow._refreshFrame`），绕过 window_manager 在 Windows 上
  从普通窗口进入全屏时不刷新子视图、退出后留下大片黑边的问题。
* **Win11 分屏布局**（`snap_layout_bridge.dart` + `windows/runner/snap_layout.cpp`）：自绘最大化按钮把自己的位置报给原生层，
  原生在该区域对 `WM_NCHITTEST` 返回 `HTMAXBUTTON`，鼠标悬停时弹出系统分屏布局；悬停 / 按下 / 点击由原生转回 Dart。
* **系统媒体控制**（`services/media_controls/`）：Windows 为自写 C++/WinRT SMTC（`windows/runner/media_controls.cpp`）——
  任务栏 / 锁屏 / 音量浮层媒体卡片、键盘媒体键、拖动进度；Android / iOS 用 audio_service（通知栏、锁屏、耳机线控）。
  runner 编译带 `/utf-8`，避免中文注释在 GBK 代码页下报 C4819。
* **≥ 800px 桌面三栏**（`ui/shell/desktop/`）：顶栏与标题栏合一（高 56，空白处拖动 / 双击最大化，右侧为窗口按钮留位）+ 后退前进、主页、居中搜索、头像（统一 40px 高）；
  macOS 原生交通灯由 `TrafficLightAligner.swift` 与 40px 控件中线对齐，同时扩展标题栏容器以保留完整点击区域；窗口缩放 / 退出全屏后在 AppKit 布局完成后重新对齐，全屏期间保留系统布局，宽窄布局切换不跳动。原生点击与缩放回归由 `tool/test_macos_titlebar.swift` 在 macOS CI 验证；
  左栏音乐库（筛选、库内搜索、排序，可拖宽，窄于 280px 或手动收起时变为 72px 图标栏；未登录显示登录引导）；
  右栏没有标签切换，分为两个面板：播放栏「播放状态」键打开「正在播放」（大封面、歌名、内嵌歌词卡、关于艺人、接下来播放；
  歌词卡右上角「放大」后撑满整个面板，偏好会记住，旁边是沉浸式歌词入口），队列键打开独立的「播放队列」面板；
  底部播放栏（窗口变窄时依次隐藏音量条、音量键，不溢出）。
* **统一提示**（`ui/widgets/toast/app_toast.dart`）：全 App 的底部提示都走 `AppToast`——反色悬浮胶囊、左侧按语气（信息 / 成功 / 注意 / 错误）
  区分的 MD3E 表现力形状图标块（入场弹簧缩放）、最多两行文字、胶囊操作键；新提示替换旧提示，带按钮的到时也会自动收起；桌面端居中显示在播放栏之上。
* **右栏形态**：≥ 1280px 停靠在内容右侧（开关状态持久化）；1100 – 1280px 为浮层，默认关闭，点空白处或 Esc 关闭，不遮挡内容。
* **< 800px 移动端**（`ui/shell/mobile/`）：内容铺到底部之下，毛玻璃底部导航 + 悬浮胶囊迷你播放器；页面底部留白按实际遮挡高度计算（`ContentBottomSpacer`）。
  手机（屏幕最短边 < 600）锁定竖屏，平板不限制（`core/utils/orientation_policy.dart`）。

---

## ⚡ 性能架构

* **播放进度独立通知**：`PlaybackProvider.positionNotifier`（`ValueNotifier<Duration>`）单独承载高频进度，只有进度条 / 歌词监听它；`notifyListeners` 仅在曲目、播放状态、队列等离散变化时触发。
* **精确订阅**：组件通过 `context.select` 订阅所需字段；`LibraryProvider` 采用写时复制列表，保证 `select` 比较稳定。
* **长列表**：曲目行未悬停时不构建 IconButton（每个自带 Tooltip / Focus / Ink 二十多个组件），只放同尺寸占位，悬停后才换成真按钮；歌单曲目用 `SliverPrototypeExtentList` 定高，滚动不逐行测量、总长度不靠估算；详情页头部按宽度缓存组件，滚动偏移变化不重建。
* **边下边播**（`services/protocol/progressive_download.dart` + `services/downloading_audio_source.dart`）：
  未缓存的曲目在 CDN 返回文件头（约 170 字节）后就开始播放，不再等整首下载完；数据边下载边解密到内存，
  播放器经 just_audio 本地代理按 Range 读取，拖到还没下载的位置时短暂缓冲。下载中途断线时按已收到的字节数用 HTTP Range 续传
  （AES-CTR 从任意偏移解密，`AesCtr.atOffset`），并轮换 CDN 地址，最多 4 次；仍失败时已缓冲部分播完并提示网络错误。
  下载完成后才写入缓存（先写 `.part` 再改名）；预取的下一首若还没下完就被点播，直接接着这份下载边下边播。
  边下边播时等当前曲目下完再预取下一首，不抢起播带宽。AES 逐块加密改为原地运算，解密整首不再产生几十万个临时数组。
* **后台解密**（`services/protocol/decrypt/`）：解密在启动时预热的常驻后台 Isolate 里进行（`IsolateDecryptBackend`），
  数据块用 `TransferableTypedData` 零拷贝往返，界面线程不再参与解密。解密方法与执行位置分离：`DecryptSpec` 描述怎么解
  （当前 `AesCtrDecryptSpec`），新增解密方法只需实现一个 `DecryptSpec` + `AudioDecryptor`，下载 / 续传 / 后台线程无需改动。
* **音频缓存**：下载完成时把 Spotify 私有头里的响度数据另存为同名 `.norm` 旁路文件（私有头会被剥掉，标准解码器不认识）；
  缓存命中时刷新文件修改时间，淘汰按修改时间从旧到新。功能上线前下载的旧缓存没有 `.norm`，按原音量播放。
* **图片解码降采样**：`CoverImage` 按显示尺寸 × DPR 设置 `memCacheWidth`，避免大图全尺寸解码。
* **歌词**：二分查找当前行，仅在行切换时重建；用户手动滚动后暂停自动滚动 3 秒。
* **搜索**：300ms 防抖 + 请求代次号，丢弃过期结果；歌词与封面取色均带缓存与并发合并。
* **防红屏**：`core/utils/error_placeholder.dart` 替换全局 `ErrorWidget`，单个组件构建失败只显示低调占位块；所有"无内容"区域统一使用 `EmptyState`，加载中使用 `skeleton.dart` 骨架屏。
* **嵌套导航**：每个 Tab 拥有独立 `Navigator`（`ui/navigation/tab_navigator.dart`），详情页不覆盖迷你播放器，切 Tab 保留页面栈。

---

## 🛠️ 为 Spotify 逆向工程深度适配

本项目的架构与 Spotify 官方数据模型及内部协议深度对齐：

| 模块 | 路径 | 逆向对接说明 |
| :--- | :--- | :--- |
| **API 路由注册表** | `lib/core/constants/spotify_endpoints.dart` | 包含所有 Spotify Web API 及 SpClient 内部端点（`/me`, `/me/player`, `/browse/*`, `/color-lyrics/*`） |
| **数据模型层** | `lib/models/` | `SpotifyTrack`, `SpotifyAlbum`, `SpotifyArtist`, `SpotifyPlaylist`, `SpotifyLyrics`, `SpotifyDevice` 均严格遵循 Spotify JSON 字段结构 |
| **API 服务层** | `lib/services/spotify_api_service.dart` | 支持带 `Bearer Token` 的网络请求，支持配置自定义代理或逆向服务。**不含任何示例 / Mock 数据**：未登录时搜索、媒体库等返回空结果，实体详情（歌单 / 专辑 / 艺人）失败时抛 `SpotifyDataException`，由界面展示错误与重试 |
| **完整曲目播放** | `lib/services/protocol/` + `audio_player_service.dart` | 纯逆向协议链路：extended-metadata（TRACK_V4）→ storage-resolve → AP 音频密钥（DH + Shannon 握手，`0xab` 令牌登录、`0x0c` 取密钥）→ CDN 下载 + AES-128-CTR 解密（边下边播，见「性能架构」）→ 去掉 Spotify 头部后交给 just_audio，下载完成后写入本地缓存。仅支持 OGG Vorbis / MP3；FLAC / AAC 属 Widevine DRM，会抛 `TrackPlaybackException`。`PlaybackProvider.playbackError` / `playbackErrors` 暴露错误，「不可播放」类自动跳下一首（有上限）；AP 连接会记住上次可用的接入点并重试多个候选 |
| **媒体库** | `lib/services/library/` | `LibrarySource` 抽象：桌面会话走 spclient `collection/v2/paging`（protobuf，已点赞歌曲 / 专辑 / 艺人）+ `playlist/v2/user/{u}/rootlist`（歌单）+ Pathfinder 补全曲目与实体；无桌面会话时走 Web API。点赞 / 收藏 / 关注乐观更新并尽力同步到账号（失败记入 `syncError`）；自建歌单仅保存在本机。未登录时媒体库为空 |
| **歌词** | `lib/services/lyrics_service.dart` | spclient `GET /color-lyrics/v2/track/{id}`，请求头沿用会话身份（桌面会话即桌面端头）；404 = 无歌词（可缓存），其他错误不缓存 |
| **歌词补全** | `lib/services/lyrics/` | `LyricsResolver` 合并官方与 LRCLIB：官方有逐行同步歌词直接用，否则查 LRCLIB；官方出错且 LRCLIB 也没有时抛原错误 |
| **协议登录** | `lib/services/auth/` | 桌面版 OAuth 使用浏览器登录、回环回调与 PKCE，刷新令牌并以桌面身份请求数据；Web DRM / track-playback 另用 Web 会话身份。Android 的桌面 OAuth 平台声明仍使用 Windows 回退值；不能把两套链路描述为统一的官方客户端身份。 |
| **桌面端数据层** | `lib/services/pathfinder/` | 桌面版 OAuth 会话下，公开 Web API（api.spotify.com）会因共享 client_id 频繁 429，因此改走官方桌面端自己的内部接口：Pathfinder GraphQL（`api-partner.spotify.com/pathfinder/v2/query`，持久化查询 hash 取自本机 `xpui.spa` 1.3.1.234）负责主页、分类、搜索、专辑、艺人、唱片目录与曲目补全；spclient `playlist/v2` 负责歌单（封面依次取 `pictureSize`、上传封面 `picture`、前几首曲目专辑封面拼的 `mosaic.scdn.co` 四宫格，见 `services/library/playlist_cover.dart`）、`user-profile-view/v3/profile/{用户名}` 负责昵称头像。桌面版令牌不含用户名，登录后用令牌登录一次 AP 取 canonical username（歌单根列表、收藏分页都按用户名寻址；注意 `profile/me` 是用户名为 "me" 的另一个账号，不能用）；旧版本缺用户名的会话启动时自动补齐并重新加载媒体库 |
| **探测脚本** | `tool/` | 纯 Dart 命令行探针（不属于 App）：`protocol_probe.dart`（播放链路端到端）、`live_probe.dart`（用本机已保存会话实测播放 / 媒体库 / 歌词）、`pathfinder_probe.dart`（Pathfinder 入参探测）、`ap_ports_probe.dart`（AP 网络可达性）。输出只写入 `tool/probe_out/`（已 gitignore，含账号数据，不得进入测试或文档） |

---

## 📂 代码目录结构

```
d:/Flutify/app/
├── lib/
│   ├── core/
│   │   ├── constants/
│   │   │   └── spotify_endpoints.dart    # Spotify 官方/SpClient 端点表
│   │   ├── theme/
│   │   │   ├── md3e_colors.dart          # MD3E 表面色阶与 Spotify 调色盘（深 / 浅两套）
│   │   │   ├── md3e_shapes.dart          # MD3E 胶囊与多级圆角规范
│   │   │   ├── md3e_typography.dart      # MiSans 字体规范（字重、中文行高与字距）
│   │   │   ├── md3e_theme.dart           # ThemeData（深 / 浅，缓存为 MD3ETheme.dark / light）
│   │   │   └── system_bars.dart          # 状态栏 / 导航栏透明 + 图标深浅随背景
│   │   └── utils/
│   │       ├── formatters.dart           # 时长、万/亿紧凑数字、发行日期、问候语（经 l10n 本地化）
│   │       └── artwork_palette.dart      # 封面主色提取（带缓存）
│   ├── l10n/                             # 界面文案（gen-l10n，配置见 l10n.yaml）
│   │   ├── app_zh.arb                    # 简体中文模板（新增文案先写这里）
│   │   ├── app_en.arb                    # 英文备用翻译，与模板保持同步
│   │   ├── app_zh_Hant.arb               # 繁体中文翻译，与模板保持同步
│   │   ├── app_localizations*.dart       # 自动生成，勿手改
│   │   ├── l10n.dart                     # context.l10n 扩展
│   │   ├── app_locale.dart               # 简体 / 繁体 / 英文 / 日语 / 系统语言解析
│   │   └── model_labels.dart             # 专辑类型、播放来源等模型字段 → 界面文案
│   ├── models/                           # Spotify 对应的数据模型
│   │   ├── track.dart, album.dart, artist.dart
│   │   ├── playlist.dart, lyrics.dart, device.dart
│   │   ├── lyrics_query.dart             # 查歌词的曲目信息（ID / 曲名 / 歌手 / 专辑 / 时长）
│   │   ├── playback_context.dart         # 播放上下文（歌单 / 专辑 / 艺人 / 搜索）
│   │   ├── playback_session.dart         # 上次播放会话（重启还原）
│   │   └── user_profile.dart, playback_state.dart
│   ├── services/
│   │   ├── auth/                         # Spotify 协议登录（对应 SpotifyApi/api-docs/01-认证与账号）
│   │   │   ├── spotify_auth_service.dart # 登录总控：浏览器授权、令牌持久化与并发合并续期、资料、登出
│   │   │   ├── oauth_pkce_service.dart   # OAuth 授权码 + PKCE（accounts.spotify.com）
│   │   │   ├── oauth_client_config.dart  # OAuth 客户端配置：桌面版 client_id、/login 回调与权限
│   │   │   ├── oauth_loopback_server.dart# 127.0.0.1:8898 回环接收授权回调
│   │   │   ├── client_profile.dart       # 客户端身份（Windows 桌面）：UA、平台头、client-token 平台数据
│   │   │   ├── account_profile_service.dart # profile-view/{用户名} 与 /v1/me 昵称头像
│   │   │   ├── client_token_service.dart # clienttoken.spotify.com 设备令牌申请
│   │   │   ├── hashcash.dart             # client-token 挑战的工作量证明求解（后台 Isolate）
│   │   │   ├── proto_codec.dart          # 无代码生成的极简 protobuf 编解码
│   │   │   └── auth_constants.dart       # 桌面版 client_id / 版本 / UA / 设备 ID
│   │   ├── pathfinder/                   # 桌面端内部接口数据层（桌面版 OAuth 会话使用）
│   │   │   ├── pathfinder_operations.dart# 持久化查询名 + sha256 hash（随桌面版升级需重新提取）
│   │   │   ├── pathfinder_client.dart    # GraphQL v2 请求与错误处理
│   │   │   ├── pathfinder_parsers.dart   # 响应 → App 数据模型（宽松解析、解包 Wrapper）
│   │   │   └── desktop_data_source.dart  # 页面级数据：主页/分类/搜索/专辑/艺人/歌单，5 分钟查询缓存
│   │   ├── protocol/                     # 完整曲目播放链路（AP 握手、音频密钥、CDN 解密、TrackAudioSource）
│   │   │   ├── progressive_download.dart # 边下边播：流式解密到内存、Range 续传、按区间读取
│   │   │   └── decrypt/                  # 可插拔解密：DecryptSpec（解法）+ DecryptBackend（内联 / 常驻后台 Isolate）
│   │   ├── network/                      # 网络代理：系统代理读取、全局选路（HttpOverrides）、CONNECT 隧道、测试连接
│   │   ├── media_controls/               # 系统媒体控制：Windows SMTC（原生通道）/ audio_service（Android、iOS）+ 播放状态同步
│   │   │                                 #   multi_media_controls.dart：多个控制端合一（SMTC + 任务栏歌词）
│   │   ├── lyrics/                       # LRCLIB 歌词补全：LRC 解析、文种识别、简繁对照、翻译版过滤、选词、磁盘缓存、合并器
│   │   ├── taskbar_lyrics/               # 任务栏歌词：原生通道（flutify/taskbar_lyrics）与作为媒体控制端的推送逻辑
│   │   ├── downloading_audio_source.dart # 把下载中的音频接到 just_audio（StreamAudioSource）
│   │   ├── playback_session_store.dart   # 上次播放会话（曲目 / 队列 / 进度）的文件存储
│   │   ├── library/                      # 媒体库来源：collection 编解码、rootlist 解析、桌面 / Web API 实现
│   │   ├── connect/                      # Spotify Connect：dealer 长连接与重连、connect-state 注册 / 命令、ConnectService 总控
│   │   ├── lyrics_service.dart           # spclient color-lyrics 取词与解析
│   │   ├── audio_player_service.dart     # 基于 just_audio 播放本地已解密文件
│   │   ├── spotify_api_service.dart      # 主页 / 搜索 / 实体详情（无 Mock；失败抛 SpotifyDataException）
│   │   └── storage_service.dart          # SharedPreferences 本地凭证持久化
│   ├── providers/
│   │   ├── auth_provider.dart            # 登录态：未登录 → 等待浏览器授权 → 已登录，错误中文化
│   │   ├── playback_provider.dart        # 播放状态、上下文、双层队列、随机/循环、音量
│   │   ├── library_provider.dart         # 收藏歌曲、歌单、关注艺人、收藏专辑（持久化）
│   │   ├── spotify_provider.dart         # 主页数据、防抖搜索、搜索历史、歌词缓存
│   │   ├── connect_provider.dart         # Connect 遥控：设备 / 远程播放状态、远程曲目补全、命令、音量节流
│   │   ├── preferences_provider.dart     # 非外观偏好（语言 / 歌词样式 / 启动页 / 窗口记忆 / Connect）
│   │   └── appearance_provider.dart      # 外观设置（主题 / 强调色 / 玻璃 / 字号 / 圆角 / 动效），防抖持久化
│   ├── ui/
│   │   ├── navigation/                   # Tab 内嵌 Navigator、统一跳转 AppRoutes、后退 / 前进历史 content_history
│   │   ├── shell/
│   │   │   ├── shell_breakpoints.dart    # 800 / 1100 / 1280 分档
│   │   │   ├── shell_layout_controller.dart # 左栏宽度 / 收起、右栏停靠与浮层开关、当前面板、歌词卡放大
│   │   │   ├── panel_surface.dart        # 三栏共用的圆角面板
│   │   │   ├── desktop/                  # 三栏总布局、顶栏、自绘标题栏与窗口按钮、音乐库左栏、右栏、拖宽手柄
│   │   │   └── mobile/mobile_bottom_bar.dart # 毛玻璃底部导航 + 悬浮迷你播放器
│   │   ├── screens/
│   │   │   ├── main_shell.dart           # 响应式主框架：持有导航 / 历史 / 搜索词 / 布局状态，分发到桌面或移动布局
│   │   │   ├── home/home_screen.dart     # 主页（按官方分区组装）；widgets/ 下为标签栏、快捷入口、卡架、推荐流
│   │   │   ├── search/search_screen.dart # 搜索与倾斜封面流派卡片
│   │   │   ├── library/library_screen.dart# 媒体库与已点赞歌曲
│   │   │   ├── detail/                   # 歌单、专辑、艺人详情页
│   │   │   │   └── widgets/              # collection_hero（大头图 + 吸顶栏 + 主色）、collection_widgets（操作行 / 占位）
│   │   │   ├── player/                   # 全屏播放器、全屏歌词、桌面沉浸式歌词、队列列表 queue_list 与设备列表
│   │   │   │   ├── lyrics/               # 歌词滚动区、单行、液态背景、玻璃控制台、玻璃圆按钮
│   │   │   │   └── widgets/swipeable_artwork.dart # 左右滑动切歌的封面
│   │   │   ├── auth/                     # 登录页 login_screen.dart（介绍 ↔ 等待授权两态）+ widgets/（主视觉 login_hero、
│   │   │   │                             #   介绍页、授权等待页、错误条、品牌标）
│   │   │   └── settings/                 # 设置页：账号卡片 + sections/（外观、强调色、液态玻璃、文字与形状、动效、
│   │   │                                 #   语言、歌词、播放、启动、Connect、网络、存储、隐私、关于）
│   │   │                                 #   + widgets/（分组、分段控件、滑杆行、色板、自定义取色、玻璃预览）
│   │   └── widgets/                      # MiniPlayer、TrackTile、CoverImage、PlaybackScrubber、
│   │                                     # PlayerControls、TrackOptionsSheet、CreatePlaylistDialog 等；
│   │                                     # track_menu（桌面右键菜单 / 移动端底部菜单）、hover_builder、
│   │                                     # playback_error_listener（播放失败提示）、toast/app_toast（统一提示）、content_bottom_spacer；
│   │                                     # track_actions/（歌曲电台、制作人员面板）；
│   │                                     # share/（分享面板、快捷操作卡片、嵌入代码区与预览、分享按钮）；
│   │                                     # connect/（远程播放栏、远程迷你播放器、进度推算、音柱、设备图标、本机 ↔ 远程协调）
│   └── main.dart
├── assets/fonts/MiSans/                  # MiSans Regular / Medium / Demibold / Bold（TTF）
├── l10n.yaml                             # gen-l10n 配置（模板 app_zh.arb）
└── test/
    ├── fixtures/sample_catalog.dart      # 合成曲库（虚构数据，不含任何账号内容）
    ├── fakes/                            # 音频 / 音频源 / 媒体库 / 数据服务的内存替身
    ├── ui/                               # 大头图、三种宽度（1440 / 1024 / 390）、移动端播放器、错误状态、外观设置与沉浸式歌词
    ├── audit/                            # 离屏渲染审查（默认跳过，见「代码分析与自动化测试」）
    ├── ui_flow_test.dart, widget_test.dart # 移动 / 桌面关键流程冒烟
    └── ...                               # Provider、协议、媒体库编解码等单元测试
```

---

## 🎨 品牌标识

连续曲率圆角方块（superellipse，n = 5）+ 薄荷 → 品牌绿 → 深青绿三段对角渐变（叠左上径向光泽）+
白色均衡器声波：三条全圆角竖波，中条最高、左右起伏。`tool/brand/generate_logo.py` 是唯一母版，运行 `python tool/brand/generate_logo.py`
（需要 Pillow）生成：

* `assets/brand/flutify_logo.svg`（矢量母版）、`flutify_glyph.svg`（单色字形）、`flutify_logo_1024.png`
* `windows/runner/resources/app_icon.ico`（16 – 256 px 共 10 个尺寸）
* Android 旧版启动图标 `mipmap-*/ic_launcher.png`，以及自适应图标（渐变背景 + 字形前景 + 单色主题图标）

App 内的 `FlutifyMark`（登录页、账号卡片）按同一组比例用 Canvas 绘制，修改几何时两处一起改。

---

## 🌐 语言与字体

### 简体、繁体、英文与日语界面（gen-l10n）
* `MaterialApp` 按偏好选择 `zh-Hans`、`zh-Hant`、`en`、`ja` 或跟随系统（`lib/l10n/app_locale.dart`），注册 Flutter 系统组件本地化代理；系统日语自动匹配 `ja`，系统 `zh-TW` / `zh-HK` / `zh-MO` 解析为繁体，其他不支持的语言回退简体。旧偏好值 `zh` 继续代表简体。
* 组件内统一使用 `context.l10n.xxx`（`import 'package:flutify_app/l10n/l10n.dart'` 或相对路径）；模型字段到文案的映射（专辑 / 单曲 / 合辑、「正在播放歌单」）放在 `l10n/model_labels.dart`，模型层不含界面语言。
* 服务层 / Provider 不依赖 `BuildContext`，其错误信息在 UI 层转换后再展示。登录页（`ui/screens/auth/`）与账号卡片的文案为直接书写的中文，尚未迁入 ARB。
* 用词参照 Spotify 中文版：主页 / 搜索 / 音乐库 / 已点赞的歌曲 / 正在播放 / 播放队列 / 歌词 / 随机播放 / 单曲循环 / 添加到歌单 / 关注。

**新增一条文案：**
1. 在 `lib/l10n/app_zh.arb` 添加键值（带占位符时写 `@键名.placeholders`，数量用 ICU `plural`，如 `"songCount": "{count, plural, other{{count} 首歌曲}}"`）；
2. 在 `lib/l10n/app_en.arb`、`lib/l10n/app_zh_Hant.arb` 和 `lib/l10n/app_ja.arb` 添加同名英文、繁体和日语译文；
3. 运行 `flutter pub get`（或直接 `flutter run` / `flutter gen-l10n`）重新生成 `app_localizations*.dart`；
4. 代码中使用 `context.l10n.键名`。

### MiSans 字体
* 来源：小米官方字体包（[hyperos.mi.com/font](https://hyperos.mi.com/font/)，`MiSans.zip` 中的全量 TTF），放在 `assets/fonts/MiSans/`，于 `pubspec.yaml` 注册为 `MiSans` 字族并设为 `ThemeData.fontFamily`。
* 字重映射：Regular 400、Medium 500、Demibold 600、Bold 700（每档约 7.5 MB，共约 30 MB）。代码中的 `w800` / `w900` 按字重匹配规则回落到 Bold——对中文标题而言比 MiSans Heavy 更通透。
* 排版：正文行高 1.5、标题约 1.3，`TextLeadingDistribution.even` 上下均分行距避免汉字被裁切；除展示级大字号外字距为 0（负字距会让汉字挤在一起）。
* **许可**：MiSans 由小米公司发布，依据《MiSans 字体知识产权许可协议》可免费用于个人与商业用途（含在软件中嵌入与分发）；不得对字体本身进行改编、二次开发或单独出售，字体版权归小米所有。完整协议以官网为准：<https://hyperos.mi.com/font/>。

---

## 🚀 运行与构建

使用本地 Flutter SDK (`D:\flutter-sdk\3.44.0\flutter\bin\flutter.bat`)：

### 1. 运行 Windows 桌面端
```powershell
cd d:\Flutify\app
& "D:\flutter-sdk\3.44.0\flutter\bin\flutter.bat" run -d windows
```

### 2. 运行 Android 端
```powershell
& "D:\flutter-sdk\3.44.0\flutter\bin\flutter.bat" run -d android
```

### 3. 登录 Spotify 账号
设置（主页头像 / 桌面端侧栏底部）→ 顶部账号卡片 →「登录」。登录成功后 App 自动切到真实数据，之后令牌过期会静默续期。

唯一的登录方式是**在浏览器中登录**（桌面版 OAuth）：登录页只有一个按钮，打开官方登录页，完成后自动回到 App。
人机验证、两步验证、Passkey、Google/Apple 等第三方登录均由官方页面处理；需要本机 8898 端口空闲。
等待授权时可重新打开浏览器、复制登录链接或取消。旧版本用账号密码 / 短信 / 一次性令牌 / 导入凭据 / 开发者应用登录的会话，
升级后视为未登录（残留凭据会被清除），需要重新在浏览器中登录一次。

登录页为 MD3E 表现力设计：主视觉是坐落在缓慢自转的十二瓣曲奇形与柔和爆裂形上的品牌标，三条安心说明放在大圆角卡片里，
等待授权时显示形状变换的加载指示器（`M3ELoadingIndicator`）；减弱动效时形状静止。

浏览器 OAuth 使用 PKCE，桌面数据请求统一从 `client_profile.dart` 取身份参数，令牌续期做并发合并；Connect 播放端使用本地持久化的随机设备 ID。
Web 播放和桌面数据认证仍是两套身份参数，平台回退、版本常量、网关出口与内部 API 兼容性仍有风险；这些工程修正不能证明或保证账号不受限制。

桌面版 OAuth 登录后，数据走桌面端内部接口（见上表「桌面端数据层」），Spotify Connect 遥控也只在这种会话下可用（dealer / connect-state）。
桌面客户端升级后若出现 `PersistedQueryNotFound`，可用 `tool/pathfinder_probe.dart` 探测并从新的 `xpui.spa` 重新提取 hash。

未实现：家庭儿童账号切换。
> 以官方客户端身份登录违反 Spotify 服务条款，仍存在风控可能，建议使用测试账号。

### 4. 代码分析与自动化测试
```powershell
& "D:\flutter-sdk\3.44.0\flutter\bin\flutter.bat" analyze
& "D:\flutter-sdk\3.44.0\flutter\bin\flutter.bat" test
```

离屏渲染审查（不打开任何窗口，在测试环境里按 390×844 手机竖屏深浅色各渲染一遍主要页面，外加桌面右栏歌词与沉浸式歌词；
图片写入 `build/audit/`，用于人工检查布局）：
```powershell
$env:FLUTIFY_AUDIT='1'; & "D:\flutter-sdk\3.44.0\flutter\bin\flutter.bat" test --update-goldens test/audit; $env:FLUTIFY_AUDIT=$null
```
> 测试环境下阴影不做模糊（`debugDisableShadows`），封面下方的实色"台阶"是测试渲染特有的，实机为柔和投影。

### 5. 云端构建（GitHub Actions）
本地没有 Android 开发环境也能出包：推送到 `main` 或手动运行 **Actions → Build** 只构建（产物在本次运行的 Artifacts 里）；
推送 `v*` 标签（如 `v0.04-beta`）构建完成后自动发布到 Releases，标签带 `beta` / `alpha` / `rc` 时标为预发布。

手动发布：在 **Actions → Build → Run workflow** 选择要发布的分支或标签，勾选 `publish_release`，填写 `release_tag`（例如 `v0.04-beta`）。
若该标签已存在，必须指向本次构建的提交。Windows x64、原生 ARM64 和 Android 全部构建及校验通过后才执行 **Publish release**，
发布两个 Windows 便携包、两个安装包、四个 Android APK 和 `SHA256SUMS.txt`。不勾选发布时跳过发布 Job 是预期行为。

macOS 使用单独的 FairPlay / WebKit 播放链路；CI 只上传未签名自测产物，不参与 Windows / Android 的 Release 发布，详见 [MACOS.md](MACOS.md)。

---

## ⚠️ 声明

本项目仅供学习与研究 Spotify 客户端协议，与 Spotify AB 无任何关联。以官方客户端身份登录与播放违反 Spotify 服务条款，
存在账号风控风险，请使用测试账号，并支持正版订阅。

## 📄 许可证

源代码以 [MIT License](LICENSE) 发布。随附的第三方组件（MiSans 字体、hls.js、Windows 版中的 libmpv / FFmpeg 等）
遵循各自的许可证，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 🙏 致谢

感谢 <a href="https://linux.do">LINUX DO</a> 社区。
