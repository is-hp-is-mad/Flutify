// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String playbackRetryWaiting(int attempt, int total, int seconds) {
    return '网络连接失败，$seconds 秒后第 $attempt/$total 次重试';
  }

  @override
  String playbackRetryRunning(int attempt, int total) {
    return '正在重新连接，第 $attempt/$total 次重试';
  }

  @override
  String get appTitle => 'Flutify';

  @override
  String get shellBack => '后退';

  @override
  String get shellForward => '前进';

  @override
  String get shellHome => '主页';

  @override
  String get shellSearchShortcut => 'Ctrl K';

  @override
  String get shellAccountMenu => '账号';

  @override
  String get shellCollapseLibrary => '收起音乐库';

  @override
  String get shellExpandLibrary => '展开音乐库';

  @override
  String get shellPlaybackStatus => '播放状态';

  @override
  String get shellHidePanel => '隐藏';

  @override
  String get shellAboutArtist => '关于艺人';

  @override
  String shellMonthlyFollowers(String count) {
    return '$count 位粉丝';
  }

  @override
  String get shellSignInTitle => '登录后查看你的音乐库';

  @override
  String get shellSignInMessage => '收藏的歌单、专辑和艺人会显示在这里。';

  @override
  String get shellSignIn => '登录';

  @override
  String get windowMinimize => '最小化';

  @override
  String get windowMaximize => '最大化';

  @override
  String get windowRestore => '向下还原';

  @override
  String get windowClose => '关闭';

  @override
  String get menuPlayback => '播放';

  @override
  String get menuNavigate => '导航';

  @override
  String get menuEdit => '编辑';

  @override
  String get menuUndo => '撤销';

  @override
  String get menuRedo => '重做';

  @override
  String get menuCut => '剪切';

  @override
  String get menuCopy => '拷贝';

  @override
  String get menuPaste => '粘贴';

  @override
  String get menuSelectAll => '全选';

  @override
  String get menuWindow => '窗口';

  @override
  String get menuSettings => '设置…';

  @override
  String get commonCancel => '取消';

  @override
  String get commonCreate => '创建';

  @override
  String get commonDone => '完成';

  @override
  String get commonClose => '关闭';

  @override
  String get commonClear => '清除';

  @override
  String get commonRemove => '移除';

  @override
  String get commonRetry => '重试';

  @override
  String get commonLoadMore => '加载更多';

  @override
  String get commonMoreOptions => '更多选项';

  @override
  String get commonShowAll => '显示全部';

  @override
  String get commonSeeMore => '查看更多';

  @override
  String get commonShowLess => '收起';

  @override
  String get commonSettings => '设置';

  @override
  String get commonShare => '分享';

  @override
  String subtitleJoin(String first, String second) {
    return '$first · $second';
  }

  @override
  String get navHome => '主页';

  @override
  String get navSearch => '搜索';

  @override
  String get navLibrary => '音乐库';

  @override
  String get typeTrack => '歌曲';

  @override
  String get typeArtist => '艺人';

  @override
  String get typePlaylist => '歌单';

  @override
  String get typePodcast => '播客';

  @override
  String podcastEpisodeCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 集',
    );
    return '$_temp0';
  }

  @override
  String get podcastPlayed => '已播完';

  @override
  String podcastResumeFrom(String position) {
    return '播至 $position';
  }

  @override
  String get podcastEmpty => '这个节目暂时没有单集';

  @override
  String get podcastLoadFailed => '节目加载失败，请检查网络后重试';

  @override
  String get typeAlbum => '专辑';

  @override
  String get typeSingle => '单曲';

  @override
  String get typeCompilation => '合辑';

  @override
  String get filterAll => '全部';

  @override
  String get filterMusic => '音乐';

  @override
  String get filterPodcasts => '播客';

  @override
  String get filterSongs => '歌曲';

  @override
  String get filterArtists => '艺人';

  @override
  String get filterPlaylists => '歌单';

  @override
  String get filterAlbums => '专辑';

  @override
  String songCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 首歌曲',
    );
    return '$_temp0';
  }

  @override
  String followerCount(String count) {
    return '$count 位粉丝';
  }

  @override
  String durationHoursMinutes(int hours, int minutes) {
    return '$hours 小时 $minutes 分钟';
  }

  @override
  String durationMinutesSeconds(int minutes, int seconds) {
    return '$minutes 分 $seconds 秒';
  }

  @override
  String countAndDuration(String count, String duration) {
    return '$count，$duration';
  }

  @override
  String get greetingMorning => '早上好';

  @override
  String get greetingAfternoon => '下午好';

  @override
  String get greetingEvening => '晚上好';

  @override
  String get likedSongs => '已点赞的歌曲';

  @override
  String get likedSongsDescription => '你喜欢的所有歌曲都在这里。';

  @override
  String get likeAdd => '添加到已点赞的歌曲';

  @override
  String get likeRemove => '从已点赞的歌曲中移除';

  @override
  String get libraryAdd => '保存到音乐库';

  @override
  String get libraryRemove => '从音乐库中移除';

  @override
  String get homeLoadFailedTitle => '无法加载推荐内容';

  @override
  String get homeLoadFailedMessage => '请检查网络连接后重试。';

  @override
  String get authSessionExpiredTitle => '登录已过期';

  @override
  String get authSessionExpiredMessage =>
      'Spotify 已让这次登录失效（例如在其他地方退出了所有设备或修改了密码），请重新登录。';

  @override
  String get authSignInAgain => '重新登录';

  @override
  String get homeEmptyTitle => '这里暂时没有内容';

  @override
  String get homeEmptyMessage => '换个筛选标签看看，或稍后再来。';

  @override
  String get homeClearFilter => '清除筛选';

  @override
  String get homePodcastUnsupported => '暂不支持播客，敬请期待';

  @override
  String get homeTypePodcast => '播客';

  @override
  String get homeTypeEpisode => '单集';

  @override
  String get searchHint => '你想听什么？';

  @override
  String get searchRecent => '最近搜索';

  @override
  String get searchClearAll => '全部清除';

  @override
  String get searchBrowseAll => '浏览全部';

  @override
  String get searchCategoriesFailedTitle => '无法加载分类';

  @override
  String get searchCategoriesFailedMessage => '请检查网络连接后重试。';

  @override
  String get searchFailedTitle => '无法加载搜索结果';

  @override
  String get searchFailedMessage => '请检查网络连接后重试，已加载的结果会保留。';

  @override
  String searchNoResultsTitle(String query) {
    return '未找到与“$query”相关的结果';
  }

  @override
  String get searchNoResultsMessage => '请检查拼写，或换个关键词试试。';

  @override
  String get searchFilterEmptyTitle => '该分类下暂无结果';

  @override
  String get searchFilterEmptyMessage => '换个筛选条件，查看更多结果。';

  @override
  String searchCategoryMix(String name) {
    return '$name 精选';
  }

  @override
  String searchCategoryMixDescription(String name) {
    return '精选 $name 好歌，新鲜好听。';
  }

  @override
  String get librarySearchHint => '在音乐库中搜索';

  @override
  String get libraryCloseSearch => '关闭搜索';

  @override
  String get libraryCreatePlaylist => '创建歌单';

  @override
  String get libraryClearFilter => '清除筛选';

  @override
  String get librarySortRecent => '最近添加';

  @override
  String get librarySortAlphabetical => '按字母顺序';

  @override
  String get libraryListView => '列表视图';

  @override
  String get libraryGridView => '网格视图';

  @override
  String get libraryEmptyTitle => '这里还没有内容';

  @override
  String get libraryEmptyMessage => '收藏的歌单、艺人和专辑会显示在这里。';

  @override
  String libraryNewPlaylistName(int number) {
    return '我的歌单 #$number';
  }

  @override
  String get playlistDelete => '删除歌单';

  @override
  String get playlistLikedEmpty => '你点赞的歌曲会显示在这里。\n点按爱心图标即可收藏歌曲。';

  @override
  String get playlistOwnEmpty => '来为你的歌单找些歌曲吧。\n在任意歌曲的菜单中选择“添加到歌单”。';

  @override
  String get playlistEmpty => '这个歌单还没有歌曲。';

  @override
  String get albumNoTracks => '这张专辑暂无可播放的曲目。';

  @override
  String albumMoreBy(String name) {
    return '$name 的更多作品';
  }

  @override
  String get artistPopular => '热门歌曲';

  @override
  String get artistNoPopular => '暂无热门歌曲。';

  @override
  String get artistNoAlbums => '暂无可显示的专辑。';

  @override
  String get artistNoSongs => '暂无可显示的歌曲。';

  @override
  String get artistDiscography => '作品';

  @override
  String get artistFollow => '关注';

  @override
  String get artistFollowing => '已关注';

  @override
  String get playingFromPlaylist => '正在播放歌单';

  @override
  String get playingFromAlbum => '正在播放专辑';

  @override
  String get playingFromArtist => '正在播放艺人';

  @override
  String get playingFromSearch => '正在播放搜索结果';

  @override
  String get playingFromLibrary => '正在播放音乐库';

  @override
  String get nowPlaying => '正在播放';

  @override
  String get openNowPlaying => '打开正在播放';

  @override
  String get playerNothingPlayingTitle => '当前没有播放内容';

  @override
  String get playerNothingPlayingMessage => '选择一首歌曲、专辑或歌单，开始收听吧。';

  @override
  String get playerIdleHint => '暂无播放 — 挑点音乐来听吧';

  @override
  String get playerThisDevice => '正在本设备上收听';

  @override
  String get playerShuffleOn => '开启随机播放';

  @override
  String get playerShuffleOff => '关闭随机播放';

  @override
  String get playerRepeatOn => '开启列表循环';

  @override
  String get playerRepeatOneOn => '开启单曲循环';

  @override
  String get playerRepeatOff => '关闭循环';

  @override
  String get playerNext => '下一首';

  @override
  String get playerPrevious => '上一首';

  @override
  String get playerMute => '静音';

  @override
  String get playerUnmute => '取消静音';

  @override
  String get playerLyricsFullscreen => '全屏歌词';

  @override
  String get playerSwipeHint => '左右滑动封面切换歌曲';

  @override
  String get playbackErrorSignIn => '登录后才能播放';

  @override
  String get playbackErrorWebSignIn => '全曲播放需要先完成 Web 登录';

  @override
  String get webLoginAction => 'Web 登录';

  @override
  String get webLoginSuccess => 'Web 登录成功，全曲播放已就绪';

  @override
  String playbackErrorUnavailable(String track) {
    return '「$track」暂时无法播放';
  }

  @override
  String playbackErrorSkipped(String track) {
    return '「$track」暂时无法播放，已跳过';
  }

  @override
  String playbackErrorNetwork(String track) {
    return '「$track」加载失败，请检查网络';
  }

  @override
  String playbackErrorWidevine(String track) {
    return '「$track」无法解密播放：此设备缺少 Widevine 组件';
  }

  @override
  String playbackErrorFairPlay(String track) {
    return '「$track」无法解密播放：此设备无法创建 FairPlay 会话';
  }

  @override
  String playbackErrorAutoPaused(int count) {
    return '连续 $count 首无法播放，已暂停';
  }

  @override
  String get detailSignInRequired => '登录后即可查看这里的内容';

  @override
  String get detailLoadFailed => '暂时无法加载，请检查网络后重试';

  @override
  String get queueTitle => '播放队列';

  @override
  String get queueNextInQueue => '队列中的下一首';

  @override
  String get queueClear => '清空队列';

  @override
  String get queueNextUp => '接下来播放';

  @override
  String queueNextFrom(String name) {
    return '接下来播放：$name';
  }

  @override
  String get queueEmpty => '队列中暂无待播歌曲';

  @override
  String get lyricsTitle => '歌词';

  @override
  String get lyricsNotPlaying => '未在播放';

  @override
  String get lyricsNothingPlayingMessage => '播放一首歌曲，即可在这里查看歌词。';

  @override
  String get lyricsUnavailableTitle => '暂无歌词';

  @override
  String get lyricsUnavailableMessage => '这首歌还没有歌词。\n尽情享受音乐吧！';

  @override
  String get lyricsUnsynced => '这些歌词尚未与歌曲同步。';

  @override
  String get lyricsFromLrclib => '歌词来自 LRCLIB';

  @override
  String get lyricsImmersive => '沉浸式歌词';

  @override
  String get lyricsExpand => '放大歌词';

  @override
  String get lyricsCollapse => '收起歌词';

  @override
  String get lyricsExitImmersive => '退出全屏歌词（Esc）';

  @override
  String get lyricsFillScreen => '铺满整个屏幕（F11）';

  @override
  String get lyricsFillWindow => '只铺满窗口（F11）';

  @override
  String get deviceConnectTitle => '连接到设备';

  @override
  String get deviceConnectDescription =>
      '通过 Spotify Connect，可在电脑、手机或智能音箱上无缝播放。';

  @override
  String get deviceCurrent => '当前收听设备';

  @override
  String get deviceSpotifyConnect => 'Spotify Connect';

  @override
  String get connectThisDevice => '此设备';

  @override
  String get connectTakeOver => '在此设备继续播放';

  @override
  String connectPlayingOn(String device) {
    return '正在 $device 上播放';
  }

  @override
  String get connectOtherDevices => '选择其他设备';

  @override
  String get connectNoDevices => '没有找到其他设备';

  @override
  String get connectNoDevicesHint => '在手机、电脑或音箱上打开 Spotify，并登录同一账号';

  @override
  String get connectUnavailable => '使用桌面版方式登录后，即可遥控其他设备上的 Spotify';

  @override
  String get connectConnecting => '正在连接 Spotify Connect…';

  @override
  String get connectOffline => '连接已断开，正在重试…';

  @override
  String get connectSameNetwork => '同一网络';

  @override
  String get connectCommandFailed => '操作未成功：免费账号可能不支持远程执行此操作';

  @override
  String connectVolumeUnsupported(String device) {
    return '$device 不支持远程调节音量';
  }

  @override
  String get connectVolume => '设备音量';

  @override
  String get trackAddToPlaylist => '添加到歌单';

  @override
  String get trackAddToQueue => '添加到播放队列';

  @override
  String get trackGoToAlbum => '前往专辑';

  @override
  String get trackGoToRadio => '前往歌曲电台';

  @override
  String get trackViewCredits => '查看制作人员';

  @override
  String get creditsTitle => '制作人员';

  @override
  String get creditsSources => '来源';

  @override
  String get creditsEmpty => '这首歌暂时没有制作人员信息';

  @override
  String get radioUnavailable => '这首歌暂时没有歌曲电台';

  @override
  String trackGoToArtist(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '前往艺人',
    );
    return '$_temp0';
  }

  @override
  String get trackNewPlaylist => '新建歌单';

  @override
  String get toastLikeAdded => '已添加到已点赞的歌曲';

  @override
  String get toastLikeRemoved => '已从已点赞的歌曲中移除';

  @override
  String get toastAddedToQueue => '已添加到播放队列';

  @override
  String get shareCopyLink => '复制链接';

  @override
  String get shareCopyUri => '复制 URI';

  @override
  String get shareOpenWeb => '网页打开';

  @override
  String get shareCopied => '已复制';

  @override
  String get shareEmbedTitle => '嵌入代码';

  @override
  String get shareEmbedSubtitle => '粘贴到网页 HTML 中，即可展示 Spotify 播放器';

  @override
  String get shareEmbedStandard => '标准';

  @override
  String get shareEmbedCompact => '紧凑';

  @override
  String get shareEmbedDark => '深色';

  @override
  String get shareEmbedCopy => '复制代码';

  @override
  String get shareEmbedUnavailable => '此设备的系统 WebView 暂不可用，仍可复制下方嵌入代码。';

  @override
  String get shareEmbedFailed => 'Spotify 嵌入播放器加载失败，请检查网络后重试。';

  @override
  String toastAddedTo(String name) {
    return '已添加到「$name」';
  }

  @override
  String toastAlreadyIn(String name) {
    return '「$name」中已有这首歌';
  }

  @override
  String get createPlaylistTitle => '为歌单命名';

  @override
  String get createPlaylistHint => '歌单名称';

  @override
  String get createPlaylistDefaultName => '我的歌单';

  @override
  String get settingsAppearanceSection => '外观';

  @override
  String get settingsThemeMode => '主题';

  @override
  String get settingsThemeSystem => '跟随系统';

  @override
  String get settingsThemeLight => '浅色';

  @override
  String get settingsThemeDark => '深色';

  @override
  String get settingsPureBlack => '纯黑背景';

  @override
  String get settingsPureBlackSubtitle => '深色模式下使用纯黑底色，OLED 屏幕更省电';

  @override
  String get settingsAccentSection => '强调色';

  @override
  String get settingsAccentCustom => '自定义颜色';

  @override
  String get settingsDynamicAccent => '跟随封面取色';

  @override
  String get settingsDynamicAccentSubtitle => '强调色随正在播放的专辑封面变化';

  @override
  String get settingsGlassSection => '液态玻璃';

  @override
  String get settingsGlassPreview => '玻璃预览';

  @override
  String get settingsGlassBlur => '模糊强度';

  @override
  String get settingsGlassOpacity => '不透明度';

  @override
  String get settingsTextShapeSection => '文字与形状';

  @override
  String get settingsFontScale => '字号';

  @override
  String get settingsFontPreview => '夜空中最亮的星';

  @override
  String get settingsCornerStyle => '圆角';

  @override
  String get settingsCornerRounded => '圆润';

  @override
  String get settingsCornerStandard => '标准';

  @override
  String get settingsCornerSquare => '方正';

  @override
  String get settingsPlaybackSection => '播放';

  @override
  String get settingsPauseAfterFailures => '连续无法播放时暂停';

  @override
  String settingsPauseAfterFailuresSubtitle(int count) {
    return '连续 $count 首无法播放就停下，不再继续自动跳过';
  }

  @override
  String get settingsMotionSection => '动效';

  @override
  String get settingsReduceMotion => '减弱动效';

  @override
  String get settingsReduceMotionSubtitle => '关闭流动背景、过渡与悬停等装饰性动画';

  @override
  String get settingsPowerSaving => '省电模式';

  @override
  String get settingsPowerSavingSubtitle => '玻璃改用磨砂底、歌词页背景不再流动；歌词滚动与动效全部保留';

  @override
  String get settingsFrameRate => '帧率上限';

  @override
  String get settingsFrameRateSubtitle => '降低可明显减少 GPU 占用，动画速度不变';

  @override
  String get settingsFrameRateFollow => '跟随屏幕';

  @override
  String get settingsFrameRateCustom => '自定义';

  @override
  String settingsFrameRateValue(int fps) {
    return '$fps fps';
  }

  @override
  String get settingsResetAppearance => '恢复默认外观';

  @override
  String get settingsCustomColorTitle => '自定义强调色';

  @override
  String get settingsHue => '色相';

  @override
  String get settingsSaturation => '饱和度';

  @override
  String get settingsBrightness => '亮度';

  @override
  String get settingsLanguageSection => '语言';

  @override
  String get settingsLanguage => '界面语言';

  @override
  String get settingsLanguageSubtitle => '同时影响主页推荐等由 Spotify 提供的文案';

  @override
  String get settingsLanguageSystem => '跟随系统';

  @override
  String get settingsLanguageZh => '简体中文';

  @override
  String get settingsLanguageEn => 'English';

  @override
  String get settingsStorageSection => '存储';

  @override
  String get settingsAudioCache => '音频缓存';

  @override
  String settingsAudioCacheUsage(String used, String limit) {
    return '已用 $used，上限 $limit';
  }

  @override
  String get settingsAudioCacheCalculating => '正在计算…';

  @override
  String get settingsAudioCacheLimit => '缓存上限';

  @override
  String get settingsAudioCacheLimitSubtitle => '超出后自动删除最久没播放的歌曲';

  @override
  String get settingsClearAudioCache => '清除音频缓存';

  @override
  String get settingsClearAudioCacheTitle => '清除音频缓存？';

  @override
  String get settingsClearAudioCacheMessage =>
      '已下载的歌曲会被删除，再次播放时重新下载。正在播放的歌曲会保留。';

  @override
  String settingsAudioCacheCleared(String size) {
    return '已释放 $size';
  }

  @override
  String get settingsLyricsSection => '歌词';

  @override
  String get settingsLyricsFocusPosition => '当前行位置';

  @override
  String get settingsLyricsFocusPositionSubtitle =>
      '调整当前歌词在可见歌词区域中的高度，数值越大越靠下。';

  @override
  String get lyricsTranslationFromNetease => '译词来自网易云音乐社区';

  @override
  String get lyricsTranslationFromQqMusic => '译词来自 QQ 音乐';

  @override
  String get settingsLyricsSize => '歌词字号';

  @override
  String get settingsLyricsAlign => '对齐方式';

  @override
  String get settingsLyricsAlignLeft => '左对齐';

  @override
  String get settingsLyricsAlignCenter => '居中';

  @override
  String get settingsLyricsBlur => '其他行模糊';

  @override
  String get settingsLyricsImmersiveScreen => '全屏歌词铺满整个屏幕';

  @override
  String get settingsLyricsImmersiveScreenSubtitle =>
      '关闭时只铺满窗口；在全屏歌词里按 F11 也能切换';

  @override
  String get settingsLyricsFallback => '补全歌词';

  @override
  String get settingsLyricsFallbackSubtitle =>
      'Spotify 没有逐行同步歌词时，从 LRCLIB 开放歌词库补全，并按原唱语言挑选';

  @override
  String get settingsLyricsBilingual => '社区歌词翻译';

  @override
  String get settingsLyricsBilingualSubtitle =>
      '加载歌词时预取中文译词，优先 QQ 音乐，缺失或不完整时查网易云，启用补全时最后查 LRCLIB，也供任务栏歌词使用。关闭后仍可手动或自动查询；曲名与歌手会发送到查询来源。';

  @override
  String get settingsTaskbarLyricsSection => '任务栏歌词';

  @override
  String get settingsTaskbarLyrics => '在任务栏显示歌词';

  @override
  String get settingsTaskbarLyricsSubtitle =>
      '任务栏图标居中时显示在左侧，居左时显示在系统托盘左边；任务栏竖向时自动停用。悬停显示播放控制，点按打开 Flutify，右键重新获取歌词';

  @override
  String get settingsTaskbarLyricsColor => '文字颜色';

  @override
  String get settingsTaskbarLyricsCustomColor => '自定义颜色';

  @override
  String get settingsTaskbarLyricsChangeColor => '更改';

  @override
  String get settingsTaskbarLyricsOpacity => '不透明度';

  @override
  String get settingsTaskbarLyricsFontSize => '字号';

  @override
  String get settingsCopyLog => '复制诊断日志';

  @override
  String get settingsCopyLogSubtitle => '反馈问题时粘贴给开发者；日志只含运行记录，不含密码';

  @override
  String get settingsCopyLogDone => '日志已复制到剪贴板';

  @override
  String get settingsCopyLogEmpty => '暂无日志';

  @override
  String get taskbarLyricsColorAuto => '自动';

  @override
  String get taskbarLyricsColorWhite => '白色';

  @override
  String get taskbarLyricsColorBlack => '黑色';

  @override
  String get taskbarLyricsColorAccent => '强调色';

  @override
  String get taskbarLyricsColorCustom => '自定义';

  @override
  String get taskbarLyricsMenuOpen => '打开 Flutify';

  @override
  String get taskbarLyricsMenuRefetch => '重新获取歌词';

  @override
  String get taskbarLyricsMenuDisable => '关闭任务栏歌词';

  @override
  String get taskbarLyricsPreviewLine1 => '歌词会在这里随歌声滚动';

  @override
  String get taskbarLyricsPreviewLine2 => '悬停即可切歌、暂停';

  @override
  String get taskbarLyricsPreviewLine3 => '颜色与不透明度即时生效';

  @override
  String get settingsOff => '关';

  @override
  String get settingsNormalize => '音量均衡';

  @override
  String get settingsNormalizeSubtitle => '按 Spotify 提供的响度数据，把偏响的歌调低到一致的音量';

  @override
  String get settingsFade => '歌曲间淡入淡出';

  @override
  String get settingsFadeSubtitle => '结尾逐渐淡出，下一首淡入';

  @override
  String settingsSeconds(int count) {
    return '$count 秒';
  }

  @override
  String get settingsStartupSection => '启动';

  @override
  String get settingsStartPage => '启动时打开';

  @override
  String get settingsStartPageHome => '主页';

  @override
  String get settingsStartPageLibrary => '音乐库';

  @override
  String get settingsStartPageLast => '上次位置';

  @override
  String get settingsRememberWindow => '记住窗口大小和位置';

  @override
  String get settingsRememberWindowSubtitle => '下次启动时还原；显示器变化导致窗口不可见时回到屏幕中央';

  @override
  String get settingsConnectSection => 'Spotify Connect';

  @override
  String get settingsConnectEnabled => '启用 Spotify Connect';

  @override
  String get settingsConnectEnabledSubtitle => '显示并遥控同一账号在其他设备上的播放';

  @override
  String get settingsConnectDeviceName => '设备名称';

  @override
  String get settingsConnectDeviceNameSubtitle => '其他设备的设备列表里显示的名字，留空使用默认名';

  @override
  String get settingsConnectUseDeviceName => '使用设备名称';

  @override
  String get settingsConnectReportOnLaunch => '启动时同步播放状态';

  @override
  String get settingsConnectReportOnLaunchSubtitle =>
      '打开 Flutify 后即使还没播放，也让其他设备看到 Flutify 上的当前歌曲（会接管正在空闲的播放会话）';

  @override
  String get settingsRemoteLyricsLead => '远程歌词提前';

  @override
  String get settingsRemoteLyricsLeadSubtitle => '其他设备上播放时，歌词比演唱慢就调大，快就调小';

  @override
  String get settingsNetworkSection => '网络';

  @override
  String get settingsProxy => '代理';

  @override
  String get settingsProxySystem => '系统代理';

  @override
  String get settingsProxyNone => '不使用';

  @override
  String get settingsProxyManual => '手动';

  @override
  String settingsProxySystemDetected(String endpoint) {
    return '当前系统代理：$endpoint';
  }

  @override
  String get settingsProxySystemEmpty => '系统未设置代理，直接连接';

  @override
  String get settingsProxySystemAuto => '系统使用自动代理配置（PAC / 自动检测）';

  @override
  String get settingsProxyNoneSubtitle => '所有请求直接连接，不经过代理';

  @override
  String get settingsProxyManualSubtitle => '填写 HTTP 代理的地址与端口';

  @override
  String get settingsProxyServer => '代理服务器';

  @override
  String get settingsProxyHostHint => '127.0.0.1';

  @override
  String get settingsProxyPortHint => '端口';

  @override
  String get settingsProxyInvalid => '请填写有效的地址和 1–65535 之间的端口';

  @override
  String get settingsProxyAuth => '代理认证（可选）';

  @override
  String get settingsProxyUsernameHint => '用户名';

  @override
  String get settingsProxyPasswordHint => '密码';

  @override
  String get settingsProxyUsernameInvalid =>
      '用户名不能包含冒号（:），冒号是用户名与密码的分隔符，代理会认证失败';

  @override
  String get settingsProxyAuthIncomplete =>
      '用户名和密码只填一项时，HTTPS 可用；HTTP 代理认证需要两项都填写';

  @override
  String get settingsProxyTest => '测试连接';

  @override
  String get settingsProxyTesting => '正在连接 Spotify…';

  @override
  String settingsProxyTestOk(int ms) {
    return '连接正常，用时 $ms 毫秒';
  }

  @override
  String settingsProxyTestFailed(String error) {
    return '连接失败：$error';
  }

  @override
  String get settingsProxyFootnote =>
      '仅支持 HTTP 代理（Clash、v2rayN 等的混合端口即可）；手动代理可填用户名 / 密码，适合自建带认证的跨区反代。登录页面始终跟随系统代理设置。';

  @override
  String get settingsPrivacySection => '隐私';

  @override
  String get settingsClearSearchHistory => '清除搜索记录';

  @override
  String settingsSearchHistoryCount(int count) {
    return '$count 条记录';
  }

  @override
  String get settingsSearchHistoryEmpty => '没有搜索记录';

  @override
  String get settingsClearLyricsCache => '清除歌词缓存';

  @override
  String get settingsClearLyricsCacheSubtitle => '清除后重新从 Spotify 获取歌词';

  @override
  String get settingsCleared => '已清除';

  @override
  String get settingsAboutSection => '关于';

  @override
  String get settingsVersion => '版本';

  @override
  String get settingsShortcuts => '键盘快捷键';

  @override
  String get settingsLicenses => '开源许可';

  @override
  String get shortcutPlayPause => '播放 / 暂停';

  @override
  String get shortcutNext => '下一首';

  @override
  String get shortcutPrevious => '上一首';

  @override
  String get shortcutVolumeUp => '调高音量';

  @override
  String get shortcutVolumeDown => '调低音量';

  @override
  String get shortcutShuffle => '随机播放';

  @override
  String get shortcutRepeat => '切换循环模式';

  @override
  String get shortcutSearch => '搜索';

  @override
  String get shortcutBack => '后退';

  @override
  String get shortcutForward => '前进';

  @override
  String get shortcutImmersive => '全屏歌词';

  @override
  String get shortcutImmersiveMode => '全屏歌词中：切换铺满屏幕 / 窗口';

  @override
  String get shortcutExitImmersive => '退出全屏歌词';

  @override
  String get accountTitle => 'Spotify 账号';

  @override
  String get accountSignedOutMessage => '登录后同步你的音乐库';

  @override
  String get accountSignIn => '登录';

  @override
  String get accountSignOut => '退出登录';

  @override
  String get accountSignOutTitle => '退出登录？';

  @override
  String get accountSignOutMessage => '将清除本机保存的登录信息与媒体库缓存，退出后需重新登录才能播放和查看媒体库。';

  @override
  String get accountSignOutConfirm => '退出';

  @override
  String get sleepTimer => '睡眠定时器';

  @override
  String sleepTimerMinutes(int count) {
    return '$count 分钟';
  }

  @override
  String get sleepTimerHour => '1 小时';

  @override
  String get sleepTimerEndOfTrack => '本首结束时';

  @override
  String get sleepTimerOff => '关闭定时器';

  @override
  String sleepTimerRemaining(String time) {
    return '睡眠定时器：剩余 $time';
  }

  @override
  String get sleepTimerEndOfTrackActive => '睡眠定时器：本首结束时暂停';

  @override
  String toastSleepTimerSet(String label) {
    return '睡眠定时器已设为「$label」';
  }

  @override
  String get toastSleepTimerOff => '睡眠定时器已关闭';

  @override
  String shortcutOnHoveredTrack(String action) {
    return '悬停曲目时：$action';
  }

  @override
  String get trackColumnTitle => '标题';

  @override
  String get trackColumnArtist => '艺人';

  @override
  String get trackColumnAlbum => '专辑';

  @override
  String get trackColumnAddedAt => '添加日期';

  @override
  String get trackColumnDuration => '时长';

  @override
  String get trackSortBy => '排序方式';

  @override
  String get trackSortCustom => '自定义顺序';

  @override
  String get trackViewAs => '查看方式';

  @override
  String get trackViewList => '列表';

  @override
  String get trackViewCompact => '紧凑';

  @override
  String get trackSearchHint => '在歌单中搜索';

  @override
  String get trackSearchClose => '关闭搜索';

  @override
  String trackSearchNoResults(String query) {
    return '找不到「$query」';
  }

  @override
  String get addedToday => '今天';

  @override
  String addedDaysAgo(int count) {
    return '$count 天前';
  }

  @override
  String addedWeeksAgo(int count) {
    return '$count 周前';
  }

  @override
  String get settingsGateway => 'Spotify 反代';

  @override
  String get settingsGatewayDescription =>
      '通过自建服务器连接 Spotify API、媒体和 Connect。浏览器登录仍使用 Spotify 原站；保存后新连接生效。';

  @override
  String get settingsGatewayUrl => '反代地址（包含路径）';

  @override
  String get settingsGatewayUser => '反代用户名';

  @override
  String get settingsGatewayPassword => '反代密码';

  @override
  String get settingsGatewayInvalid => '请填写有效的 HTTPS 地址、单段路径及用户名和密码。';

  @override
  String get settingsApply => '保存';

  @override
  String get settingsCacheLocation => '缓存位置';

  @override
  String get settingsAudioCacheLocation => '音频缓存位置';

  @override
  String get settingsArtworkCacheLocation => '封面缓存位置';

  @override
  String get settingsLyricsCacheLocation => '歌词缓存位置';

  @override
  String get settingsCacheAppData => '应用数据目录（AppData）';

  @override
  String get settingsCacheApplication => '安装 / 便携程序目录';

  @override
  String get settingsCacheCustom => '自定义目录';

  @override
  String get settingsClearAllCache => '清理所有缓存';

  @override
  String get settingsClearAllCacheHelp =>
      '清理音频、封面、歌词和浏览器临时缓存，保留登录、设置、收藏和播放记录。正在播放或下载的音频会保留。';

  @override
  String get settingsCacheLocationHelp =>
      '已有缓存会迁移到新位置，校验成功后删除旧文件。正在播放或下载的音频将在释放后继续迁移。自定义位置使用所选目录下的 FlutifyCache 文件夹。';

  @override
  String settingsCacheMigrated(int files, int deferred, int failed) {
    return '已迁移 $files 个文件，$deferred 个使用中，$failed 个未成功';
  }

  @override
  String settingsCacheCleared(String size, int deferred, int failed) {
    return '已释放 $size，$deferred 个使用中，$failed 个未成功';
  }

  @override
  String get settingsCacheLocationInvalid => '目录不可写或路径无效，请选择应用有权访问的本地目录。';

  @override
  String get settingsCacheLocationSaved => '缓存位置已更新';

  @override
  String get settingsCacheLocationHint => '目录绝对路径';

  @override
  String get settingsCacheChooseDirectory => '选择文件夹';

  @override
  String get settingsCachePickerFailed => '无法打开系统文件夹选择器，请重试或手动输入路径。';

  @override
  String get settingsGatewayAutomatic => '自动开关反代';

  @override
  String get settingsGatewayAutomaticHelp =>
      '启动、网络变化、回到应用及每 2 分钟通过 Cloudflare 查询出口国家/地区；遵循已选择的系统或手动代理。查询失败保留当前状态。';

  @override
  String get settingsGatewayDirectCountries => '允许直连的国家/地区代码';

  @override
  String get settingsGatewayDirectCountriesHelp =>
      '可选，填写两位代码，以逗号或空格分隔。留空：CN 开启反代，其余直连；填写后：仅列表内国家/地区直连，其余开启反代。';

  @override
  String get settingsGatewayCountriesInvalid => '请输入两位国家/地区代码，例如 US、JP、HK。';

  @override
  String get settingsGatewayLookupFailed => '国家/地区查询失败，已保留当前连接方式。';

  @override
  String get settingsGatewayCountryPending => '等待查询网络所在国家/地区，暂时保留当前连接方式。';

  @override
  String settingsGatewayCountryStatus(String country, String route) {
    return '网络所在国家/地区：$country · $route';
  }

  @override
  String get settingsGatewayRouteProxy => '反代已开启';

  @override
  String get settingsGatewayRouteDirect => '直连';

  @override
  String get settingsGatewayRecheck => '重新查询国家/地区';

  @override
  String get lyricsTranslate => '显示译词';

  @override
  String get lyricsCancelTranslation => '取消译词';

  @override
  String get lyricsTranslationFailed => '译词查找失败，点击重试';

  @override
  String get lyricsTranslating => '正在查找译词 · 点击取消';

  @override
  String get settingsLyricsAutoTranslate => '自动翻译歌词';

  @override
  String get settingsLyricsAutoTranslateSubtitle =>
      '自动查找已有译文。中文译词按曲名、歌手优先查询 QQ 音乐，缺失或不完整时查网易云，启用补全时最后查 LRCLIB；只采用不丢失已译行的更完整版本。简繁体跟随界面。';

  @override
  String get settingsLyricsExcludeInterface => '不自动翻译界面语言';

  @override
  String get settingsLyricsExcluded => '其他不自动翻译的语言';

  @override
  String get settingsLyricsExcludedHint =>
      '用逗号分隔：en, ja, zh-Hans（简体）, zh-Hant（繁体）；zh 排除全部中文，留空清除';

  @override
  String get settingsLyricsExcludedInvalid =>
      '请输入语言代码，例如 en、ja、zh-Hans、zh-Hant';

  @override
  String get settingsCanvas => 'Spotify Canvas 动态封面';

  @override
  String get settingsCanvasSubtitle => '播放时显示官方短片；无 Canvas 或减少动态效果时显示静态封面。';

  @override
  String get settingsLanguageZhHant => '繁體中文';

  @override
  String get lyricsTranslationUnavailable => '暂无对应语言的译词';

  @override
  String get settingsLanguageJa => '日本語';

  @override
  String get homeRefresh => '刷新首页';

  @override
  String get homeRefreshFailed => '刷新失败，请检查网络后重试。';

  @override
  String get loginTitle => '登录 Spotify';

  @override
  String get loginSubtitle => '在 Spotify 官方登录页登录一次，\n其余授权全部自动完成';

  @override
  String get loginTermsNotice => '以官方客户端身份登录不符合 Spotify 服务条款，建议使用小号。';

  @override
  String get loginPasswordPrivate => 'Flutify 不接触你的密码';

  @override
  String get loginOfficialPage => '使用 Spotify 官方页面完成账号登录';

  @override
  String get loginRemoteDevices => '登录后可遥控你的其他 Spotify 设备';

  @override
  String loginSignedInAs(String name) {
    return '已登录为 $name';
  }

  @override
  String get loginPlaybackReady => '全曲播放已就绪';

  @override
  String get loginBack => '返回';

  @override
  String get loginFailed => '登录失败';

  @override
  String get webLoginTitle => '全曲播放：Web 登录';

  @override
  String get webLoginCardTitle => '全曲播放（Web 登录）';

  @override
  String get webLoginReady => '已就绪，可以播放完整曲目';

  @override
  String get webLoginRequired => '登录一次以解锁完整曲目播放';

  @override
  String get webLoginConsentHint => '如果页面在等你确认，请点「同意」完成授权；其余步骤已自动完成';

  @override
  String get webLoginPreparing => '正在获取播放凭据…';

  @override
  String get webLoginAuthorizing => '正在完成账号授权…';

  @override
  String get webLoginFinishing => '正在完成登录…';

  @override
  String get webLoginBackgroundHint => '登录已完成，剩下的步骤在后台自动进行';

  @override
  String get webLoginGoogleHint =>
      '用 Google 注册的账号：请在此处使用「邮箱 + 密码」登录；没有密码可先在 Spotify 官网「忘记密码」设置一个。';

  @override
  String get loginBrowserFallback => '无法自动打开浏览器，登录链接已复制，请粘贴到浏览器中打开';

  @override
  String get loginBrowserTitle => '在浏览器中完成登录';

  @override
  String get loginBrowserSubtitle => '登录并同意授权后，这里会自动继续';

  @override
  String get loginReopen => '重新打开';

  @override
  String get loginLinkCopied => '登录链接已复制';

  @override
  String get loginCopyLink => '复制链接';

  @override
  String get updatesTitle => '软件更新';

  @override
  String get updatesMode => '更新方式';

  @override
  String get updatesManual => '手动更新';

  @override
  String get updatesAutomatic => '自动下载更新';

  @override
  String get updatesDisabled => '不检查更新';

  @override
  String get updatesHint => '自动检查新版本和更新内容。自动模式在后台下载，完成后由你确认安装，不会中断播放。';

  @override
  String get updatesCheck => '检查更新';

  @override
  String get updatesChecking => '正在检查更新…';

  @override
  String get updatesCurrent => '当前版本';

  @override
  String get updatesUpToDate => '已是最新版本';

  @override
  String get updatesAvailable => '发现新版本';

  @override
  String get updatesNotes => '更新内容';

  @override
  String get updatesNoNotes => '此版本未提供更新说明。';

  @override
  String get updatesDownload => '下载更新';

  @override
  String get updatesDownloading => '正在下载并校验…';

  @override
  String get updatesReady => '更新已就绪';

  @override
  String get updatesReadyHint => '更新包已下载并通过校验。安装会关闭应用；也可以稍后从设置中继续。';

  @override
  String get updatesAndroidHint => 'APK 已下载并通过校验。确认后打开系统安装程序。';

  @override
  String get updatesInstall => '重启并安装';

  @override
  String get updatesInstallApk => '安装 APK';

  @override
  String get updatesInstalling => '正在准备安装…';

  @override
  String get updatesSkip => '跳过本次更新';

  @override
  String get updatesLater => '稍后';

  @override
  String get updatesPage => '手动更新 · 发布页面';

  @override
  String get updatesFailed => '更新失败，请重试或前往发布页面。';

  @override
  String get updatesPermission => '请允许 Flutify 安装未知来源应用，返回后再次点击「安装 APK」。';

  @override
  String get updatesUnsupported => '此平台暂不提供应用内安装，请通过发布页面手动更新。';

  @override
  String get updatesDetails => '查看更新';
}

/// The translations for Chinese, using the Han script (`zh_Hant`).
class AppLocalizationsZhHant extends AppLocalizationsZh {
  AppLocalizationsZhHant() : super('zh_Hant');

  @override
  String playbackRetryWaiting(int attempt, int total, int seconds) {
    return '網路連接失敗，$seconds 秒后第 $attempt/$total 次重試';
  }

  @override
  String playbackRetryRunning(int attempt, int total) {
    return '正在重新連接，第 $attempt/$total 次重試';
  }

  @override
  String get appTitle => 'Flutify';

  @override
  String get shellBack => '后退';

  @override
  String get shellForward => '前進';

  @override
  String get shellHome => '主頁';

  @override
  String get shellSearchShortcut => 'Ctrl K';

  @override
  String get shellAccountMenu => '帳號';

  @override
  String get shellCollapseLibrary => '收起音樂庫';

  @override
  String get shellExpandLibrary => '展開音樂庫';

  @override
  String get shellPlaybackStatus => '播放狀態';

  @override
  String get shellHidePanel => '隱藏';

  @override
  String get shellAboutArtist => '關于藝人';

  @override
  String shellMonthlyFollowers(String count) {
    return '$count 位粉絲';
  }

  @override
  String get shellSignInTitle => '登入后查看你的音樂庫';

  @override
  String get shellSignInMessage => '收藏的歌單、專輯和藝人會顯示在這里。';

  @override
  String get shellSignIn => '登入';

  @override
  String get windowMinimize => '最小化';

  @override
  String get windowMaximize => '最大化';

  @override
  String get windowRestore => '向下還原';

  @override
  String get windowClose => '關閉';

  @override
  String get menuPlayback => '播放';

  @override
  String get menuNavigate => '導覽';

  @override
  String get menuEdit => '編輯';

  @override
  String get menuUndo => '復原';

  @override
  String get menuRedo => '重做';

  @override
  String get menuCut => '剪下';

  @override
  String get menuCopy => '複製';

  @override
  String get menuPaste => '貼上';

  @override
  String get menuSelectAll => '全選';

  @override
  String get menuWindow => '視窗';

  @override
  String get menuSettings => '設定…';

  @override
  String get commonCancel => '取消';

  @override
  String get commonCreate => '創建';

  @override
  String get commonDone => '完成';

  @override
  String get commonClose => '關閉';

  @override
  String get commonClear => '清除';

  @override
  String get commonRemove => '移除';

  @override
  String get commonRetry => '重試';

  @override
  String get commonLoadMore => '載入更多';

  @override
  String get commonMoreOptions => '更多選項';

  @override
  String get commonShowAll => '顯示全部';

  @override
  String get commonSeeMore => '查看更多';

  @override
  String get commonShowLess => '收起';

  @override
  String get commonSettings => '設定';

  @override
  String get commonShare => '分享';

  @override
  String subtitleJoin(String first, String second) {
    return '$first · $second';
  }

  @override
  String get navHome => '主頁';

  @override
  String get navSearch => '搜索';

  @override
  String get navLibrary => '音樂庫';

  @override
  String get typeTrack => '歌曲';

  @override
  String get typeArtist => '藝人';

  @override
  String get typePlaylist => '歌單';

  @override
  String get typePodcast => '播客';

  @override
  String podcastEpisodeCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 集',
    );
    return '$_temp0';
  }

  @override
  String get podcastPlayed => '已播完';

  @override
  String podcastResumeFrom(String position) {
    return '播至 $position';
  }

  @override
  String get podcastEmpty => '這個節目暫時沒有單集';

  @override
  String get podcastLoadFailed => '節目載入失敗，請檢查網路后重試';

  @override
  String get typeAlbum => '專輯';

  @override
  String get typeSingle => '單曲';

  @override
  String get typeCompilation => '合輯';

  @override
  String get filterAll => '全部';

  @override
  String get filterMusic => '音樂';

  @override
  String get filterPodcasts => '播客';

  @override
  String get filterSongs => '歌曲';

  @override
  String get filterArtists => '藝人';

  @override
  String get filterPlaylists => '歌單';

  @override
  String get filterAlbums => '專輯';

  @override
  String songCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 首歌曲',
    );
    return '$_temp0';
  }

  @override
  String followerCount(String count) {
    return '$count 位粉絲';
  }

  @override
  String durationHoursMinutes(int hours, int minutes) {
    return '$hours 小時 $minutes 分鐘';
  }

  @override
  String durationMinutesSeconds(int minutes, int seconds) {
    return '$minutes 分 $seconds 秒';
  }

  @override
  String countAndDuration(String count, String duration) {
    return '$count，$duration';
  }

  @override
  String get greetingMorning => '早上好';

  @override
  String get greetingAfternoon => '下午好';

  @override
  String get greetingEvening => '晚上好';

  @override
  String get likedSongs => '已點贊的歌曲';

  @override
  String get likedSongsDescription => '你喜歡的所有歌曲都在這里。';

  @override
  String get likeAdd => '添加到已點贊的歌曲';

  @override
  String get likeRemove => '從已點贊的歌曲中移除';

  @override
  String get libraryAdd => '保存到音樂庫';

  @override
  String get libraryRemove => '從音樂庫中移除';

  @override
  String get homeLoadFailedTitle => '無法載入推薦內容';

  @override
  String get homeLoadFailedMessage => '請檢查網路連接后重試。';

  @override
  String get authSessionExpiredTitle => '登入已過期';

  @override
  String get authSessionExpiredMessage =>
      'Spotify 已讓這次登入失效（例如在其他地方退出了所有裝置或修改了密碼），請重新登入。';

  @override
  String get authSignInAgain => '重新登入';

  @override
  String get homeEmptyTitle => '這里暫時沒有內容';

  @override
  String get homeEmptyMessage => '換個篩選標簽看看，或稍后再來。';

  @override
  String get homeClearFilter => '清除篩選';

  @override
  String get homePodcastUnsupported => '暫不支持播客，敬請期待';

  @override
  String get homeTypePodcast => '播客';

  @override
  String get homeTypeEpisode => '單集';

  @override
  String get searchHint => '你想聽什么？';

  @override
  String get searchRecent => '最近搜索';

  @override
  String get searchClearAll => '全部清除';

  @override
  String get searchBrowseAll => '瀏覽全部';

  @override
  String get searchCategoriesFailedTitle => '無法載入分類';

  @override
  String get searchCategoriesFailedMessage => '請檢查網路連接后重試。';

  @override
  String get searchFailedTitle => '無法載入搜尋結果';

  @override
  String get searchFailedMessage => '請檢查網路連線後重試，已載入的結果會保留。';

  @override
  String searchNoResultsTitle(String query) {
    return '未找到與“$query”相關的結果';
  }

  @override
  String get searchNoResultsMessage => '請檢查拼寫，或換個關鍵詞試試。';

  @override
  String get searchFilterEmptyTitle => '該分類下暫無結果';

  @override
  String get searchFilterEmptyMessage => '換個篩選條件，查看更多結果。';

  @override
  String searchCategoryMix(String name) {
    return '$name 精選';
  }

  @override
  String searchCategoryMixDescription(String name) {
    return '精選 $name 好歌，新鮮好聽。';
  }

  @override
  String get librarySearchHint => '在音樂庫中搜索';

  @override
  String get libraryCloseSearch => '關閉搜索';

  @override
  String get libraryCreatePlaylist => '創建歌單';

  @override
  String get libraryClearFilter => '清除篩選';

  @override
  String get librarySortRecent => '最近添加';

  @override
  String get librarySortAlphabetical => '按字母順序';

  @override
  String get libraryListView => '列表視圖';

  @override
  String get libraryGridView => '網格視圖';

  @override
  String get libraryEmptyTitle => '這里還沒有內容';

  @override
  String get libraryEmptyMessage => '收藏的歌單、藝人和專輯會顯示在這里。';

  @override
  String libraryNewPlaylistName(int number) {
    return '我的歌單 #$number';
  }

  @override
  String get playlistDelete => '刪除歌單';

  @override
  String get playlistLikedEmpty => '你點贊的歌曲會顯示在這里。\n點按愛心圖標即可收藏歌曲。';

  @override
  String get playlistOwnEmpty => '來為你的歌單找些歌曲吧。\n在任意歌曲的菜單中選擇“添加到歌單”。';

  @override
  String get playlistEmpty => '這個歌單還沒有歌曲。';

  @override
  String get albumNoTracks => '這張專輯暫無可播放的曲目。';

  @override
  String albumMoreBy(String name) {
    return '$name 的更多作品';
  }

  @override
  String get artistPopular => '熱門歌曲';

  @override
  String get artistNoPopular => '暫無熱門歌曲。';

  @override
  String get artistNoAlbums => '暫無可顯示的專輯。';

  @override
  String get artistNoSongs => '暫無可顯示的歌曲。';

  @override
  String get artistDiscography => '作品';

  @override
  String get artistFollow => '關注';

  @override
  String get artistFollowing => '已關注';

  @override
  String get playingFromPlaylist => '正在播放歌單';

  @override
  String get playingFromAlbum => '正在播放專輯';

  @override
  String get playingFromArtist => '正在播放藝人';

  @override
  String get playingFromSearch => '正在播放搜索結果';

  @override
  String get playingFromLibrary => '正在播放音樂庫';

  @override
  String get nowPlaying => '正在播放';

  @override
  String get openNowPlaying => '打開正在播放';

  @override
  String get playerNothingPlayingTitle => '當前沒有播放內容';

  @override
  String get playerNothingPlayingMessage => '選擇一首歌曲、專輯或歌單，開始收聽吧。';

  @override
  String get playerIdleHint => '暫無播放 — 挑點音樂來聽吧';

  @override
  String get playerThisDevice => '正在本裝置上收聽';

  @override
  String get playerShuffleOn => '開啟隨機播放';

  @override
  String get playerShuffleOff => '關閉隨機播放';

  @override
  String get playerRepeatOn => '開啟列表循環';

  @override
  String get playerRepeatOneOn => '開啟單曲循環';

  @override
  String get playerRepeatOff => '關閉循環';

  @override
  String get playerNext => '下一首';

  @override
  String get playerPrevious => '上一首';

  @override
  String get playerMute => '靜音';

  @override
  String get playerUnmute => '取消靜音';

  @override
  String get playerLyricsFullscreen => '全螢幕歌詞';

  @override
  String get playerSwipeHint => '左右滑動封面切換歌曲';

  @override
  String get playbackErrorSignIn => '登入后才能播放';

  @override
  String get playbackErrorWebSignIn => '全曲播放需要先完成 Web 登入';

  @override
  String get webLoginAction => 'Web 登入';

  @override
  String get webLoginSuccess => 'Web 登入成功，全曲播放已就緒';

  @override
  String playbackErrorUnavailable(String track) {
    return '「$track」暫時無法播放';
  }

  @override
  String playbackErrorSkipped(String track) {
    return '「$track」暫時無法播放，已跳過';
  }

  @override
  String playbackErrorNetwork(String track) {
    return '「$track」載入失敗，請檢查網路';
  }

  @override
  String playbackErrorWidevine(String track) {
    return '「$track」無法解密播放：此裝置缺少 Widevine 組件';
  }

  @override
  String playbackErrorFairPlay(String track) {
    return '無法解密「$track」：此裝置無法建立 FairPlay 工作階段';
  }

  @override
  String playbackErrorAutoPaused(int count) {
    return '連續 $count 首無法播放，已暫停';
  }

  @override
  String get detailSignInRequired => '登入后即可查看這里的內容';

  @override
  String get detailLoadFailed => '暫時無法載入，請檢查網路后重試';

  @override
  String get queueTitle => '播放隊列';

  @override
  String get queueNextInQueue => '隊列中的下一首';

  @override
  String get queueClear => '清空隊列';

  @override
  String get queueNextUp => '接下來播放';

  @override
  String queueNextFrom(String name) {
    return '接下來播放：$name';
  }

  @override
  String get queueEmpty => '隊列中暫無待播歌曲';

  @override
  String get lyricsTitle => '歌詞';

  @override
  String get lyricsNotPlaying => '未在播放';

  @override
  String get lyricsNothingPlayingMessage => '播放一首歌曲，即可在這里查看歌詞。';

  @override
  String get lyricsUnavailableTitle => '暫無歌詞';

  @override
  String get lyricsUnavailableMessage => '這首歌還沒有歌詞。\n盡情享受音樂吧！';

  @override
  String get lyricsUnsynced => '這些歌詞尚未與歌曲同步。';

  @override
  String get lyricsFromLrclib => '歌詞來自 LRCLIB';

  @override
  String get lyricsImmersive => '沉浸式歌詞';

  @override
  String get lyricsExpand => '放大歌詞';

  @override
  String get lyricsCollapse => '收起歌詞';

  @override
  String get lyricsExitImmersive => '退出全螢幕歌詞（Esc）';

  @override
  String get lyricsFillScreen => '鋪滿整個螢幕（F11）';

  @override
  String get lyricsFillWindow => '只鋪滿視窗（F11）';

  @override
  String get deviceConnectTitle => '連接到裝置';

  @override
  String get deviceConnectDescription =>
      '通過 Spotify Connect，可在電腦、手機或智能音箱上無縫播放。';

  @override
  String get deviceCurrent => '當前收聽裝置';

  @override
  String get deviceSpotifyConnect => 'Spotify Connect';

  @override
  String get connectThisDevice => '此裝置';

  @override
  String get connectTakeOver => '在此裝置繼續播放';

  @override
  String connectPlayingOn(String device) {
    return '正在 $device 上播放';
  }

  @override
  String get connectOtherDevices => '選擇其他裝置';

  @override
  String get connectNoDevices => '沒有找到其他裝置';

  @override
  String get connectNoDevicesHint => '在手機、電腦或音箱上打開 Spotify，并登入同一帳號';

  @override
  String get connectUnavailable => '使用桌面版方式登入后，即可遙控其他裝置上的 Spotify';

  @override
  String get connectConnecting => '正在連接 Spotify Connect…';

  @override
  String get connectOffline => '連接已斷開，正在重試…';

  @override
  String get connectSameNetwork => '同一網路';

  @override
  String get connectCommandFailed => '操作未成功：免費帳號可能不支持遠程執行此操作';

  @override
  String connectVolumeUnsupported(String device) {
    return '$device 不支持遠程調節音量';
  }

  @override
  String get connectVolume => '裝置音量';

  @override
  String get trackAddToPlaylist => '添加到歌單';

  @override
  String get trackAddToQueue => '添加到播放隊列';

  @override
  String get trackGoToAlbum => '前往專輯';

  @override
  String get trackGoToRadio => '前往歌曲電臺';

  @override
  String get trackViewCredits => '查看制作人員';

  @override
  String get creditsTitle => '制作人員';

  @override
  String get creditsSources => '來源';

  @override
  String get creditsEmpty => '這首歌暫時沒有制作人員資訊';

  @override
  String get radioUnavailable => '這首歌暫時沒有歌曲電臺';

  @override
  String trackGoToArtist(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '前往藝人',
    );
    return '$_temp0';
  }

  @override
  String get trackNewPlaylist => '新建歌單';

  @override
  String get toastLikeAdded => '已添加到已點贊的歌曲';

  @override
  String get toastLikeRemoved => '已從已點贊的歌曲中移除';

  @override
  String get toastAddedToQueue => '已添加到播放隊列';

  @override
  String get shareCopyLink => '復制連結';

  @override
  String get shareCopyUri => '復制 URI';

  @override
  String get shareOpenWeb => '網頁打開';

  @override
  String get shareCopied => '已復制';

  @override
  String get shareEmbedTitle => '嵌入代碼';

  @override
  String get shareEmbedSubtitle => '粘貼到網頁 HTML 中，即可展示 Spotify 播放器';

  @override
  String get shareEmbedStandard => '標準';

  @override
  String get shareEmbedCompact => '緊湊';

  @override
  String get shareEmbedDark => '深色';

  @override
  String get shareEmbedCopy => '復制代碼';

  @override
  String get shareEmbedUnavailable => '此裝置的系統 WebView 暫不可用，仍可復制下方嵌入代碼。';

  @override
  String get shareEmbedFailed => 'Spotify 嵌入播放器載入失敗，請檢查網路后重試。';

  @override
  String toastAddedTo(String name) {
    return '已添加到「$name」';
  }

  @override
  String toastAlreadyIn(String name) {
    return '「$name」中已有這首歌';
  }

  @override
  String get createPlaylistTitle => '為歌單命名';

  @override
  String get createPlaylistHint => '歌單名稱';

  @override
  String get createPlaylistDefaultName => '我的歌單';

  @override
  String get settingsAppearanceSection => '外觀';

  @override
  String get settingsThemeMode => '主題';

  @override
  String get settingsThemeSystem => '跟隨系統';

  @override
  String get settingsThemeLight => '淺色';

  @override
  String get settingsThemeDark => '深色';

  @override
  String get settingsPureBlack => '純黑背景';

  @override
  String get settingsPureBlackSubtitle => '深色模式下使用純黑底色，OLED 螢幕更省電';

  @override
  String get settingsAccentSection => '強調色';

  @override
  String get settingsAccentCustom => '自定義顏色';

  @override
  String get settingsDynamicAccent => '跟隨封面取色';

  @override
  String get settingsDynamicAccentSubtitle => '強調色隨正在播放的專輯封面變化';

  @override
  String get settingsGlassSection => '液態玻璃';

  @override
  String get settingsGlassPreview => '玻璃預覽';

  @override
  String get settingsGlassBlur => '模糊強度';

  @override
  String get settingsGlassOpacity => '不透明度';

  @override
  String get settingsTextShapeSection => '文字與形狀';

  @override
  String get settingsFontScale => '字號';

  @override
  String get settingsFontPreview => '夜空中最亮的星';

  @override
  String get settingsCornerStyle => '圓角';

  @override
  String get settingsCornerRounded => '圓潤';

  @override
  String get settingsCornerStandard => '標準';

  @override
  String get settingsCornerSquare => '方正';

  @override
  String get settingsPlaybackSection => '播放';

  @override
  String get settingsPauseAfterFailures => '連續無法播放時暫停';

  @override
  String settingsPauseAfterFailuresSubtitle(int count) {
    return '連續 $count 首無法播放就停下，不再繼續自動跳過';
  }

  @override
  String get settingsMotionSection => '動效';

  @override
  String get settingsReduceMotion => '減弱動效';

  @override
  String get settingsReduceMotionSubtitle => '關閉流動背景、過渡與懸停等裝飾性動畫';

  @override
  String get settingsPowerSaving => '省電模式';

  @override
  String get settingsPowerSavingSubtitle => '玻璃改用磨砂底、歌詞頁背景不再流動；歌詞捲動與動效全部保留';

  @override
  String get settingsFrameRate => '幀率上限';

  @override
  String get settingsFrameRateSubtitle => '降低可明顯減少 GPU 佔用，動畫速度不變';

  @override
  String get settingsFrameRateFollow => '跟隨螢幕';

  @override
  String get settingsFrameRateCustom => '自訂';

  @override
  String settingsFrameRateValue(int fps) {
    return '$fps fps';
  }

  @override
  String get settingsResetAppearance => '恢復預設外觀';

  @override
  String get settingsCustomColorTitle => '自定義強調色';

  @override
  String get settingsHue => '色相';

  @override
  String get settingsSaturation => '飽和度';

  @override
  String get settingsBrightness => '亮度';

  @override
  String get settingsLanguageSection => '語言';

  @override
  String get settingsLanguage => '界面語言';

  @override
  String get settingsLanguageSubtitle => '同時影響主頁推薦等由 Spotify 提供的文案';

  @override
  String get settingsLanguageSystem => '跟隨系統';

  @override
  String get settingsLanguageZh => '简体中文';

  @override
  String get settingsLanguageEn => 'English';

  @override
  String get settingsStorageSection => '存儲';

  @override
  String get settingsAudioCache => '音頻快取';

  @override
  String settingsAudioCacheUsage(String used, String limit) {
    return '已用 $used，上限 $limit';
  }

  @override
  String get settingsAudioCacheCalculating => '正在計算…';

  @override
  String get settingsAudioCacheLimit => '快取上限';

  @override
  String get settingsAudioCacheLimitSubtitle => '超出后自動刪除最久沒播放的歌曲';

  @override
  String get settingsClearAudioCache => '清除音頻快取';

  @override
  String get settingsClearAudioCacheTitle => '清除音頻快取？';

  @override
  String get settingsClearAudioCacheMessage =>
      '已下載的歌曲會被刪除，再次播放時重新下載。正在播放的歌曲會保留。';

  @override
  String settingsAudioCacheCleared(String size) {
    return '已釋放 $size';
  }

  @override
  String get settingsLyricsSection => '歌詞';

  @override
  String get settingsLyricsFocusPosition => '目前歌詞行位置';

  @override
  String get settingsLyricsFocusPositionSubtitle =>
      '調整目前歌詞在可見歌詞區域中的高度，數值越大越靠下。';

  @override
  String get lyricsTranslationFromNetease => '譯詞來自網易雲音樂社群';

  @override
  String get lyricsTranslationFromQqMusic => '譯詞來自 QQ 音樂';

  @override
  String get settingsLyricsSize => '歌詞字號';

  @override
  String get settingsLyricsAlign => '對齊方式';

  @override
  String get settingsLyricsAlignLeft => '左對齊';

  @override
  String get settingsLyricsAlignCenter => '居中';

  @override
  String get settingsLyricsBlur => '其他行模糊';

  @override
  String get settingsLyricsImmersiveScreen => '全螢幕歌詞鋪滿整個螢幕';

  @override
  String get settingsLyricsImmersiveScreenSubtitle =>
      '關閉時只鋪滿視窗；在全螢幕歌詞里按 F11 也能切換';

  @override
  String get settingsLyricsFallback => '補全歌詞';

  @override
  String get settingsLyricsFallbackSubtitle =>
      'Spotify 沒有逐行同步歌詞時，從 LRCLIB 開放歌詞庫補全，并按原唱語言挑選';

  @override
  String get settingsLyricsBilingual => '社群歌詞翻譯';

  @override
  String get settingsLyricsBilingualSubtitle =>
      '載入歌詞時預先取得中文譯詞，優先 QQ 音樂，缺失或不完整時查網易雲，啟用補全時最後查 LRCLIB，也供工作列歌詞使用。關閉後仍可手動或自動查詢；曲名與歌手會傳送至查詢來源。';

  @override
  String get settingsTaskbarLyricsSection => '任務欄歌詞';

  @override
  String get settingsTaskbarLyrics => '在任務欄顯示歌詞';

  @override
  String get settingsTaskbarLyricsSubtitle =>
      '任務欄圖標居中時顯示在左側，居左時顯示在系統托盤左邊；任務欄豎向時自動停用。懸停顯示播放控制，點按打開 Flutify，右鍵重新獲取歌詞';

  @override
  String get settingsTaskbarLyricsColor => '文字顏色';

  @override
  String get settingsTaskbarLyricsCustomColor => '自定義顏色';

  @override
  String get settingsTaskbarLyricsChangeColor => '更改';

  @override
  String get settingsTaskbarLyricsOpacity => '不透明度';

  @override
  String get settingsTaskbarLyricsFontSize => '字號';

  @override
  String get settingsCopyLog => '復制診斷日志';

  @override
  String get settingsCopyLogSubtitle => '反饋問題時粘貼給開發者；日志只含運行記錄，不含密碼';

  @override
  String get settingsCopyLogDone => '日志已復制到剪貼簿';

  @override
  String get settingsCopyLogEmpty => '暫無日志';

  @override
  String get taskbarLyricsColorAuto => '自動';

  @override
  String get taskbarLyricsColorWhite => '白色';

  @override
  String get taskbarLyricsColorBlack => '黑色';

  @override
  String get taskbarLyricsColorAccent => '強調色';

  @override
  String get taskbarLyricsColorCustom => '自定義';

  @override
  String get taskbarLyricsMenuOpen => '打開 Flutify';

  @override
  String get taskbarLyricsMenuRefetch => '重新獲取歌詞';

  @override
  String get taskbarLyricsMenuDisable => '關閉任務欄歌詞';

  @override
  String get taskbarLyricsPreviewLine1 => '歌詞會在這里隨歌聲滾動';

  @override
  String get taskbarLyricsPreviewLine2 => '懸停即可切歌、暫停';

  @override
  String get taskbarLyricsPreviewLine3 => '顏色與不透明度即時生效';

  @override
  String get settingsOff => '關';

  @override
  String get settingsNormalize => '音量均衡';

  @override
  String get settingsNormalizeSubtitle => '按 Spotify 提供的響度數據，把偏響的歌調低到一致的音量';

  @override
  String get settingsFade => '歌曲間淡入淡出';

  @override
  String get settingsFadeSubtitle => '結尾逐漸淡出，下一首淡入';

  @override
  String settingsSeconds(int count) {
    return '$count 秒';
  }

  @override
  String get settingsStartupSection => '啟動';

  @override
  String get settingsStartPage => '啟動時打開';

  @override
  String get settingsStartPageHome => '主頁';

  @override
  String get settingsStartPageLibrary => '音樂庫';

  @override
  String get settingsStartPageLast => '上次位置';

  @override
  String get settingsRememberWindow => '記住視窗大小和位置';

  @override
  String get settingsRememberWindowSubtitle => '下次啟動時還原；顯示器變化導致視窗不可見時回到螢幕中央';

  @override
  String get settingsConnectSection => 'Spotify Connect';

  @override
  String get settingsConnectEnabled => '啟用 Spotify Connect';

  @override
  String get settingsConnectEnabledSubtitle => '顯示并遙控同一帳號在其他裝置上的播放';

  @override
  String get settingsConnectDeviceName => '裝置名稱';

  @override
  String get settingsConnectDeviceNameSubtitle => '其他裝置的裝置列表里顯示的名字，留空使用預設名';

  @override
  String get settingsConnectUseDeviceName => '使用裝置名稱';

  @override
  String get settingsConnectReportOnLaunch => '啟動時同步播放狀態';

  @override
  String get settingsConnectReportOnLaunchSubtitle =>
      '打開 Flutify 后即使還沒播放，也讓其他裝置看到 Flutify 上的當前歌曲（會接管正在空閑的播放會話）';

  @override
  String get settingsRemoteLyricsLead => '遠程歌詞提前';

  @override
  String get settingsRemoteLyricsLeadSubtitle => '其他裝置上播放時，歌詞比演唱慢就調大，快就調小';

  @override
  String get settingsNetworkSection => '網路';

  @override
  String get settingsProxy => '代理';

  @override
  String get settingsProxySystem => '系統代理';

  @override
  String get settingsProxyNone => '不使用';

  @override
  String get settingsProxyManual => '手動';

  @override
  String settingsProxySystemDetected(String endpoint) {
    return '當前系統代理：$endpoint';
  }

  @override
  String get settingsProxySystemEmpty => '系統未設定代理，直接連接';

  @override
  String get settingsProxySystemAuto => '系統使用自動代理設定（PAC / 自動偵測）';

  @override
  String get settingsProxyNoneSubtitle => '所有請求直接連接，不經過代理';

  @override
  String get settingsProxyManualSubtitle => '填寫 HTTP 代理的地址與端口';

  @override
  String get settingsProxyServer => '代理服務器';

  @override
  String get settingsProxyHostHint => '127.0.0.1';

  @override
  String get settingsProxyPortHint => '端口';

  @override
  String get settingsProxyInvalid => '請填寫有效的地址和 1–65535 之間的端口';

  @override
  String get settingsProxyAuth => '代理驗證（選填）';

  @override
  String get settingsProxyUsernameHint => '使用者名稱';

  @override
  String get settingsProxyPasswordHint => '密碼';

  @override
  String get settingsProxyUsernameInvalid =>
      '使用者名稱不能包含冒號（:），否則會被當作使用者名稱與密碼的分隔符，導致驗證失敗';

  @override
  String get settingsProxyAuthIncomplete => 'HTTPS 可只填寫其中一項；HTTP 代理驗證需要同時填寫兩項';

  @override
  String get settingsProxyTest => '測試連接';

  @override
  String get settingsProxyTesting => '正在連接 Spotify…';

  @override
  String settingsProxyTestOk(int ms) {
    return '連接正常，用時 $ms 毫秒';
  }

  @override
  String settingsProxyTestFailed(String error) {
    return '連接失敗：$error';
  }

  @override
  String get settingsProxyFootnote =>
      '僅支持 HTTP 代理（Clash、v2rayN 等的混合端口即可）。登入頁面始終跟隨系統代理設定。';

  @override
  String get settingsPrivacySection => '隱私';

  @override
  String get settingsClearSearchHistory => '清除搜索記錄';

  @override
  String settingsSearchHistoryCount(int count) {
    return '$count 條記錄';
  }

  @override
  String get settingsSearchHistoryEmpty => '沒有搜索記錄';

  @override
  String get settingsClearLyricsCache => '清除歌詞快取';

  @override
  String get settingsClearLyricsCacheSubtitle => '清除后重新從 Spotify 獲取歌詞';

  @override
  String get settingsCleared => '已清除';

  @override
  String get settingsAboutSection => '關于';

  @override
  String get settingsVersion => '版本';

  @override
  String get settingsShortcuts => '鍵盤快捷鍵';

  @override
  String get settingsLicenses => '開源許可';

  @override
  String get shortcutPlayPause => '播放 / 暫停';

  @override
  String get shortcutNext => '下一首';

  @override
  String get shortcutPrevious => '上一首';

  @override
  String get shortcutVolumeUp => '調高音量';

  @override
  String get shortcutVolumeDown => '調低音量';

  @override
  String get shortcutShuffle => '隨機播放';

  @override
  String get shortcutRepeat => '切換循環模式';

  @override
  String get shortcutSearch => '搜索';

  @override
  String get shortcutBack => '后退';

  @override
  String get shortcutForward => '前進';

  @override
  String get shortcutImmersive => '全螢幕歌詞';

  @override
  String get shortcutImmersiveMode => '全螢幕歌詞中：切換鋪滿螢幕 / 視窗';

  @override
  String get shortcutExitImmersive => '退出全螢幕歌詞';

  @override
  String get accountTitle => 'Spotify 帳號';

  @override
  String get accountSignedOutMessage => '登入后同步你的音樂庫';

  @override
  String get accountSignIn => '登入';

  @override
  String get accountSignOut => '退出登入';

  @override
  String get accountSignOutTitle => '退出登入？';

  @override
  String get accountSignOutMessage => '將清除本機保存的登入資訊與媒體庫快取，退出后需重新登入才能播放和查看媒體庫。';

  @override
  String get accountSignOutConfirm => '退出';

  @override
  String get sleepTimer => '睡眠定時器';

  @override
  String sleepTimerMinutes(int count) {
    return '$count 分鐘';
  }

  @override
  String get sleepTimerHour => '1 小時';

  @override
  String get sleepTimerEndOfTrack => '本首結束時';

  @override
  String get sleepTimerOff => '關閉定時器';

  @override
  String sleepTimerRemaining(String time) {
    return '睡眠定時器：剩余 $time';
  }

  @override
  String get sleepTimerEndOfTrackActive => '睡眠定時器：本首結束時暫停';

  @override
  String toastSleepTimerSet(String label) {
    return '睡眠定時器已設為「$label」';
  }

  @override
  String get toastSleepTimerOff => '睡眠定時器已關閉';

  @override
  String shortcutOnHoveredTrack(String action) {
    return '懸停曲目時：$action';
  }

  @override
  String get trackColumnTitle => '標題';

  @override
  String get trackColumnArtist => '藝人';

  @override
  String get trackColumnAlbum => '專輯';

  @override
  String get trackColumnAddedAt => '添加日期';

  @override
  String get trackColumnDuration => '時長';

  @override
  String get trackSortBy => '排序方式';

  @override
  String get trackSortCustom => '自定義順序';

  @override
  String get trackViewAs => '查看方式';

  @override
  String get trackViewList => '列表';

  @override
  String get trackViewCompact => '緊湊';

  @override
  String get trackSearchHint => '在歌單中搜索';

  @override
  String get trackSearchClose => '關閉搜索';

  @override
  String trackSearchNoResults(String query) {
    return '找不到「$query」';
  }

  @override
  String get addedToday => '今天';

  @override
  String addedDaysAgo(int count) {
    return '$count 天前';
  }

  @override
  String addedWeeksAgo(int count) {
    return '$count 周前';
  }

  @override
  String get settingsGateway => 'Spotify 反代';

  @override
  String get settingsGatewayDescription =>
      '通過自建服務器連接 Spotify API、媒體和 Connect。瀏覽器登入仍使用 Spotify 原站；保存后新連接生效。';

  @override
  String get settingsGatewayUrl => '反代地址（包含路徑）';

  @override
  String get settingsGatewayUser => '反代用戶名';

  @override
  String get settingsGatewayPassword => '反代密碼';

  @override
  String get settingsGatewayInvalid => '請填寫有效的 HTTPS 地址、單段路徑及用戶名和密碼。';

  @override
  String get settingsApply => '保存';

  @override
  String get settingsCacheLocation => '快取位置';

  @override
  String get settingsAudioCacheLocation => '音頻快取位置';

  @override
  String get settingsArtworkCacheLocation => '封面快取位置';

  @override
  String get settingsLyricsCacheLocation => '歌詞快取位置';

  @override
  String get settingsCacheAppData => '應用數據目錄（AppData）';

  @override
  String get settingsCacheApplication => '安裝 / 便攜程序目錄';

  @override
  String get settingsCacheCustom => '自定義目錄';

  @override
  String get settingsClearAllCache => '清理所有快取';

  @override
  String get settingsClearAllCacheHelp =>
      '清理音頻、封面、歌詞和瀏覽器臨時快取，保留登入、設定、收藏和播放記錄。正在播放或下載的音頻會保留。';

  @override
  String get settingsCacheLocationHelp =>
      '已有快取會遷移到新位置，校驗成功后刪除舊檔案。正在播放或下載的音頻將在釋放后繼續遷移。自定義位置使用所選目錄下的 FlutifyCache 資料夾。';

  @override
  String settingsCacheMigrated(int files, int deferred, int failed) {
    return '已遷移 $files 個檔案，$deferred 個使用中，$failed 個未成功';
  }

  @override
  String settingsCacheCleared(String size, int deferred, int failed) {
    return '已釋放 $size，$deferred 個使用中，$failed 個未成功';
  }

  @override
  String get settingsCacheLocationInvalid => '目錄不可寫或路徑無效，請選擇應用有權訪問的本地目錄。';

  @override
  String get settingsCacheLocationSaved => '快取位置已更新';

  @override
  String get settingsCacheLocationHint => '目錄絕對路徑';

  @override
  String get settingsCacheChooseDirectory => '選擇資料夾';

  @override
  String get settingsCachePickerFailed => '無法打開系統資料夾選擇器，請重試或手動輸入路徑。';

  @override
  String get settingsGatewayAutomatic => '自動開關反代';

  @override
  String get settingsGatewayAutomaticHelp =>
      '啟動、網路變化、回到應用及每 2 分鐘通過 Cloudflare 查詢出口國家/地區；遵循已選擇的系統或手動代理。查詢失敗保留當前狀態。';

  @override
  String get settingsGatewayDirectCountries => '允許直連的國家/地區代碼';

  @override
  String get settingsGatewayDirectCountriesHelp =>
      '可選，填寫兩位代碼，以逗號或空格分隔。留空：CN 開啟反代，其余直連；填寫后：僅列表內國家/地區直連，其余開啟反代。';

  @override
  String get settingsGatewayCountriesInvalid => '請輸入兩位國家/地區代碼，例如 US、JP、HK。';

  @override
  String get settingsGatewayLookupFailed => '國家/地區查詢失敗，已保留當前連接方式。';

  @override
  String get settingsGatewayCountryPending => '等待查詢網路所在國家/地區，暫時保留當前連接方式。';

  @override
  String settingsGatewayCountryStatus(String country, String route) {
    return '網路所在國家/地區：$country · $route';
  }

  @override
  String get settingsGatewayRouteProxy => '反代已開啟';

  @override
  String get settingsGatewayRouteDirect => '直連';

  @override
  String get settingsGatewayRecheck => '重新查詢國家/地區';

  @override
  String get lyricsTranslate => '顯示譯詞';

  @override
  String get lyricsCancelTranslation => '取消譯詞';

  @override
  String get lyricsTranslationFailed => '譯詞查找失敗，點擊重試';

  @override
  String get lyricsTranslating => '正在查找譯詞 · 點擊取消';

  @override
  String get settingsLyricsAutoTranslate => '自動翻譯歌詞';

  @override
  String get settingsLyricsAutoTranslateSubtitle =>
      '自動尋找已有譯文。中文譯詞依曲名、歌手優先查詢 QQ 音樂，缺失或不完整時查網易雲，啟用補全時最後查 LRCLIB；只採用不遺失已譯行的更完整版本。簡繁體跟隨介面。';

  @override
  String get settingsLyricsExcludeInterface => '不自動翻譯界面語言';

  @override
  String get settingsLyricsExcluded => '其他不自動翻譯的語言';

  @override
  String get settingsLyricsExcludedHint =>
      '用逗號分隔：en, ja, zh-Hans（簡體）, zh-Hant（繁體）；zh 排除全部中文，留空清除';

  @override
  String get settingsLyricsExcludedInvalid =>
      '請輸入語言代碼，例如 en、ja、zh-Hans、zh-Hant';

  @override
  String get settingsCanvas => 'Spotify Canvas 動態封面';

  @override
  String get settingsCanvasSubtitle => '播放時顯示官方短片；無 Canvas 或減少動態效果時顯示靜態封面。';

  @override
  String get settingsLanguageZhHant => '繁體中文';

  @override
  String get lyricsTranslationUnavailable => '暫無對應語言的譯詞';

  @override
  String get settingsLanguageJa => '日本語';

  @override
  String get homeRefresh => '重新整理首頁';

  @override
  String get homeRefreshFailed => '重新整理失敗，請檢查網路後再試。';

  @override
  String get loginTitle => '登入 Spotify';

  @override
  String get loginSubtitle => '在 Spotify 官方登入頁面登入一次，\n其餘授權皆會自動完成';

  @override
  String get loginTermsNotice => '以官方用戶端身分登入不符合 Spotify 服務條款，建議使用其他帳號。';

  @override
  String get loginPasswordPrivate => 'Flutify 不會接觸你的密碼';

  @override
  String get loginOfficialPage => '使用 Spotify 官方頁面完成帳號登入';

  @override
  String get loginRemoteDevices => '登入後可遙控你的其他 Spotify 裝置';

  @override
  String loginSignedInAs(String name) {
    return '已登入為 $name';
  }

  @override
  String get loginPlaybackReady => '全曲播放已就緒';

  @override
  String get loginBack => '返回';

  @override
  String get loginFailed => '登入失敗';

  @override
  String get webLoginTitle => '全曲播放：網頁登入';

  @override
  String get webLoginCardTitle => '全曲播放（網頁登入）';

  @override
  String get webLoginReady => '已就緒，可以播放完整曲目';

  @override
  String get webLoginRequired => '登入一次以啟用完整曲目播放';

  @override
  String get webLoginConsentHint => '如果頁面正在等待確認，請按「同意」完成授權；其餘步驟已自動完成';

  @override
  String get webLoginPreparing => '正在取得播放憑證…';

  @override
  String get webLoginAuthorizing => '正在完成帳號授權…';

  @override
  String get webLoginFinishing => '正在完成登入…';

  @override
  String get webLoginBackgroundHint => '登入已完成，剩餘步驟會在背景自動進行';

  @override
  String get webLoginGoogleHint =>
      '使用 Google 註冊的帳號：請在此處使用「電子郵件 + 密碼」登入；若沒有密碼，可先到 Spotify 官網透過「忘記密碼」設定。';

  @override
  String get loginBrowserFallback => '無法自動開啟瀏覽器，登入連結已複製，請貼到瀏覽器中開啟';

  @override
  String get loginBrowserTitle => '在瀏覽器中完成登入';

  @override
  String get loginBrowserSubtitle => '登入並同意授權後，此處會自動繼續';

  @override
  String get loginReopen => '重新開啟';

  @override
  String get loginLinkCopied => '登入連結已複製';

  @override
  String get loginCopyLink => '複製連結';

  @override
  String get updatesTitle => '軟體更新';

  @override
  String get updatesMode => '更新方式';

  @override
  String get updatesManual => '手動更新';

  @override
  String get updatesAutomatic => '自動下載更新';

  @override
  String get updatesDisabled => '不檢查更新';

  @override
  String get updatesHint => '自動檢查新版本與更新內容。自動模式在背景下載，完成後由你確認安裝，不會中斷播放。';

  @override
  String get updatesCheck => '檢查更新';

  @override
  String get updatesChecking => '正在檢查更新…';

  @override
  String get updatesCurrent => '目前版本';

  @override
  String get updatesUpToDate => '已是最新版本';

  @override
  String get updatesAvailable => '發現新版本';

  @override
  String get updatesNotes => '更新內容';

  @override
  String get updatesNoNotes => '此版本未提供更新說明。';

  @override
  String get updatesDownload => '下載更新';

  @override
  String get updatesDownloading => '正在下載並驗證…';

  @override
  String get updatesReady => '更新已就緒';

  @override
  String get updatesReadyHint => '更新套件已下載並通過驗證。安裝會關閉應用程式；也可以稍後從設定繼續。';

  @override
  String get updatesAndroidHint => 'APK 已下載並通過驗證。確認後開啟系統安裝程式。';

  @override
  String get updatesInstall => '重新啟動並安裝';

  @override
  String get updatesInstallApk => '安裝 APK';

  @override
  String get updatesInstalling => '正在準備安裝…';

  @override
  String get updatesSkip => '略過此次更新';

  @override
  String get updatesLater => '稍後';

  @override
  String get updatesPage => '手動更新 · 發布頁面';

  @override
  String get updatesFailed => '更新失敗，請重試或前往發布頁面。';

  @override
  String get updatesPermission => '請允許 Flutify 安裝未知來源應用程式，返回後再次點選「安裝 APK」。';

  @override
  String get updatesUnsupported => '此平台暫不提供應用程式內安裝，請透過發布頁面手動更新。';

  @override
  String get updatesDetails => '查看更新';
}
