import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
    Locale('zh'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  ];

  /// No description provided for @playbackRetryWaiting.
  ///
  /// In zh, this message translates to:
  /// **'网络连接失败，{seconds} 秒后第 {attempt}/{total} 次重试'**
  String playbackRetryWaiting(int attempt, int total, int seconds);

  /// No description provided for @playbackRetryRunning.
  ///
  /// In zh, this message translates to:
  /// **'正在重新连接，第 {attempt}/{total} 次重试'**
  String playbackRetryRunning(int attempt, int total);

  /// No description provided for @appTitle.
  ///
  /// In zh, this message translates to:
  /// **'Flutify'**
  String get appTitle;

  /// No description provided for @shellBack.
  ///
  /// In zh, this message translates to:
  /// **'后退'**
  String get shellBack;

  /// No description provided for @shellForward.
  ///
  /// In zh, this message translates to:
  /// **'前进'**
  String get shellForward;

  /// No description provided for @shellHome.
  ///
  /// In zh, this message translates to:
  /// **'主页'**
  String get shellHome;

  /// No description provided for @shellSearchShortcut.
  ///
  /// In zh, this message translates to:
  /// **'Ctrl K'**
  String get shellSearchShortcut;

  /// No description provided for @shellAccountMenu.
  ///
  /// In zh, this message translates to:
  /// **'账号'**
  String get shellAccountMenu;

  /// No description provided for @shellCollapseLibrary.
  ///
  /// In zh, this message translates to:
  /// **'收起音乐库'**
  String get shellCollapseLibrary;

  /// No description provided for @shellExpandLibrary.
  ///
  /// In zh, this message translates to:
  /// **'展开音乐库'**
  String get shellExpandLibrary;

  /// No description provided for @shellPlaybackStatus.
  ///
  /// In zh, this message translates to:
  /// **'播放状态'**
  String get shellPlaybackStatus;

  /// No description provided for @shellHidePanel.
  ///
  /// In zh, this message translates to:
  /// **'隐藏'**
  String get shellHidePanel;

  /// No description provided for @shellAboutArtist.
  ///
  /// In zh, this message translates to:
  /// **'关于艺人'**
  String get shellAboutArtist;

  /// No description provided for @shellMonthlyFollowers.
  ///
  /// In zh, this message translates to:
  /// **'{count} 位粉丝'**
  String shellMonthlyFollowers(String count);

  /// No description provided for @shellSignInTitle.
  ///
  /// In zh, this message translates to:
  /// **'登录后查看你的音乐库'**
  String get shellSignInTitle;

  /// No description provided for @shellSignInMessage.
  ///
  /// In zh, this message translates to:
  /// **'收藏的歌单、专辑和艺人会显示在这里。'**
  String get shellSignInMessage;

  /// No description provided for @shellSignIn.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get shellSignIn;

  /// No description provided for @windowMinimize.
  ///
  /// In zh, this message translates to:
  /// **'最小化'**
  String get windowMinimize;

  /// No description provided for @windowMaximize.
  ///
  /// In zh, this message translates to:
  /// **'最大化'**
  String get windowMaximize;

  /// No description provided for @windowRestore.
  ///
  /// In zh, this message translates to:
  /// **'向下还原'**
  String get windowRestore;

  /// No description provided for @windowClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get windowClose;

  /// No description provided for @menuPlayback.
  ///
  /// In zh, this message translates to:
  /// **'播放'**
  String get menuPlayback;

  /// No description provided for @menuNavigate.
  ///
  /// In zh, this message translates to:
  /// **'导航'**
  String get menuNavigate;

  /// No description provided for @menuEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get menuEdit;

  /// No description provided for @menuUndo.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get menuUndo;

  /// No description provided for @menuRedo.
  ///
  /// In zh, this message translates to:
  /// **'重做'**
  String get menuRedo;

  /// No description provided for @menuCut.
  ///
  /// In zh, this message translates to:
  /// **'剪切'**
  String get menuCut;

  /// No description provided for @menuCopy.
  ///
  /// In zh, this message translates to:
  /// **'拷贝'**
  String get menuCopy;

  /// No description provided for @menuPaste.
  ///
  /// In zh, this message translates to:
  /// **'粘贴'**
  String get menuPaste;

  /// No description provided for @menuSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get menuSelectAll;

  /// No description provided for @menuWindow.
  ///
  /// In zh, this message translates to:
  /// **'窗口'**
  String get menuWindow;

  /// No description provided for @menuSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置…'**
  String get menuSettings;

  /// No description provided for @commonCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get commonCancel;

  /// No description provided for @commonCreate.
  ///
  /// In zh, this message translates to:
  /// **'创建'**
  String get commonCreate;

  /// No description provided for @commonDone.
  ///
  /// In zh, this message translates to:
  /// **'完成'**
  String get commonDone;

  /// No description provided for @commonClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get commonClose;

  /// No description provided for @commonClear.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get commonClear;

  /// No description provided for @commonRemove.
  ///
  /// In zh, this message translates to:
  /// **'移除'**
  String get commonRemove;

  /// No description provided for @commonRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get commonRetry;

  /// 分页列表加载下一页的按钮
  ///
  /// In zh, this message translates to:
  /// **'加载更多'**
  String get commonLoadMore;

  /// No description provided for @commonMoreOptions.
  ///
  /// In zh, this message translates to:
  /// **'更多选项'**
  String get commonMoreOptions;

  /// No description provided for @commonShowAll.
  ///
  /// In zh, this message translates to:
  /// **'显示全部'**
  String get commonShowAll;

  /// No description provided for @commonSeeMore.
  ///
  /// In zh, this message translates to:
  /// **'查看更多'**
  String get commonSeeMore;

  /// No description provided for @commonShowLess.
  ///
  /// In zh, this message translates to:
  /// **'收起'**
  String get commonShowLess;

  /// No description provided for @commonSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get commonSettings;

  /// No description provided for @commonShare.
  ///
  /// In zh, this message translates to:
  /// **'分享'**
  String get commonShare;

  /// 副标题中两段信息的连接，如「歌单 · Spotify」
  ///
  /// In zh, this message translates to:
  /// **'{first} · {second}'**
  String subtitleJoin(String first, String second);

  /// No description provided for @navHome.
  ///
  /// In zh, this message translates to:
  /// **'主页'**
  String get navHome;

  /// No description provided for @navSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get navSearch;

  /// No description provided for @navLibrary.
  ///
  /// In zh, this message translates to:
  /// **'音乐库'**
  String get navLibrary;

  /// No description provided for @typeTrack.
  ///
  /// In zh, this message translates to:
  /// **'歌曲'**
  String get typeTrack;

  /// No description provided for @typeArtist.
  ///
  /// In zh, this message translates to:
  /// **'艺人'**
  String get typeArtist;

  /// No description provided for @typePlaylist.
  ///
  /// In zh, this message translates to:
  /// **'歌单'**
  String get typePlaylist;

  /// No description provided for @typePodcast.
  ///
  /// In zh, this message translates to:
  /// **'播客'**
  String get typePodcast;

  /// No description provided for @podcastEpisodeCount.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 集}}'**
  String podcastEpisodeCount(int count);

  /// No description provided for @podcastPlayed.
  ///
  /// In zh, this message translates to:
  /// **'已播完'**
  String get podcastPlayed;

  /// No description provided for @podcastResumeFrom.
  ///
  /// In zh, this message translates to:
  /// **'播至 {position}'**
  String podcastResumeFrom(String position);

  /// No description provided for @podcastEmpty.
  ///
  /// In zh, this message translates to:
  /// **'这个节目暂时没有单集'**
  String get podcastEmpty;

  /// No description provided for @podcastLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'节目加载失败，请检查网络后重试'**
  String get podcastLoadFailed;

  /// No description provided for @typeAlbum.
  ///
  /// In zh, this message translates to:
  /// **'专辑'**
  String get typeAlbum;

  /// No description provided for @typeSingle.
  ///
  /// In zh, this message translates to:
  /// **'单曲'**
  String get typeSingle;

  /// No description provided for @typeCompilation.
  ///
  /// In zh, this message translates to:
  /// **'合辑'**
  String get typeCompilation;

  /// No description provided for @filterAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get filterAll;

  /// No description provided for @filterMusic.
  ///
  /// In zh, this message translates to:
  /// **'音乐'**
  String get filterMusic;

  /// No description provided for @filterPodcasts.
  ///
  /// In zh, this message translates to:
  /// **'播客'**
  String get filterPodcasts;

  /// No description provided for @filterSongs.
  ///
  /// In zh, this message translates to:
  /// **'歌曲'**
  String get filterSongs;

  /// No description provided for @filterArtists.
  ///
  /// In zh, this message translates to:
  /// **'艺人'**
  String get filterArtists;

  /// No description provided for @filterPlaylists.
  ///
  /// In zh, this message translates to:
  /// **'歌单'**
  String get filterPlaylists;

  /// No description provided for @filterAlbums.
  ///
  /// In zh, this message translates to:
  /// **'专辑'**
  String get filterAlbums;

  /// No description provided for @songCount.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 首歌曲}}'**
  String songCount(int count);

  /// 粉丝数，count 为已格式化的紧凑数字（如 1.2 万）
  ///
  /// In zh, this message translates to:
  /// **'{count} 位粉丝'**
  String followerCount(String count);

  /// No description provided for @durationHoursMinutes.
  ///
  /// In zh, this message translates to:
  /// **'{hours} 小时 {minutes} 分钟'**
  String durationHoursMinutes(int hours, int minutes);

  /// No description provided for @durationMinutesSeconds.
  ///
  /// In zh, this message translates to:
  /// **'{minutes} 分 {seconds} 秒'**
  String durationMinutesSeconds(int minutes, int seconds);

  /// 歌曲数与总时长的连接，如「12 首歌曲，45 分 12 秒」
  ///
  /// In zh, this message translates to:
  /// **'{count}，{duration}'**
  String countAndDuration(String count, String duration);

  /// No description provided for @greetingMorning.
  ///
  /// In zh, this message translates to:
  /// **'早上好'**
  String get greetingMorning;

  /// No description provided for @greetingAfternoon.
  ///
  /// In zh, this message translates to:
  /// **'下午好'**
  String get greetingAfternoon;

  /// No description provided for @greetingEvening.
  ///
  /// In zh, this message translates to:
  /// **'晚上好'**
  String get greetingEvening;

  /// No description provided for @likedSongs.
  ///
  /// In zh, this message translates to:
  /// **'已点赞的歌曲'**
  String get likedSongs;

  /// No description provided for @likedSongsDescription.
  ///
  /// In zh, this message translates to:
  /// **'你喜欢的所有歌曲都在这里。'**
  String get likedSongsDescription;

  /// No description provided for @likeAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加到已点赞的歌曲'**
  String get likeAdd;

  /// No description provided for @likeRemove.
  ///
  /// In zh, this message translates to:
  /// **'从已点赞的歌曲中移除'**
  String get likeRemove;

  /// No description provided for @libraryAdd.
  ///
  /// In zh, this message translates to:
  /// **'保存到音乐库'**
  String get libraryAdd;

  /// No description provided for @libraryRemove.
  ///
  /// In zh, this message translates to:
  /// **'从音乐库中移除'**
  String get libraryRemove;

  /// No description provided for @homeLoadFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'无法加载推荐内容'**
  String get homeLoadFailedTitle;

  /// No description provided for @homeLoadFailedMessage.
  ///
  /// In zh, this message translates to:
  /// **'请检查网络连接后重试。'**
  String get homeLoadFailedMessage;

  /// No description provided for @authSessionExpiredTitle.
  ///
  /// In zh, this message translates to:
  /// **'登录已过期'**
  String get authSessionExpiredTitle;

  /// No description provided for @authSessionExpiredMessage.
  ///
  /// In zh, this message translates to:
  /// **'Spotify 已让这次登录失效（例如在其他地方退出了所有设备或修改了密码），请重新登录。'**
  String get authSessionExpiredMessage;

  /// No description provided for @authSignInAgain.
  ///
  /// In zh, this message translates to:
  /// **'重新登录'**
  String get authSignInAgain;

  /// No description provided for @homeEmptyTitle.
  ///
  /// In zh, this message translates to:
  /// **'这里暂时没有内容'**
  String get homeEmptyTitle;

  /// No description provided for @homeEmptyMessage.
  ///
  /// In zh, this message translates to:
  /// **'换个筛选标签看看，或稍后再来。'**
  String get homeEmptyMessage;

  /// No description provided for @homeClearFilter.
  ///
  /// In zh, this message translates to:
  /// **'清除筛选'**
  String get homeClearFilter;

  /// No description provided for @homePodcastUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'暂不支持播客，敬请期待'**
  String get homePodcastUnsupported;

  /// No description provided for @homeTypePodcast.
  ///
  /// In zh, this message translates to:
  /// **'播客'**
  String get homeTypePodcast;

  /// No description provided for @homeTypeEpisode.
  ///
  /// In zh, this message translates to:
  /// **'单集'**
  String get homeTypeEpisode;

  /// No description provided for @searchHint.
  ///
  /// In zh, this message translates to:
  /// **'你想听什么？'**
  String get searchHint;

  /// No description provided for @searchRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近搜索'**
  String get searchRecent;

  /// No description provided for @searchClearAll.
  ///
  /// In zh, this message translates to:
  /// **'全部清除'**
  String get searchClearAll;

  /// No description provided for @searchBrowseAll.
  ///
  /// In zh, this message translates to:
  /// **'浏览全部'**
  String get searchBrowseAll;

  /// No description provided for @searchCategoriesFailedTitle.
  ///
  /// In zh, this message translates to:
  /// **'无法加载分类'**
  String get searchCategoriesFailedTitle;

  /// No description provided for @searchCategoriesFailedMessage.
  ///
  /// In zh, this message translates to:
  /// **'请检查网络连接后重试。'**
  String get searchCategoriesFailedMessage;

  /// 搜索请求失败的标题，与没有匹配结果区分
  ///
  /// In zh, this message translates to:
  /// **'无法加载搜索结果'**
  String get searchFailedTitle;

  /// 搜索首次加载或续页失败时的提示
  ///
  /// In zh, this message translates to:
  /// **'请检查网络连接后重试，已加载的结果会保留。'**
  String get searchFailedMessage;

  /// No description provided for @searchNoResultsTitle.
  ///
  /// In zh, this message translates to:
  /// **'未找到与“{query}”相关的结果'**
  String searchNoResultsTitle(String query);

  /// No description provided for @searchNoResultsMessage.
  ///
  /// In zh, this message translates to:
  /// **'请检查拼写，或换个关键词试试。'**
  String get searchNoResultsMessage;

  /// No description provided for @searchFilterEmptyTitle.
  ///
  /// In zh, this message translates to:
  /// **'该分类下暂无结果'**
  String get searchFilterEmptyTitle;

  /// No description provided for @searchFilterEmptyMessage.
  ///
  /// In zh, this message translates to:
  /// **'换个筛选条件，查看更多结果。'**
  String get searchFilterEmptyMessage;

  /// No description provided for @searchCategoryMix.
  ///
  /// In zh, this message translates to:
  /// **'{name} 精选'**
  String searchCategoryMix(String name);

  /// No description provided for @searchCategoryMixDescription.
  ///
  /// In zh, this message translates to:
  /// **'精选 {name} 好歌，新鲜好听。'**
  String searchCategoryMixDescription(String name);

  /// No description provided for @librarySearchHint.
  ///
  /// In zh, this message translates to:
  /// **'在音乐库中搜索'**
  String get librarySearchHint;

  /// No description provided for @libraryCloseSearch.
  ///
  /// In zh, this message translates to:
  /// **'关闭搜索'**
  String get libraryCloseSearch;

  /// No description provided for @libraryCreatePlaylist.
  ///
  /// In zh, this message translates to:
  /// **'创建歌单'**
  String get libraryCreatePlaylist;

  /// No description provided for @libraryClearFilter.
  ///
  /// In zh, this message translates to:
  /// **'清除筛选'**
  String get libraryClearFilter;

  /// No description provided for @librarySortRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近添加'**
  String get librarySortRecent;

  /// No description provided for @librarySortAlphabetical.
  ///
  /// In zh, this message translates to:
  /// **'按字母顺序'**
  String get librarySortAlphabetical;

  /// No description provided for @libraryListView.
  ///
  /// In zh, this message translates to:
  /// **'列表视图'**
  String get libraryListView;

  /// No description provided for @libraryGridView.
  ///
  /// In zh, this message translates to:
  /// **'网格视图'**
  String get libraryGridView;

  /// No description provided for @libraryEmptyTitle.
  ///
  /// In zh, this message translates to:
  /// **'这里还没有内容'**
  String get libraryEmptyTitle;

  /// No description provided for @libraryEmptyMessage.
  ///
  /// In zh, this message translates to:
  /// **'收藏的歌单、艺人和专辑会显示在这里。'**
  String get libraryEmptyMessage;

  /// No description provided for @libraryNewPlaylistName.
  ///
  /// In zh, this message translates to:
  /// **'我的歌单 #{number}'**
  String libraryNewPlaylistName(int number);

  /// No description provided for @playlistDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除歌单'**
  String get playlistDelete;

  /// No description provided for @playlistLikedEmpty.
  ///
  /// In zh, this message translates to:
  /// **'你点赞的歌曲会显示在这里。\n点按爱心图标即可收藏歌曲。'**
  String get playlistLikedEmpty;

  /// No description provided for @playlistOwnEmpty.
  ///
  /// In zh, this message translates to:
  /// **'来为你的歌单找些歌曲吧。\n在任意歌曲的菜单中选择“添加到歌单”。'**
  String get playlistOwnEmpty;

  /// No description provided for @playlistEmpty.
  ///
  /// In zh, this message translates to:
  /// **'这个歌单还没有歌曲。'**
  String get playlistEmpty;

  /// No description provided for @albumNoTracks.
  ///
  /// In zh, this message translates to:
  /// **'这张专辑暂无可播放的曲目。'**
  String get albumNoTracks;

  /// No description provided for @albumMoreBy.
  ///
  /// In zh, this message translates to:
  /// **'{name} 的更多作品'**
  String albumMoreBy(String name);

  /// No description provided for @artistPopular.
  ///
  /// In zh, this message translates to:
  /// **'热门歌曲'**
  String get artistPopular;

  /// No description provided for @artistNoPopular.
  ///
  /// In zh, this message translates to:
  /// **'暂无热门歌曲。'**
  String get artistNoPopular;

  /// 艺人专辑二级页面的空列表提示
  ///
  /// In zh, this message translates to:
  /// **'暂无可显示的专辑。'**
  String get artistNoAlbums;

  /// 艺人歌曲二级页面的空列表提示
  ///
  /// In zh, this message translates to:
  /// **'暂无可显示的歌曲。'**
  String get artistNoSongs;

  /// No description provided for @artistDiscography.
  ///
  /// In zh, this message translates to:
  /// **'作品'**
  String get artistDiscography;

  /// No description provided for @artistFollow.
  ///
  /// In zh, this message translates to:
  /// **'关注'**
  String get artistFollow;

  /// No description provided for @artistFollowing.
  ///
  /// In zh, this message translates to:
  /// **'已关注'**
  String get artistFollowing;

  /// No description provided for @playingFromPlaylist.
  ///
  /// In zh, this message translates to:
  /// **'正在播放歌单'**
  String get playingFromPlaylist;

  /// No description provided for @playingFromAlbum.
  ///
  /// In zh, this message translates to:
  /// **'正在播放专辑'**
  String get playingFromAlbum;

  /// No description provided for @playingFromArtist.
  ///
  /// In zh, this message translates to:
  /// **'正在播放艺人'**
  String get playingFromArtist;

  /// No description provided for @playingFromSearch.
  ///
  /// In zh, this message translates to:
  /// **'正在播放搜索结果'**
  String get playingFromSearch;

  /// No description provided for @playingFromLibrary.
  ///
  /// In zh, this message translates to:
  /// **'正在播放音乐库'**
  String get playingFromLibrary;

  /// No description provided for @nowPlaying.
  ///
  /// In zh, this message translates to:
  /// **'正在播放'**
  String get nowPlaying;

  /// No description provided for @openNowPlaying.
  ///
  /// In zh, this message translates to:
  /// **'打开正在播放'**
  String get openNowPlaying;

  /// No description provided for @playerNothingPlayingTitle.
  ///
  /// In zh, this message translates to:
  /// **'当前没有播放内容'**
  String get playerNothingPlayingTitle;

  /// No description provided for @playerNothingPlayingMessage.
  ///
  /// In zh, this message translates to:
  /// **'选择一首歌曲、专辑或歌单，开始收听吧。'**
  String get playerNothingPlayingMessage;

  /// No description provided for @playerIdleHint.
  ///
  /// In zh, this message translates to:
  /// **'暂无播放 — 挑点音乐来听吧'**
  String get playerIdleHint;

  /// No description provided for @playerThisDevice.
  ///
  /// In zh, this message translates to:
  /// **'正在本设备上收听'**
  String get playerThisDevice;

  /// No description provided for @playerShuffleOn.
  ///
  /// In zh, this message translates to:
  /// **'开启随机播放'**
  String get playerShuffleOn;

  /// No description provided for @playerShuffleOff.
  ///
  /// In zh, this message translates to:
  /// **'关闭随机播放'**
  String get playerShuffleOff;

  /// No description provided for @playerRepeatOn.
  ///
  /// In zh, this message translates to:
  /// **'开启列表循环'**
  String get playerRepeatOn;

  /// No description provided for @playerRepeatOneOn.
  ///
  /// In zh, this message translates to:
  /// **'开启单曲循环'**
  String get playerRepeatOneOn;

  /// No description provided for @playerRepeatOff.
  ///
  /// In zh, this message translates to:
  /// **'关闭循环'**
  String get playerRepeatOff;

  /// No description provided for @playerNext.
  ///
  /// In zh, this message translates to:
  /// **'下一首'**
  String get playerNext;

  /// No description provided for @playerPrevious.
  ///
  /// In zh, this message translates to:
  /// **'上一首'**
  String get playerPrevious;

  /// No description provided for @playerMute.
  ///
  /// In zh, this message translates to:
  /// **'静音'**
  String get playerMute;

  /// No description provided for @playerUnmute.
  ///
  /// In zh, this message translates to:
  /// **'取消静音'**
  String get playerUnmute;

  /// No description provided for @playerLyricsFullscreen.
  ///
  /// In zh, this message translates to:
  /// **'全屏歌词'**
  String get playerLyricsFullscreen;

  /// No description provided for @playerSwipeHint.
  ///
  /// In zh, this message translates to:
  /// **'左右滑动封面切换歌曲'**
  String get playerSwipeHint;

  /// No description provided for @playbackErrorSignIn.
  ///
  /// In zh, this message translates to:
  /// **'登录后才能播放'**
  String get playbackErrorSignIn;

  /// No description provided for @playbackErrorWebSignIn.
  ///
  /// In zh, this message translates to:
  /// **'全曲播放需要先完成 Web 登录'**
  String get playbackErrorWebSignIn;

  /// No description provided for @webLoginAction.
  ///
  /// In zh, this message translates to:
  /// **'Web 登录'**
  String get webLoginAction;

  /// No description provided for @webLoginSuccess.
  ///
  /// In zh, this message translates to:
  /// **'Web 登录成功，全曲播放已就绪'**
  String get webLoginSuccess;

  /// No description provided for @playbackErrorUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'「{track}」暂时无法播放'**
  String playbackErrorUnavailable(String track);

  /// No description provided for @playbackErrorSkipped.
  ///
  /// In zh, this message translates to:
  /// **'「{track}」暂时无法播放，已跳过'**
  String playbackErrorSkipped(String track);

  /// No description provided for @playbackErrorNetwork.
  ///
  /// In zh, this message translates to:
  /// **'「{track}」加载失败，请检查网络'**
  String playbackErrorNetwork(String track);

  /// No description provided for @playbackErrorWidevine.
  ///
  /// In zh, this message translates to:
  /// **'「{track}」无法解密播放：此设备缺少 Widevine 组件'**
  String playbackErrorWidevine(String track);

  /// No description provided for @playbackErrorFairPlay.
  ///
  /// In zh, this message translates to:
  /// **'「{track}」无法解密播放：此设备无法创建 FairPlay 会话'**
  String playbackErrorFairPlay(String track);

  /// No description provided for @playbackErrorAutoPaused.
  ///
  /// In zh, this message translates to:
  /// **'连续 {count} 首无法播放，已暂停'**
  String playbackErrorAutoPaused(int count);

  /// No description provided for @detailSignInRequired.
  ///
  /// In zh, this message translates to:
  /// **'登录后即可查看这里的内容'**
  String get detailSignInRequired;

  /// No description provided for @detailLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法加载，请检查网络后重试'**
  String get detailLoadFailed;

  /// No description provided for @queueTitle.
  ///
  /// In zh, this message translates to:
  /// **'播放队列'**
  String get queueTitle;

  /// No description provided for @queueNextInQueue.
  ///
  /// In zh, this message translates to:
  /// **'队列中的下一首'**
  String get queueNextInQueue;

  /// No description provided for @queueClear.
  ///
  /// In zh, this message translates to:
  /// **'清空队列'**
  String get queueClear;

  /// No description provided for @queueNextUp.
  ///
  /// In zh, this message translates to:
  /// **'接下来播放'**
  String get queueNextUp;

  /// No description provided for @queueNextFrom.
  ///
  /// In zh, this message translates to:
  /// **'接下来播放：{name}'**
  String queueNextFrom(String name);

  /// No description provided for @queueEmpty.
  ///
  /// In zh, this message translates to:
  /// **'队列中暂无待播歌曲'**
  String get queueEmpty;

  /// No description provided for @lyricsTitle.
  ///
  /// In zh, this message translates to:
  /// **'歌词'**
  String get lyricsTitle;

  /// No description provided for @lyricsNotPlaying.
  ///
  /// In zh, this message translates to:
  /// **'未在播放'**
  String get lyricsNotPlaying;

  /// No description provided for @lyricsNothingPlayingMessage.
  ///
  /// In zh, this message translates to:
  /// **'播放一首歌曲，即可在这里查看歌词。'**
  String get lyricsNothingPlayingMessage;

  /// No description provided for @lyricsUnavailableTitle.
  ///
  /// In zh, this message translates to:
  /// **'暂无歌词'**
  String get lyricsUnavailableTitle;

  /// No description provided for @lyricsUnavailableMessage.
  ///
  /// In zh, this message translates to:
  /// **'这首歌还没有歌词。\n尽情享受音乐吧！'**
  String get lyricsUnavailableMessage;

  /// No description provided for @lyricsUnsynced.
  ///
  /// In zh, this message translates to:
  /// **'这些歌词尚未与歌曲同步。'**
  String get lyricsUnsynced;

  /// No description provided for @lyricsFromLrclib.
  ///
  /// In zh, this message translates to:
  /// **'歌词来自 LRCLIB'**
  String get lyricsFromLrclib;

  /// No description provided for @lyricsImmersive.
  ///
  /// In zh, this message translates to:
  /// **'沉浸式歌词'**
  String get lyricsImmersive;

  /// No description provided for @lyricsExpand.
  ///
  /// In zh, this message translates to:
  /// **'放大歌词'**
  String get lyricsExpand;

  /// No description provided for @lyricsCollapse.
  ///
  /// In zh, this message translates to:
  /// **'收起歌词'**
  String get lyricsCollapse;

  /// No description provided for @lyricsExitImmersive.
  ///
  /// In zh, this message translates to:
  /// **'退出全屏歌词（Esc）'**
  String get lyricsExitImmersive;

  /// No description provided for @lyricsFillScreen.
  ///
  /// In zh, this message translates to:
  /// **'铺满整个屏幕（F11）'**
  String get lyricsFillScreen;

  /// No description provided for @lyricsFillWindow.
  ///
  /// In zh, this message translates to:
  /// **'只铺满窗口（F11）'**
  String get lyricsFillWindow;

  /// No description provided for @deviceConnectTitle.
  ///
  /// In zh, this message translates to:
  /// **'连接到设备'**
  String get deviceConnectTitle;

  /// No description provided for @deviceConnectDescription.
  ///
  /// In zh, this message translates to:
  /// **'通过 Spotify Connect，可在电脑、手机或智能音箱上无缝播放。'**
  String get deviceConnectDescription;

  /// No description provided for @deviceCurrent.
  ///
  /// In zh, this message translates to:
  /// **'当前收听设备'**
  String get deviceCurrent;

  /// No description provided for @deviceSpotifyConnect.
  ///
  /// In zh, this message translates to:
  /// **'Spotify Connect'**
  String get deviceSpotifyConnect;

  /// No description provided for @connectThisDevice.
  ///
  /// In zh, this message translates to:
  /// **'此设备'**
  String get connectThisDevice;

  /// No description provided for @connectTakeOver.
  ///
  /// In zh, this message translates to:
  /// **'在此设备继续播放'**
  String get connectTakeOver;

  /// No description provided for @connectPlayingOn.
  ///
  /// In zh, this message translates to:
  /// **'正在 {device} 上播放'**
  String connectPlayingOn(String device);

  /// No description provided for @connectOtherDevices.
  ///
  /// In zh, this message translates to:
  /// **'选择其他设备'**
  String get connectOtherDevices;

  /// No description provided for @connectNoDevices.
  ///
  /// In zh, this message translates to:
  /// **'没有找到其他设备'**
  String get connectNoDevices;

  /// No description provided for @connectNoDevicesHint.
  ///
  /// In zh, this message translates to:
  /// **'在手机、电脑或音箱上打开 Spotify，并登录同一账号'**
  String get connectNoDevicesHint;

  /// No description provided for @connectUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'使用桌面版方式登录后，即可遥控其他设备上的 Spotify'**
  String get connectUnavailable;

  /// No description provided for @connectConnecting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接 Spotify Connect…'**
  String get connectConnecting;

  /// No description provided for @connectOffline.
  ///
  /// In zh, this message translates to:
  /// **'连接已断开，正在重试…'**
  String get connectOffline;

  /// No description provided for @connectSameNetwork.
  ///
  /// In zh, this message translates to:
  /// **'同一网络'**
  String get connectSameNetwork;

  /// No description provided for @connectCommandFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作未成功：免费账号可能不支持远程执行此操作'**
  String get connectCommandFailed;

  /// No description provided for @connectVolumeUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'{device} 不支持远程调节音量'**
  String connectVolumeUnsupported(String device);

  /// No description provided for @connectVolume.
  ///
  /// In zh, this message translates to:
  /// **'设备音量'**
  String get connectVolume;

  /// No description provided for @trackAddToPlaylist.
  ///
  /// In zh, this message translates to:
  /// **'添加到歌单'**
  String get trackAddToPlaylist;

  /// No description provided for @trackAddToQueue.
  ///
  /// In zh, this message translates to:
  /// **'添加到播放队列'**
  String get trackAddToQueue;

  /// No description provided for @trackGoToAlbum.
  ///
  /// In zh, this message translates to:
  /// **'前往专辑'**
  String get trackGoToAlbum;

  /// No description provided for @trackGoToRadio.
  ///
  /// In zh, this message translates to:
  /// **'前往歌曲电台'**
  String get trackGoToRadio;

  /// No description provided for @trackViewCredits.
  ///
  /// In zh, this message translates to:
  /// **'查看制作人员'**
  String get trackViewCredits;

  /// No description provided for @creditsTitle.
  ///
  /// In zh, this message translates to:
  /// **'制作人员'**
  String get creditsTitle;

  /// No description provided for @creditsSources.
  ///
  /// In zh, this message translates to:
  /// **'来源'**
  String get creditsSources;

  /// No description provided for @creditsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'这首歌暂时没有制作人员信息'**
  String get creditsEmpty;

  /// No description provided for @radioUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'这首歌暂时没有歌曲电台'**
  String get radioUnavailable;

  /// No description provided for @trackGoToArtist.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{前往艺人}}'**
  String trackGoToArtist(int count);

  /// No description provided for @trackNewPlaylist.
  ///
  /// In zh, this message translates to:
  /// **'新建歌单'**
  String get trackNewPlaylist;

  /// No description provided for @toastLikeAdded.
  ///
  /// In zh, this message translates to:
  /// **'已添加到已点赞的歌曲'**
  String get toastLikeAdded;

  /// No description provided for @toastLikeRemoved.
  ///
  /// In zh, this message translates to:
  /// **'已从已点赞的歌曲中移除'**
  String get toastLikeRemoved;

  /// No description provided for @toastAddedToQueue.
  ///
  /// In zh, this message translates to:
  /// **'已添加到播放队列'**
  String get toastAddedToQueue;

  /// No description provided for @shareCopyLink.
  ///
  /// In zh, this message translates to:
  /// **'复制链接'**
  String get shareCopyLink;

  /// No description provided for @shareCopyUri.
  ///
  /// In zh, this message translates to:
  /// **'复制 URI'**
  String get shareCopyUri;

  /// No description provided for @shareOpenWeb.
  ///
  /// In zh, this message translates to:
  /// **'网页打开'**
  String get shareOpenWeb;

  /// No description provided for @shareCopied.
  ///
  /// In zh, this message translates to:
  /// **'已复制'**
  String get shareCopied;

  /// No description provided for @shareEmbedTitle.
  ///
  /// In zh, this message translates to:
  /// **'嵌入代码'**
  String get shareEmbedTitle;

  /// No description provided for @shareEmbedSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'粘贴到网页 HTML 中，即可展示 Spotify 播放器'**
  String get shareEmbedSubtitle;

  /// No description provided for @shareEmbedStandard.
  ///
  /// In zh, this message translates to:
  /// **'标准'**
  String get shareEmbedStandard;

  /// No description provided for @shareEmbedCompact.
  ///
  /// In zh, this message translates to:
  /// **'紧凑'**
  String get shareEmbedCompact;

  /// No description provided for @shareEmbedDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get shareEmbedDark;

  /// No description provided for @shareEmbedCopy.
  ///
  /// In zh, this message translates to:
  /// **'复制代码'**
  String get shareEmbedCopy;

  /// No description provided for @shareEmbedUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'此设备的系统 WebView 暂不可用，仍可复制下方嵌入代码。'**
  String get shareEmbedUnavailable;

  /// No description provided for @shareEmbedFailed.
  ///
  /// In zh, this message translates to:
  /// **'Spotify 嵌入播放器加载失败，请检查网络后重试。'**
  String get shareEmbedFailed;

  /// No description provided for @toastAddedTo.
  ///
  /// In zh, this message translates to:
  /// **'已添加到「{name}」'**
  String toastAddedTo(String name);

  /// No description provided for @toastAlreadyIn.
  ///
  /// In zh, this message translates to:
  /// **'「{name}」中已有这首歌'**
  String toastAlreadyIn(String name);

  /// No description provided for @createPlaylistTitle.
  ///
  /// In zh, this message translates to:
  /// **'为歌单命名'**
  String get createPlaylistTitle;

  /// No description provided for @createPlaylistHint.
  ///
  /// In zh, this message translates to:
  /// **'歌单名称'**
  String get createPlaylistHint;

  /// No description provided for @createPlaylistDefaultName.
  ///
  /// In zh, this message translates to:
  /// **'我的歌单'**
  String get createPlaylistDefaultName;

  /// No description provided for @settingsAppearanceSection.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get settingsAppearanceSection;

  /// No description provided for @settingsThemeMode.
  ///
  /// In zh, this message translates to:
  /// **'主题'**
  String get settingsThemeMode;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settingsThemeSystem;

  /// No description provided for @settingsThemeLight.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get settingsThemeDark;

  /// No description provided for @settingsPureBlack.
  ///
  /// In zh, this message translates to:
  /// **'纯黑背景'**
  String get settingsPureBlack;

  /// No description provided for @settingsPureBlackSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'深色模式下使用纯黑底色，OLED 屏幕更省电'**
  String get settingsPureBlackSubtitle;

  /// No description provided for @settingsAccentSection.
  ///
  /// In zh, this message translates to:
  /// **'强调色'**
  String get settingsAccentSection;

  /// No description provided for @settingsAccentCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义颜色'**
  String get settingsAccentCustom;

  /// No description provided for @settingsDynamicAccent.
  ///
  /// In zh, this message translates to:
  /// **'跟随封面取色'**
  String get settingsDynamicAccent;

  /// No description provided for @settingsDynamicAccentSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'强调色随正在播放的专辑封面变化'**
  String get settingsDynamicAccentSubtitle;

  /// No description provided for @settingsGlassSection.
  ///
  /// In zh, this message translates to:
  /// **'液态玻璃'**
  String get settingsGlassSection;

  /// No description provided for @settingsGlassPreview.
  ///
  /// In zh, this message translates to:
  /// **'玻璃预览'**
  String get settingsGlassPreview;

  /// No description provided for @settingsGlassBlur.
  ///
  /// In zh, this message translates to:
  /// **'模糊强度'**
  String get settingsGlassBlur;

  /// No description provided for @settingsGlassOpacity.
  ///
  /// In zh, this message translates to:
  /// **'不透明度'**
  String get settingsGlassOpacity;

  /// No description provided for @settingsTextShapeSection.
  ///
  /// In zh, this message translates to:
  /// **'文字与形状'**
  String get settingsTextShapeSection;

  /// No description provided for @settingsFontScale.
  ///
  /// In zh, this message translates to:
  /// **'字号'**
  String get settingsFontScale;

  /// No description provided for @settingsFontPreview.
  ///
  /// In zh, this message translates to:
  /// **'夜空中最亮的星'**
  String get settingsFontPreview;

  /// No description provided for @settingsCornerStyle.
  ///
  /// In zh, this message translates to:
  /// **'圆角'**
  String get settingsCornerStyle;

  /// No description provided for @settingsCornerRounded.
  ///
  /// In zh, this message translates to:
  /// **'圆润'**
  String get settingsCornerRounded;

  /// No description provided for @settingsCornerStandard.
  ///
  /// In zh, this message translates to:
  /// **'标准'**
  String get settingsCornerStandard;

  /// No description provided for @settingsCornerSquare.
  ///
  /// In zh, this message translates to:
  /// **'方正'**
  String get settingsCornerSquare;

  /// No description provided for @settingsPlaybackSection.
  ///
  /// In zh, this message translates to:
  /// **'播放'**
  String get settingsPlaybackSection;

  /// No description provided for @settingsPauseAfterFailures.
  ///
  /// In zh, this message translates to:
  /// **'连续无法播放时暂停'**
  String get settingsPauseAfterFailures;

  /// No description provided for @settingsPauseAfterFailuresSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'连续 {count} 首无法播放就停下，不再继续自动跳过'**
  String settingsPauseAfterFailuresSubtitle(int count);

  /// No description provided for @settingsMotionSection.
  ///
  /// In zh, this message translates to:
  /// **'动效'**
  String get settingsMotionSection;

  /// No description provided for @settingsReduceMotion.
  ///
  /// In zh, this message translates to:
  /// **'减弱动效'**
  String get settingsReduceMotion;

  /// No description provided for @settingsReduceMotionSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'关闭流动背景、过渡与悬停等装饰性动画'**
  String get settingsReduceMotionSubtitle;

  /// No description provided for @settingsPowerSaving.
  ///
  /// In zh, this message translates to:
  /// **'省电模式'**
  String get settingsPowerSaving;

  /// No description provided for @settingsPowerSavingSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'玻璃改用磨砂底、歌词页背景不再流动；歌词滚动与动效全部保留'**
  String get settingsPowerSavingSubtitle;

  /// No description provided for @settingsFrameRate.
  ///
  /// In zh, this message translates to:
  /// **'帧率上限'**
  String get settingsFrameRate;

  /// No description provided for @settingsFrameRateSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'降低可明显减少 GPU 占用，动画速度不变'**
  String get settingsFrameRateSubtitle;

  /// No description provided for @settingsFrameRateFollow.
  ///
  /// In zh, this message translates to:
  /// **'跟随屏幕'**
  String get settingsFrameRateFollow;

  /// No description provided for @settingsFrameRateCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get settingsFrameRateCustom;

  /// No description provided for @settingsFrameRateValue.
  ///
  /// In zh, this message translates to:
  /// **'{fps} fps'**
  String settingsFrameRateValue(int fps);

  /// No description provided for @settingsResetAppearance.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认外观'**
  String get settingsResetAppearance;

  /// No description provided for @settingsCustomColorTitle.
  ///
  /// In zh, this message translates to:
  /// **'自定义强调色'**
  String get settingsCustomColorTitle;

  /// No description provided for @settingsHue.
  ///
  /// In zh, this message translates to:
  /// **'色相'**
  String get settingsHue;

  /// No description provided for @settingsSaturation.
  ///
  /// In zh, this message translates to:
  /// **'饱和度'**
  String get settingsSaturation;

  /// No description provided for @settingsBrightness.
  ///
  /// In zh, this message translates to:
  /// **'亮度'**
  String get settingsBrightness;

  /// No description provided for @settingsLanguageSection.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get settingsLanguageSection;

  /// No description provided for @settingsLanguage.
  ///
  /// In zh, this message translates to:
  /// **'界面语言'**
  String get settingsLanguage;

  /// No description provided for @settingsLanguageSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'同时影响主页推荐等由 Spotify 提供的文案'**
  String get settingsLanguageSubtitle;

  /// No description provided for @settingsLanguageSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settingsLanguageSystem;

  /// No description provided for @settingsLanguageZh.
  ///
  /// In zh, this message translates to:
  /// **'简体中文'**
  String get settingsLanguageZh;

  /// No description provided for @settingsLanguageEn.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get settingsLanguageEn;

  /// No description provided for @settingsStorageSection.
  ///
  /// In zh, this message translates to:
  /// **'存储'**
  String get settingsStorageSection;

  /// No description provided for @settingsAudioCache.
  ///
  /// In zh, this message translates to:
  /// **'音频缓存'**
  String get settingsAudioCache;

  /// No description provided for @settingsAudioCacheUsage.
  ///
  /// In zh, this message translates to:
  /// **'已用 {used}，上限 {limit}'**
  String settingsAudioCacheUsage(String used, String limit);

  /// No description provided for @settingsAudioCacheCalculating.
  ///
  /// In zh, this message translates to:
  /// **'正在计算…'**
  String get settingsAudioCacheCalculating;

  /// No description provided for @settingsAudioCacheLimit.
  ///
  /// In zh, this message translates to:
  /// **'缓存上限'**
  String get settingsAudioCacheLimit;

  /// No description provided for @settingsAudioCacheLimitSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'超出后自动删除最久没播放的歌曲'**
  String get settingsAudioCacheLimitSubtitle;

  /// No description provided for @settingsClearAudioCache.
  ///
  /// In zh, this message translates to:
  /// **'清除音频缓存'**
  String get settingsClearAudioCache;

  /// No description provided for @settingsClearAudioCacheTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除音频缓存？'**
  String get settingsClearAudioCacheTitle;

  /// No description provided for @settingsClearAudioCacheMessage.
  ///
  /// In zh, this message translates to:
  /// **'已下载的歌曲会被删除，再次播放时重新下载。正在播放的歌曲会保留。'**
  String get settingsClearAudioCacheMessage;

  /// No description provided for @settingsAudioCacheCleared.
  ///
  /// In zh, this message translates to:
  /// **'已释放 {size}'**
  String settingsAudioCacheCleared(String size);

  /// No description provided for @settingsLyricsSection.
  ///
  /// In zh, this message translates to:
  /// **'歌词'**
  String get settingsLyricsSection;

  /// No description provided for @settingsLyricsFocusPosition.
  ///
  /// In zh, this message translates to:
  /// **'当前行位置'**
  String get settingsLyricsFocusPosition;

  /// No description provided for @settingsLyricsFocusPositionSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'调整当前歌词在可见歌词区域中的高度，数值越大越靠下。'**
  String get settingsLyricsFocusPositionSubtitle;

  /// No description provided for @lyricsTranslationFromNetease.
  ///
  /// In zh, this message translates to:
  /// **'译词来自网易云音乐社区'**
  String get lyricsTranslationFromNetease;

  /// No description provided for @settingsLyricsSize.
  ///
  /// In zh, this message translates to:
  /// **'歌词字号'**
  String get settingsLyricsSize;

  /// No description provided for @settingsLyricsAlign.
  ///
  /// In zh, this message translates to:
  /// **'对齐方式'**
  String get settingsLyricsAlign;

  /// No description provided for @settingsLyricsAlignLeft.
  ///
  /// In zh, this message translates to:
  /// **'左对齐'**
  String get settingsLyricsAlignLeft;

  /// No description provided for @settingsLyricsAlignCenter.
  ///
  /// In zh, this message translates to:
  /// **'居中'**
  String get settingsLyricsAlignCenter;

  /// No description provided for @settingsLyricsBlur.
  ///
  /// In zh, this message translates to:
  /// **'其他行模糊'**
  String get settingsLyricsBlur;

  /// No description provided for @settingsLyricsImmersiveScreen.
  ///
  /// In zh, this message translates to:
  /// **'全屏歌词铺满整个屏幕'**
  String get settingsLyricsImmersiveScreen;

  /// No description provided for @settingsLyricsImmersiveScreenSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'关闭时只铺满窗口；在全屏歌词里按 F11 也能切换'**
  String get settingsLyricsImmersiveScreenSubtitle;

  /// No description provided for @settingsLyricsFallback.
  ///
  /// In zh, this message translates to:
  /// **'补全歌词'**
  String get settingsLyricsFallback;

  /// No description provided for @settingsLyricsFallbackSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'Spotify 没有逐行同步歌词时，从 LRCLIB 开放歌词库补全，并按原唱语言挑选'**
  String get settingsLyricsFallbackSubtitle;

  /// No description provided for @settingsLyricsBilingual.
  ///
  /// In zh, this message translates to:
  /// **'社区歌词翻译'**
  String get settingsLyricsBilingual;

  /// No description provided for @settingsLyricsBilingualSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'加载歌词时预取中文译词，也供任务栏歌词使用。关闭后仍可通过翻译按钮或自动翻译查找译词；查询会发送曲名与歌手到网易云音乐。'**
  String get settingsLyricsBilingualSubtitle;

  /// No description provided for @settingsTaskbarLyricsSection.
  ///
  /// In zh, this message translates to:
  /// **'任务栏歌词'**
  String get settingsTaskbarLyricsSection;

  /// No description provided for @settingsTaskbarLyrics.
  ///
  /// In zh, this message translates to:
  /// **'在任务栏显示歌词'**
  String get settingsTaskbarLyrics;

  /// No description provided for @settingsTaskbarLyricsSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'任务栏图标居中时显示在左侧，居左时显示在系统托盘左边；任务栏竖向时自动停用。悬停显示播放控制，点按打开 Flutify，右键重新获取歌词'**
  String get settingsTaskbarLyricsSubtitle;

  /// No description provided for @settingsTaskbarLyricsColor.
  ///
  /// In zh, this message translates to:
  /// **'文字颜色'**
  String get settingsTaskbarLyricsColor;

  /// No description provided for @settingsTaskbarLyricsCustomColor.
  ///
  /// In zh, this message translates to:
  /// **'自定义颜色'**
  String get settingsTaskbarLyricsCustomColor;

  /// No description provided for @settingsTaskbarLyricsChangeColor.
  ///
  /// In zh, this message translates to:
  /// **'更改'**
  String get settingsTaskbarLyricsChangeColor;

  /// No description provided for @settingsTaskbarLyricsOpacity.
  ///
  /// In zh, this message translates to:
  /// **'不透明度'**
  String get settingsTaskbarLyricsOpacity;

  /// No description provided for @settingsTaskbarLyricsFontSize.
  ///
  /// In zh, this message translates to:
  /// **'字号'**
  String get settingsTaskbarLyricsFontSize;

  /// No description provided for @settingsCopyLog.
  ///
  /// In zh, this message translates to:
  /// **'复制诊断日志'**
  String get settingsCopyLog;

  /// No description provided for @settingsCopyLogSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'反馈问题时粘贴给开发者；日志只含运行记录，不含密码'**
  String get settingsCopyLogSubtitle;

  /// No description provided for @settingsCopyLogDone.
  ///
  /// In zh, this message translates to:
  /// **'日志已复制到剪贴板'**
  String get settingsCopyLogDone;

  /// No description provided for @settingsCopyLogEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无日志'**
  String get settingsCopyLogEmpty;

  /// No description provided for @taskbarLyricsColorAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get taskbarLyricsColorAuto;

  /// No description provided for @taskbarLyricsColorWhite.
  ///
  /// In zh, this message translates to:
  /// **'白色'**
  String get taskbarLyricsColorWhite;

  /// No description provided for @taskbarLyricsColorBlack.
  ///
  /// In zh, this message translates to:
  /// **'黑色'**
  String get taskbarLyricsColorBlack;

  /// No description provided for @taskbarLyricsColorAccent.
  ///
  /// In zh, this message translates to:
  /// **'强调色'**
  String get taskbarLyricsColorAccent;

  /// No description provided for @taskbarLyricsColorCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get taskbarLyricsColorCustom;

  /// No description provided for @taskbarLyricsMenuOpen.
  ///
  /// In zh, this message translates to:
  /// **'打开 Flutify'**
  String get taskbarLyricsMenuOpen;

  /// No description provided for @taskbarLyricsMenuRefetch.
  ///
  /// In zh, this message translates to:
  /// **'重新获取歌词'**
  String get taskbarLyricsMenuRefetch;

  /// No description provided for @taskbarLyricsMenuDisable.
  ///
  /// In zh, this message translates to:
  /// **'关闭任务栏歌词'**
  String get taskbarLyricsMenuDisable;

  /// No description provided for @taskbarLyricsPreviewLine1.
  ///
  /// In zh, this message translates to:
  /// **'歌词会在这里随歌声滚动'**
  String get taskbarLyricsPreviewLine1;

  /// No description provided for @taskbarLyricsPreviewLine2.
  ///
  /// In zh, this message translates to:
  /// **'悬停即可切歌、暂停'**
  String get taskbarLyricsPreviewLine2;

  /// No description provided for @taskbarLyricsPreviewLine3.
  ///
  /// In zh, this message translates to:
  /// **'颜色与不透明度即时生效'**
  String get taskbarLyricsPreviewLine3;

  /// No description provided for @settingsOff.
  ///
  /// In zh, this message translates to:
  /// **'关'**
  String get settingsOff;

  /// No description provided for @settingsNormalize.
  ///
  /// In zh, this message translates to:
  /// **'音量均衡'**
  String get settingsNormalize;

  /// No description provided for @settingsNormalizeSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'按 Spotify 提供的响度数据，把偏响的歌调低到一致的音量'**
  String get settingsNormalizeSubtitle;

  /// No description provided for @settingsFade.
  ///
  /// In zh, this message translates to:
  /// **'歌曲间淡入淡出'**
  String get settingsFade;

  /// No description provided for @settingsFadeSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'结尾逐渐淡出，下一首淡入'**
  String get settingsFadeSubtitle;

  /// No description provided for @settingsSeconds.
  ///
  /// In zh, this message translates to:
  /// **'{count} 秒'**
  String settingsSeconds(int count);

  /// No description provided for @settingsStartupSection.
  ///
  /// In zh, this message translates to:
  /// **'启动'**
  String get settingsStartupSection;

  /// No description provided for @settingsStartPage.
  ///
  /// In zh, this message translates to:
  /// **'启动时打开'**
  String get settingsStartPage;

  /// No description provided for @settingsStartPageHome.
  ///
  /// In zh, this message translates to:
  /// **'主页'**
  String get settingsStartPageHome;

  /// No description provided for @settingsStartPageLibrary.
  ///
  /// In zh, this message translates to:
  /// **'音乐库'**
  String get settingsStartPageLibrary;

  /// No description provided for @settingsStartPageLast.
  ///
  /// In zh, this message translates to:
  /// **'上次位置'**
  String get settingsStartPageLast;

  /// No description provided for @settingsRememberWindow.
  ///
  /// In zh, this message translates to:
  /// **'记住窗口大小和位置'**
  String get settingsRememberWindow;

  /// No description provided for @settingsRememberWindowSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'下次启动时还原；显示器变化导致窗口不可见时回到屏幕中央'**
  String get settingsRememberWindowSubtitle;

  /// No description provided for @settingsConnectSection.
  ///
  /// In zh, this message translates to:
  /// **'Spotify Connect'**
  String get settingsConnectSection;

  /// No description provided for @settingsConnectEnabled.
  ///
  /// In zh, this message translates to:
  /// **'启用 Spotify Connect'**
  String get settingsConnectEnabled;

  /// No description provided for @settingsConnectEnabledSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'显示并遥控同一账号在其他设备上的播放'**
  String get settingsConnectEnabledSubtitle;

  /// No description provided for @settingsConnectDeviceName.
  ///
  /// In zh, this message translates to:
  /// **'设备名称'**
  String get settingsConnectDeviceName;

  /// No description provided for @settingsConnectDeviceNameSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'其他设备的设备列表里显示的名字，留空使用默认名'**
  String get settingsConnectDeviceNameSubtitle;

  /// No description provided for @settingsConnectUseDeviceName.
  ///
  /// In zh, this message translates to:
  /// **'使用设备名称'**
  String get settingsConnectUseDeviceName;

  /// No description provided for @settingsConnectReportOnLaunch.
  ///
  /// In zh, this message translates to:
  /// **'启动时同步播放状态'**
  String get settingsConnectReportOnLaunch;

  /// No description provided for @settingsConnectReportOnLaunchSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'打开 Flutify 后即使还没播放，也让其他设备看到 Flutify 上的当前歌曲（会接管正在空闲的播放会话）'**
  String get settingsConnectReportOnLaunchSubtitle;

  /// No description provided for @settingsRemoteLyricsLead.
  ///
  /// In zh, this message translates to:
  /// **'远程歌词提前'**
  String get settingsRemoteLyricsLead;

  /// No description provided for @settingsRemoteLyricsLeadSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'其他设备上播放时，歌词比演唱慢就调大，快就调小'**
  String get settingsRemoteLyricsLeadSubtitle;

  /// No description provided for @settingsNetworkSection.
  ///
  /// In zh, this message translates to:
  /// **'网络'**
  String get settingsNetworkSection;

  /// No description provided for @settingsProxy.
  ///
  /// In zh, this message translates to:
  /// **'代理'**
  String get settingsProxy;

  /// No description provided for @settingsProxySystem.
  ///
  /// In zh, this message translates to:
  /// **'系统代理'**
  String get settingsProxySystem;

  /// No description provided for @settingsProxyNone.
  ///
  /// In zh, this message translates to:
  /// **'不使用'**
  String get settingsProxyNone;

  /// No description provided for @settingsProxyManual.
  ///
  /// In zh, this message translates to:
  /// **'手动'**
  String get settingsProxyManual;

  /// No description provided for @settingsProxySystemDetected.
  ///
  /// In zh, this message translates to:
  /// **'当前系统代理：{endpoint}'**
  String settingsProxySystemDetected(String endpoint);

  /// No description provided for @settingsProxySystemEmpty.
  ///
  /// In zh, this message translates to:
  /// **'系统未设置代理，直接连接'**
  String get settingsProxySystemEmpty;

  /// No description provided for @settingsProxySystemAuto.
  ///
  /// In zh, this message translates to:
  /// **'系统使用自动代理配置（PAC / 自动检测）'**
  String get settingsProxySystemAuto;

  /// No description provided for @settingsProxyNoneSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'所有请求直接连接，不经过代理'**
  String get settingsProxyNoneSubtitle;

  /// No description provided for @settingsProxyManualSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'填写 HTTP 代理的地址与端口'**
  String get settingsProxyManualSubtitle;

  /// No description provided for @settingsProxyServer.
  ///
  /// In zh, this message translates to:
  /// **'代理服务器'**
  String get settingsProxyServer;

  /// No description provided for @settingsProxyHostHint.
  ///
  /// In zh, this message translates to:
  /// **'127.0.0.1'**
  String get settingsProxyHostHint;

  /// No description provided for @settingsProxyPortHint.
  ///
  /// In zh, this message translates to:
  /// **'端口'**
  String get settingsProxyPortHint;

  /// No description provided for @settingsProxyInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请填写有效的地址和 1–65535 之间的端口'**
  String get settingsProxyInvalid;

  /// No description provided for @settingsProxyAuth.
  ///
  /// In zh, this message translates to:
  /// **'代理认证（可选）'**
  String get settingsProxyAuth;

  /// No description provided for @settingsProxyUsernameHint.
  ///
  /// In zh, this message translates to:
  /// **'用户名'**
  String get settingsProxyUsernameHint;

  /// No description provided for @settingsProxyPasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get settingsProxyPasswordHint;

  /// No description provided for @settingsProxyUsernameInvalid.
  ///
  /// In zh, this message translates to:
  /// **'用户名不能包含冒号（:），冒号是用户名与密码的分隔符，代理会认证失败'**
  String get settingsProxyUsernameInvalid;

  /// No description provided for @settingsProxyAuthIncomplete.
  ///
  /// In zh, this message translates to:
  /// **'用户名和密码只填一项时，HTTPS 可用；HTTP 代理认证需要两项都填写'**
  String get settingsProxyAuthIncomplete;

  /// No description provided for @settingsProxyTest.
  ///
  /// In zh, this message translates to:
  /// **'测试连接'**
  String get settingsProxyTest;

  /// No description provided for @settingsProxyTesting.
  ///
  /// In zh, this message translates to:
  /// **'正在连接 Spotify…'**
  String get settingsProxyTesting;

  /// No description provided for @settingsProxyTestOk.
  ///
  /// In zh, this message translates to:
  /// **'连接正常，用时 {ms} 毫秒'**
  String settingsProxyTestOk(int ms);

  /// No description provided for @settingsProxyTestFailed.
  ///
  /// In zh, this message translates to:
  /// **'连接失败：{error}'**
  String settingsProxyTestFailed(String error);

  /// No description provided for @settingsProxyFootnote.
  ///
  /// In zh, this message translates to:
  /// **'仅支持 HTTP 代理（Clash、v2rayN 等的混合端口即可）；手动代理可填用户名 / 密码，适合自建带认证的跨区反代。登录页面始终跟随系统代理设置。'**
  String get settingsProxyFootnote;

  /// No description provided for @settingsPrivacySection.
  ///
  /// In zh, this message translates to:
  /// **'隐私'**
  String get settingsPrivacySection;

  /// No description provided for @settingsClearSearchHistory.
  ///
  /// In zh, this message translates to:
  /// **'清除搜索记录'**
  String get settingsClearSearchHistory;

  /// No description provided for @settingsSearchHistoryCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条记录'**
  String settingsSearchHistoryCount(int count);

  /// No description provided for @settingsSearchHistoryEmpty.
  ///
  /// In zh, this message translates to:
  /// **'没有搜索记录'**
  String get settingsSearchHistoryEmpty;

  /// No description provided for @settingsClearLyricsCache.
  ///
  /// In zh, this message translates to:
  /// **'清除歌词缓存'**
  String get settingsClearLyricsCache;

  /// No description provided for @settingsClearLyricsCacheSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'清除后重新从 Spotify 获取歌词'**
  String get settingsClearLyricsCacheSubtitle;

  /// No description provided for @settingsCleared.
  ///
  /// In zh, this message translates to:
  /// **'已清除'**
  String get settingsCleared;

  /// No description provided for @settingsAboutSection.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get settingsAboutSection;

  /// No description provided for @settingsVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本'**
  String get settingsVersion;

  /// No description provided for @settingsShortcuts.
  ///
  /// In zh, this message translates to:
  /// **'键盘快捷键'**
  String get settingsShortcuts;

  /// No description provided for @settingsLicenses.
  ///
  /// In zh, this message translates to:
  /// **'开源许可'**
  String get settingsLicenses;

  /// No description provided for @shortcutPlayPause.
  ///
  /// In zh, this message translates to:
  /// **'播放 / 暂停'**
  String get shortcutPlayPause;

  /// No description provided for @shortcutNext.
  ///
  /// In zh, this message translates to:
  /// **'下一首'**
  String get shortcutNext;

  /// No description provided for @shortcutPrevious.
  ///
  /// In zh, this message translates to:
  /// **'上一首'**
  String get shortcutPrevious;

  /// No description provided for @shortcutVolumeUp.
  ///
  /// In zh, this message translates to:
  /// **'调高音量'**
  String get shortcutVolumeUp;

  /// No description provided for @shortcutVolumeDown.
  ///
  /// In zh, this message translates to:
  /// **'调低音量'**
  String get shortcutVolumeDown;

  /// No description provided for @shortcutShuffle.
  ///
  /// In zh, this message translates to:
  /// **'随机播放'**
  String get shortcutShuffle;

  /// No description provided for @shortcutRepeat.
  ///
  /// In zh, this message translates to:
  /// **'切换循环模式'**
  String get shortcutRepeat;

  /// No description provided for @shortcutSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get shortcutSearch;

  /// No description provided for @shortcutBack.
  ///
  /// In zh, this message translates to:
  /// **'后退'**
  String get shortcutBack;

  /// No description provided for @shortcutForward.
  ///
  /// In zh, this message translates to:
  /// **'前进'**
  String get shortcutForward;

  /// No description provided for @shortcutImmersive.
  ///
  /// In zh, this message translates to:
  /// **'全屏歌词'**
  String get shortcutImmersive;

  /// No description provided for @shortcutImmersiveMode.
  ///
  /// In zh, this message translates to:
  /// **'全屏歌词中：切换铺满屏幕 / 窗口'**
  String get shortcutImmersiveMode;

  /// No description provided for @shortcutExitImmersive.
  ///
  /// In zh, this message translates to:
  /// **'退出全屏歌词'**
  String get shortcutExitImmersive;

  /// No description provided for @accountTitle.
  ///
  /// In zh, this message translates to:
  /// **'Spotify 账号'**
  String get accountTitle;

  /// No description provided for @accountSignedOutMessage.
  ///
  /// In zh, this message translates to:
  /// **'登录后同步你的音乐库'**
  String get accountSignedOutMessage;

  /// No description provided for @accountSignIn.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get accountSignIn;

  /// No description provided for @accountSignOut.
  ///
  /// In zh, this message translates to:
  /// **'退出登录'**
  String get accountSignOut;

  /// No description provided for @accountSignOutTitle.
  ///
  /// In zh, this message translates to:
  /// **'退出登录？'**
  String get accountSignOutTitle;

  /// No description provided for @accountSignOutMessage.
  ///
  /// In zh, this message translates to:
  /// **'将清除本机保存的登录信息与媒体库缓存，退出后需重新登录才能播放和查看媒体库。'**
  String get accountSignOutMessage;

  /// No description provided for @accountSignOutConfirm.
  ///
  /// In zh, this message translates to:
  /// **'退出'**
  String get accountSignOutConfirm;

  /// No description provided for @sleepTimer.
  ///
  /// In zh, this message translates to:
  /// **'睡眠定时器'**
  String get sleepTimer;

  /// No description provided for @sleepTimerMinutes.
  ///
  /// In zh, this message translates to:
  /// **'{count} 分钟'**
  String sleepTimerMinutes(int count);

  /// No description provided for @sleepTimerHour.
  ///
  /// In zh, this message translates to:
  /// **'1 小时'**
  String get sleepTimerHour;

  /// No description provided for @sleepTimerEndOfTrack.
  ///
  /// In zh, this message translates to:
  /// **'本首结束时'**
  String get sleepTimerEndOfTrack;

  /// No description provided for @sleepTimerOff.
  ///
  /// In zh, this message translates to:
  /// **'关闭定时器'**
  String get sleepTimerOff;

  /// No description provided for @sleepTimerRemaining.
  ///
  /// In zh, this message translates to:
  /// **'睡眠定时器：剩余 {time}'**
  String sleepTimerRemaining(String time);

  /// No description provided for @sleepTimerEndOfTrackActive.
  ///
  /// In zh, this message translates to:
  /// **'睡眠定时器：本首结束时暂停'**
  String get sleepTimerEndOfTrackActive;

  /// No description provided for @toastSleepTimerSet.
  ///
  /// In zh, this message translates to:
  /// **'睡眠定时器已设为「{label}」'**
  String toastSleepTimerSet(String label);

  /// No description provided for @toastSleepTimerOff.
  ///
  /// In zh, this message translates to:
  /// **'睡眠定时器已关闭'**
  String get toastSleepTimerOff;

  /// No description provided for @shortcutOnHoveredTrack.
  ///
  /// In zh, this message translates to:
  /// **'悬停曲目时：{action}'**
  String shortcutOnHoveredTrack(String action);

  /// No description provided for @trackColumnTitle.
  ///
  /// In zh, this message translates to:
  /// **'标题'**
  String get trackColumnTitle;

  /// No description provided for @trackColumnArtist.
  ///
  /// In zh, this message translates to:
  /// **'艺人'**
  String get trackColumnArtist;

  /// No description provided for @trackColumnAlbum.
  ///
  /// In zh, this message translates to:
  /// **'专辑'**
  String get trackColumnAlbum;

  /// No description provided for @trackColumnAddedAt.
  ///
  /// In zh, this message translates to:
  /// **'添加日期'**
  String get trackColumnAddedAt;

  /// No description provided for @trackColumnDuration.
  ///
  /// In zh, this message translates to:
  /// **'时长'**
  String get trackColumnDuration;

  /// No description provided for @trackSortBy.
  ///
  /// In zh, this message translates to:
  /// **'排序方式'**
  String get trackSortBy;

  /// No description provided for @trackSortCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义顺序'**
  String get trackSortCustom;

  /// No description provided for @trackViewAs.
  ///
  /// In zh, this message translates to:
  /// **'查看方式'**
  String get trackViewAs;

  /// No description provided for @trackViewList.
  ///
  /// In zh, this message translates to:
  /// **'列表'**
  String get trackViewList;

  /// No description provided for @trackViewCompact.
  ///
  /// In zh, this message translates to:
  /// **'紧凑'**
  String get trackViewCompact;

  /// No description provided for @trackSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'在歌单中搜索'**
  String get trackSearchHint;

  /// No description provided for @trackSearchClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭搜索'**
  String get trackSearchClose;

  /// No description provided for @trackSearchNoResults.
  ///
  /// In zh, this message translates to:
  /// **'找不到「{query}」'**
  String trackSearchNoResults(String query);

  /// No description provided for @addedToday.
  ///
  /// In zh, this message translates to:
  /// **'今天'**
  String get addedToday;

  /// No description provided for @addedDaysAgo.
  ///
  /// In zh, this message translates to:
  /// **'{count} 天前'**
  String addedDaysAgo(int count);

  /// No description provided for @addedWeeksAgo.
  ///
  /// In zh, this message translates to:
  /// **'{count} 周前'**
  String addedWeeksAgo(int count);

  /// No description provided for @settingsGateway.
  ///
  /// In zh, this message translates to:
  /// **'Spotify 反代'**
  String get settingsGateway;

  /// No description provided for @settingsGatewayDescription.
  ///
  /// In zh, this message translates to:
  /// **'通过自建服务器连接 Spotify API、媒体和 Connect。浏览器登录仍使用 Spotify 原站；保存后新连接生效。'**
  String get settingsGatewayDescription;

  /// No description provided for @settingsGatewayUrl.
  ///
  /// In zh, this message translates to:
  /// **'反代地址（包含路径）'**
  String get settingsGatewayUrl;

  /// No description provided for @settingsGatewayUser.
  ///
  /// In zh, this message translates to:
  /// **'反代用户名'**
  String get settingsGatewayUser;

  /// No description provided for @settingsGatewayPassword.
  ///
  /// In zh, this message translates to:
  /// **'反代密码'**
  String get settingsGatewayPassword;

  /// No description provided for @settingsGatewayInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请填写有效的 HTTPS 地址、单段路径及用户名和密码。'**
  String get settingsGatewayInvalid;

  /// No description provided for @settingsApply.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get settingsApply;

  /// No description provided for @settingsCacheLocation.
  ///
  /// In zh, this message translates to:
  /// **'缓存位置'**
  String get settingsCacheLocation;

  /// No description provided for @settingsAudioCacheLocation.
  ///
  /// In zh, this message translates to:
  /// **'音频缓存位置'**
  String get settingsAudioCacheLocation;

  /// No description provided for @settingsArtworkCacheLocation.
  ///
  /// In zh, this message translates to:
  /// **'封面缓存位置'**
  String get settingsArtworkCacheLocation;

  /// No description provided for @settingsLyricsCacheLocation.
  ///
  /// In zh, this message translates to:
  /// **'歌词缓存位置'**
  String get settingsLyricsCacheLocation;

  /// No description provided for @settingsCacheAppData.
  ///
  /// In zh, this message translates to:
  /// **'应用数据目录（AppData）'**
  String get settingsCacheAppData;

  /// No description provided for @settingsCacheApplication.
  ///
  /// In zh, this message translates to:
  /// **'安装 / 便携程序目录'**
  String get settingsCacheApplication;

  /// No description provided for @settingsCacheCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义目录'**
  String get settingsCacheCustom;

  /// No description provided for @settingsClearAllCache.
  ///
  /// In zh, this message translates to:
  /// **'清理所有缓存'**
  String get settingsClearAllCache;

  /// No description provided for @settingsClearAllCacheHelp.
  ///
  /// In zh, this message translates to:
  /// **'清理音频、封面、歌词和浏览器临时缓存，保留登录、设置、收藏和播放记录。正在播放或下载的音频会保留。'**
  String get settingsClearAllCacheHelp;

  /// No description provided for @settingsCacheLocationHelp.
  ///
  /// In zh, this message translates to:
  /// **'已有缓存会迁移到新位置，校验成功后删除旧文件。正在播放或下载的音频将在释放后继续迁移。自定义位置使用所选目录下的 FlutifyCache 文件夹。'**
  String get settingsCacheLocationHelp;

  /// No description provided for @settingsCacheMigrated.
  ///
  /// In zh, this message translates to:
  /// **'已迁移 {files} 个文件，{deferred} 个使用中，{failed} 个未成功'**
  String settingsCacheMigrated(int files, int deferred, int failed);

  /// No description provided for @settingsCacheCleared.
  ///
  /// In zh, this message translates to:
  /// **'已释放 {size}，{deferred} 个使用中，{failed} 个未成功'**
  String settingsCacheCleared(String size, int deferred, int failed);

  /// No description provided for @settingsCacheLocationInvalid.
  ///
  /// In zh, this message translates to:
  /// **'目录不可写或路径无效，请选择应用有权访问的本地目录。'**
  String get settingsCacheLocationInvalid;

  /// No description provided for @settingsCacheLocationSaved.
  ///
  /// In zh, this message translates to:
  /// **'缓存位置已更新'**
  String get settingsCacheLocationSaved;

  /// No description provided for @settingsCacheLocationHint.
  ///
  /// In zh, this message translates to:
  /// **'目录绝对路径'**
  String get settingsCacheLocationHint;

  /// No description provided for @settingsCacheChooseDirectory.
  ///
  /// In zh, this message translates to:
  /// **'选择文件夹'**
  String get settingsCacheChooseDirectory;

  /// No description provided for @settingsCachePickerFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法打开系统文件夹选择器，请重试或手动输入路径。'**
  String get settingsCachePickerFailed;

  /// No description provided for @settingsGatewayAutomatic.
  ///
  /// In zh, this message translates to:
  /// **'自动开关反代'**
  String get settingsGatewayAutomatic;

  /// No description provided for @settingsGatewayAutomaticHelp.
  ///
  /// In zh, this message translates to:
  /// **'启动、网络变化、回到应用及每 2 分钟通过 Cloudflare 查询出口国家/地区；遵循已选择的系统或手动代理。查询失败保留当前状态。'**
  String get settingsGatewayAutomaticHelp;

  /// No description provided for @settingsGatewayDirectCountries.
  ///
  /// In zh, this message translates to:
  /// **'允许直连的国家/地区代码'**
  String get settingsGatewayDirectCountries;

  /// No description provided for @settingsGatewayDirectCountriesHelp.
  ///
  /// In zh, this message translates to:
  /// **'可选，填写两位代码，以逗号或空格分隔。留空：CN 开启反代，其余直连；填写后：仅列表内国家/地区直连，其余开启反代。'**
  String get settingsGatewayDirectCountriesHelp;

  /// No description provided for @settingsGatewayCountriesInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入两位国家/地区代码，例如 US、JP、HK。'**
  String get settingsGatewayCountriesInvalid;

  /// No description provided for @settingsGatewayLookupFailed.
  ///
  /// In zh, this message translates to:
  /// **'国家/地区查询失败，已保留当前连接方式。'**
  String get settingsGatewayLookupFailed;

  /// No description provided for @settingsGatewayCountryPending.
  ///
  /// In zh, this message translates to:
  /// **'等待查询网络所在国家/地区，暂时保留当前连接方式。'**
  String get settingsGatewayCountryPending;

  /// No description provided for @settingsGatewayCountryStatus.
  ///
  /// In zh, this message translates to:
  /// **'网络所在国家/地区：{country} · {route}'**
  String settingsGatewayCountryStatus(String country, String route);

  /// No description provided for @settingsGatewayRouteProxy.
  ///
  /// In zh, this message translates to:
  /// **'反代已开启'**
  String get settingsGatewayRouteProxy;

  /// No description provided for @settingsGatewayRouteDirect.
  ///
  /// In zh, this message translates to:
  /// **'直连'**
  String get settingsGatewayRouteDirect;

  /// No description provided for @settingsGatewayRecheck.
  ///
  /// In zh, this message translates to:
  /// **'重新查询国家/地区'**
  String get settingsGatewayRecheck;

  /// No description provided for @lyricsTranslate.
  ///
  /// In zh, this message translates to:
  /// **'显示译词'**
  String get lyricsTranslate;

  /// No description provided for @lyricsCancelTranslation.
  ///
  /// In zh, this message translates to:
  /// **'取消译词'**
  String get lyricsCancelTranslation;

  /// No description provided for @lyricsTranslationFailed.
  ///
  /// In zh, this message translates to:
  /// **'译词查找失败，点击重试'**
  String get lyricsTranslationFailed;

  /// No description provided for @lyricsTranslating.
  ///
  /// In zh, this message translates to:
  /// **'正在查找译词 · 点击取消'**
  String get lyricsTranslating;

  /// No description provided for @settingsLyricsAutoTranslate.
  ///
  /// In zh, this message translates to:
  /// **'自动翻译歌词'**
  String get settingsLyricsAutoTranslate;

  /// No description provided for @settingsLyricsAutoTranslateSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'自动查找歌词源已有的译文。中文译词会按曲名、歌手查询网易云；启用 LRCLIB 补全时也会查找对照版。简繁体跟随界面。'**
  String get settingsLyricsAutoTranslateSubtitle;

  /// No description provided for @settingsLyricsExcludeInterface.
  ///
  /// In zh, this message translates to:
  /// **'不自动翻译界面语言'**
  String get settingsLyricsExcludeInterface;

  /// No description provided for @settingsLyricsExcluded.
  ///
  /// In zh, this message translates to:
  /// **'其他不自动翻译的语言'**
  String get settingsLyricsExcluded;

  /// No description provided for @settingsLyricsExcludedHint.
  ///
  /// In zh, this message translates to:
  /// **'用逗号分隔：en, ja, zh-Hans（简体）, zh-Hant（繁体）；zh 排除全部中文，留空清除'**
  String get settingsLyricsExcludedHint;

  /// No description provided for @settingsLyricsExcludedInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入语言代码，例如 en、ja、zh-Hans、zh-Hant'**
  String get settingsLyricsExcludedInvalid;

  /// No description provided for @settingsCanvas.
  ///
  /// In zh, this message translates to:
  /// **'Spotify Canvas 动态封面'**
  String get settingsCanvas;

  /// No description provided for @settingsCanvasSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'播放时显示官方短片；无 Canvas 或减少动态效果时显示静态封面。'**
  String get settingsCanvasSubtitle;

  /// No description provided for @settingsLanguageZhHant.
  ///
  /// In zh, this message translates to:
  /// **'繁體中文'**
  String get settingsLanguageZhHant;

  /// No description provided for @lyricsTranslationUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'暂无对应语言的译词'**
  String get lyricsTranslationUnavailable;

  /// No description provided for @settingsLanguageJa.
  ///
  /// In zh, this message translates to:
  /// **'日本語'**
  String get settingsLanguageJa;

  /// No description provided for @homeRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新首页'**
  String get homeRefresh;

  /// No description provided for @homeRefreshFailed.
  ///
  /// In zh, this message translates to:
  /// **'刷新失败，请检查网络后重试。'**
  String get homeRefreshFailed;

  /// No description provided for @loginTitle.
  ///
  /// In zh, this message translates to:
  /// **'登录 Spotify'**
  String get loginTitle;

  /// No description provided for @loginSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'在 Spotify 官方登录页登录一次，\n其余授权全部自动完成'**
  String get loginSubtitle;

  /// No description provided for @loginTermsNotice.
  ///
  /// In zh, this message translates to:
  /// **'以官方客户端身份登录不符合 Spotify 服务条款，建议使用小号。'**
  String get loginTermsNotice;

  /// No description provided for @loginPasswordPrivate.
  ///
  /// In zh, this message translates to:
  /// **'Flutify 不接触你的密码'**
  String get loginPasswordPrivate;

  /// No description provided for @loginOfficialPage.
  ///
  /// In zh, this message translates to:
  /// **'使用 Spotify 官方页面完成账号登录'**
  String get loginOfficialPage;

  /// No description provided for @loginRemoteDevices.
  ///
  /// In zh, this message translates to:
  /// **'登录后可遥控你的其他 Spotify 设备'**
  String get loginRemoteDevices;

  /// No description provided for @loginSignedInAs.
  ///
  /// In zh, this message translates to:
  /// **'已登录为 {name}'**
  String loginSignedInAs(String name);

  /// No description provided for @loginPlaybackReady.
  ///
  /// In zh, this message translates to:
  /// **'全曲播放已就绪'**
  String get loginPlaybackReady;

  /// No description provided for @loginBack.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get loginBack;

  /// No description provided for @loginFailed.
  ///
  /// In zh, this message translates to:
  /// **'登录失败'**
  String get loginFailed;

  /// No description provided for @webLoginTitle.
  ///
  /// In zh, this message translates to:
  /// **'全曲播放：Web 登录'**
  String get webLoginTitle;

  /// No description provided for @webLoginCardTitle.
  ///
  /// In zh, this message translates to:
  /// **'全曲播放（Web 登录）'**
  String get webLoginCardTitle;

  /// No description provided for @webLoginReady.
  ///
  /// In zh, this message translates to:
  /// **'已就绪，可以播放完整曲目'**
  String get webLoginReady;

  /// No description provided for @webLoginRequired.
  ///
  /// In zh, this message translates to:
  /// **'登录一次以解锁完整曲目播放'**
  String get webLoginRequired;

  /// No description provided for @webLoginConsentHint.
  ///
  /// In zh, this message translates to:
  /// **'如果页面在等你确认，请点「同意」完成授权；其余步骤已自动完成'**
  String get webLoginConsentHint;

  /// No description provided for @webLoginPreparing.
  ///
  /// In zh, this message translates to:
  /// **'正在获取播放凭据…'**
  String get webLoginPreparing;

  /// No description provided for @webLoginAuthorizing.
  ///
  /// In zh, this message translates to:
  /// **'正在完成账号授权…'**
  String get webLoginAuthorizing;

  /// No description provided for @webLoginFinishing.
  ///
  /// In zh, this message translates to:
  /// **'正在完成登录…'**
  String get webLoginFinishing;

  /// No description provided for @webLoginBackgroundHint.
  ///
  /// In zh, this message translates to:
  /// **'登录已完成，剩下的步骤在后台自动进行'**
  String get webLoginBackgroundHint;

  /// No description provided for @webLoginGoogleHint.
  ///
  /// In zh, this message translates to:
  /// **'用 Google 注册的账号：请在此处使用「邮箱 + 密码」登录；没有密码可先在 Spotify 官网「忘记密码」设置一个。'**
  String get webLoginGoogleHint;

  /// No description provided for @loginBrowserFallback.
  ///
  /// In zh, this message translates to:
  /// **'无法自动打开浏览器，登录链接已复制，请粘贴到浏览器中打开'**
  String get loginBrowserFallback;

  /// No description provided for @loginBrowserTitle.
  ///
  /// In zh, this message translates to:
  /// **'在浏览器中完成登录'**
  String get loginBrowserTitle;

  /// No description provided for @loginBrowserSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'登录并同意授权后，这里会自动继续'**
  String get loginBrowserSubtitle;

  /// No description provided for @loginReopen.
  ///
  /// In zh, this message translates to:
  /// **'重新打开'**
  String get loginReopen;

  /// No description provided for @loginLinkCopied.
  ///
  /// In zh, this message translates to:
  /// **'登录链接已复制'**
  String get loginLinkCopied;

  /// No description provided for @loginCopyLink.
  ///
  /// In zh, this message translates to:
  /// **'复制链接'**
  String get loginCopyLink;

  /// No description provided for @updatesTitle.
  ///
  /// In zh, this message translates to:
  /// **'软件更新'**
  String get updatesTitle;

  /// No description provided for @updatesMode.
  ///
  /// In zh, this message translates to:
  /// **'更新方式'**
  String get updatesMode;

  /// No description provided for @updatesManual.
  ///
  /// In zh, this message translates to:
  /// **'手动更新'**
  String get updatesManual;

  /// No description provided for @updatesAutomatic.
  ///
  /// In zh, this message translates to:
  /// **'自动下载更新'**
  String get updatesAutomatic;

  /// No description provided for @updatesDisabled.
  ///
  /// In zh, this message translates to:
  /// **'不检查更新'**
  String get updatesDisabled;

  /// No description provided for @updatesHint.
  ///
  /// In zh, this message translates to:
  /// **'自动检查新版本和更新内容。自动模式在后台下载，完成后由你确认安装，不会中断播放。'**
  String get updatesHint;

  /// No description provided for @updatesCheck.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get updatesCheck;

  /// No description provided for @updatesChecking.
  ///
  /// In zh, this message translates to:
  /// **'正在检查更新…'**
  String get updatesChecking;

  /// No description provided for @updatesCurrent.
  ///
  /// In zh, this message translates to:
  /// **'当前版本'**
  String get updatesCurrent;

  /// No description provided for @updatesUpToDate.
  ///
  /// In zh, this message translates to:
  /// **'已是最新版本'**
  String get updatesUpToDate;

  /// No description provided for @updatesAvailable.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本'**
  String get updatesAvailable;

  /// No description provided for @updatesNotes.
  ///
  /// In zh, this message translates to:
  /// **'更新内容'**
  String get updatesNotes;

  /// No description provided for @updatesNoNotes.
  ///
  /// In zh, this message translates to:
  /// **'此版本未提供更新说明。'**
  String get updatesNoNotes;

  /// No description provided for @updatesDownload.
  ///
  /// In zh, this message translates to:
  /// **'下载更新'**
  String get updatesDownload;

  /// No description provided for @updatesDownloading.
  ///
  /// In zh, this message translates to:
  /// **'正在下载并校验…'**
  String get updatesDownloading;

  /// No description provided for @updatesReady.
  ///
  /// In zh, this message translates to:
  /// **'更新已就绪'**
  String get updatesReady;

  /// No description provided for @updatesReadyHint.
  ///
  /// In zh, this message translates to:
  /// **'更新包已下载并通过校验。安装会关闭应用；也可以稍后从设置中继续。'**
  String get updatesReadyHint;

  /// No description provided for @updatesAndroidHint.
  ///
  /// In zh, this message translates to:
  /// **'APK 已下载并通过校验。确认后打开系统安装程序。'**
  String get updatesAndroidHint;

  /// No description provided for @updatesInstall.
  ///
  /// In zh, this message translates to:
  /// **'重启并安装'**
  String get updatesInstall;

  /// No description provided for @updatesInstallApk.
  ///
  /// In zh, this message translates to:
  /// **'安装 APK'**
  String get updatesInstallApk;

  /// No description provided for @updatesInstalling.
  ///
  /// In zh, this message translates to:
  /// **'正在准备安装…'**
  String get updatesInstalling;

  /// No description provided for @updatesSkip.
  ///
  /// In zh, this message translates to:
  /// **'跳过本次更新'**
  String get updatesSkip;

  /// No description provided for @updatesLater.
  ///
  /// In zh, this message translates to:
  /// **'稍后'**
  String get updatesLater;

  /// No description provided for @updatesPage.
  ///
  /// In zh, this message translates to:
  /// **'手动更新 · 发布页面'**
  String get updatesPage;

  /// No description provided for @updatesFailed.
  ///
  /// In zh, this message translates to:
  /// **'更新失败，请重试或前往发布页面。'**
  String get updatesFailed;

  /// No description provided for @updatesPermission.
  ///
  /// In zh, this message translates to:
  /// **'请允许 Flutify 安装未知来源应用，返回后再次点击「安装 APK」。'**
  String get updatesPermission;

  /// No description provided for @updatesUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'此平台暂不提供应用内安装，请通过发布页面手动更新。'**
  String get updatesUnsupported;

  /// No description provided for @updatesDetails.
  ///
  /// In zh, this message translates to:
  /// **'查看更新'**
  String get updatesDetails;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+script codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.scriptCode) {
          case 'Hant':
            return AppLocalizationsZhHant();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
