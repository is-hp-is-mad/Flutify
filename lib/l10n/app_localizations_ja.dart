// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String playbackRetryWaiting(int attempt, int total, int seconds) {
    return '接続できません。$seconds 秒後に再試行 $attempt/$total';
  }

  @override
  String playbackRetryRunning(int attempt, int total) {
    return '再接続中… 再試行 $attempt/$total';
  }

  @override
  String get appTitle => 'Flutify';

  @override
  String get shellBack => '戻る';

  @override
  String get shellForward => '進む';

  @override
  String get shellHome => 'ホーム';

  @override
  String get shellSearchShortcut => 'Ctrl K';

  @override
  String get shellAccountMenu => 'アカウント';

  @override
  String get shellCollapseLibrary => 'マイライブラリを折りたたむ';

  @override
  String get shellExpandLibrary => 'マイライブラリを展開';

  @override
  String get shellPlaybackStatus => '再生状況';

  @override
  String get shellHidePanel => '非表示';

  @override
  String get shellAboutArtist => 'アーティストについて';

  @override
  String shellMonthlyFollowers(String count) {
    return 'フォロワー $count 人';
  }

  @override
  String get shellSignInTitle => 'ログインしてマイライブラリを表示';

  @override
  String get shellSignInMessage => '保存したプレイリスト、アルバム、アーティストがここに表示されます。';

  @override
  String get shellSignIn => 'ログイン';

  @override
  String get windowMinimize => '最小化';

  @override
  String get windowMaximize => '最大化';

  @override
  String get windowRestore => '元のサイズに戻す';

  @override
  String get windowClose => '閉じる';

  @override
  String get menuPlayback => '再生';

  @override
  String get menuNavigate => '移動';

  @override
  String get menuEdit => '編集';

  @override
  String get menuUndo => '元に戻す';

  @override
  String get menuRedo => 'やり直す';

  @override
  String get menuCut => '切り取り';

  @override
  String get menuCopy => 'コピー';

  @override
  String get menuPaste => '貼り付け';

  @override
  String get menuSelectAll => 'すべて選択';

  @override
  String get menuWindow => 'ウインドウ';

  @override
  String get menuSettings => '設定…';

  @override
  String get commonCancel => 'キャンセル';

  @override
  String get commonCreate => '作成';

  @override
  String get commonDone => '完了';

  @override
  String get commonClose => '閉じる';

  @override
  String get commonClear => 'クリア';

  @override
  String get commonRemove => '削除';

  @override
  String get commonRetry => '再試行';

  @override
  String get commonLoadMore => 'さらに読み込む';

  @override
  String get commonMoreOptions => 'その他のオプション';

  @override
  String get commonShowAll => 'すべて表示';

  @override
  String get commonSeeMore => 'もっと見る';

  @override
  String get commonShowLess => '表示を減らす';

  @override
  String get commonSettings => '設定';

  @override
  String get commonShare => 'シェア';

  @override
  String subtitleJoin(String first, String second) {
    return '$first • $second';
  }

  @override
  String get navHome => 'ホーム';

  @override
  String get navSearch => '検索';

  @override
  String get navLibrary => 'マイライブラリ';

  @override
  String get typeTrack => '曲';

  @override
  String get typeArtist => 'アーティスト';

  @override
  String get typePlaylist => 'プレイリスト';

  @override
  String get typePodcast => 'ポッドキャスト';

  @override
  String podcastEpisodeCount(int count) {
    return '$count エピソード';
  }

  @override
  String get podcastPlayed => '再生済み';

  @override
  String podcastResumeFrom(String position) {
    return '$position まで再生';
  }

  @override
  String get podcastEmpty => 'エピソードはまだありません';

  @override
  String get podcastLoadFailed => '番組を読み込めませんでした。接続を確認して再試行してください';

  @override
  String get typeAlbum => 'アルバム';

  @override
  String get typeSingle => 'シングル';

  @override
  String get typeCompilation => 'コンピレーション';

  @override
  String get filterAll => 'すべて';

  @override
  String get filterMusic => '音楽';

  @override
  String get filterPodcasts => 'ポッドキャスト';

  @override
  String get filterSongs => '曲';

  @override
  String get filterArtists => 'アーティスト';

  @override
  String get filterPlaylists => 'プレイリスト';

  @override
  String get filterAlbums => 'アルバム';

  @override
  String songCount(int count) {
    return '$count 曲';
  }

  @override
  String followerCount(String count) {
    return 'フォロワー $count 人';
  }

  @override
  String durationHoursMinutes(int hours, int minutes) {
    return '$hours 時間 $minutes 分';
  }

  @override
  String durationMinutesSeconds(int minutes, int seconds) {
    return '$minutes 分 $seconds 秒';
  }

  @override
  String countAndDuration(String count, String duration) {
    return '$count、$duration';
  }

  @override
  String get greetingMorning => 'おはようございます';

  @override
  String get greetingAfternoon => 'こんにちは';

  @override
  String get greetingEvening => 'こんばんは';

  @override
  String get likedSongs => 'お気に入りの曲';

  @override
  String get likedSongsDescription => 'お気に入りの曲をまとめて楽しもう。';

  @override
  String get likeAdd => 'お気に入りの曲に追加';

  @override
  String get likeRemove => 'お気に入りの曲から削除';

  @override
  String get libraryAdd => 'マイライブラリに保存';

  @override
  String get libraryRemove => 'マイライブラリから削除';

  @override
  String get homeLoadFailedTitle => 'おすすめを読み込めませんでした';

  @override
  String get homeLoadFailedMessage => '接続を確認して再試行してください。';

  @override
  String get authSessionExpiredTitle => 'ログインの有効期限が切れました';

  @override
  String get authSessionExpiredMessage =>
      'すべてのデバイスからのログアウトやパスワード変更などにより、Spotify のログインが終了しました。もう一度ログインしてください。';

  @override
  String get authSignInAgain => '再ログイン';

  @override
  String get homeEmptyTitle => 'まだコンテンツがありません';

  @override
  String get homeEmptyMessage => '別のフィルターを試すか、しばらくしてから確認してください。';

  @override
  String get homeClearFilter => 'フィルターを解除';

  @override
  String get homePodcastUnsupported => 'ポッドキャストにはまだ対応していません';

  @override
  String get homeTypePodcast => 'ポッドキャスト';

  @override
  String get homeTypeEpisode => 'エピソード';

  @override
  String get searchHint => '何を聴きたいですか？';

  @override
  String get searchRecent => '最近の検索';

  @override
  String get searchClearAll => 'すべて削除';

  @override
  String get searchBrowseAll => 'すべてのジャンル';

  @override
  String get searchCategoriesFailedTitle => 'カテゴリーを読み込めませんでした';

  @override
  String get searchCategoriesFailedMessage => '接続を確認して再試行してください。';

  @override
  String get searchFailedTitle => '検索結果を読み込めませんでした';

  @override
  String get searchFailedMessage => '接続を確認して再試行してください。読み込み済みの結果は保持されます。';

  @override
  String searchNoResultsTitle(String query) {
    return '「$query」の検索結果はありません';
  }

  @override
  String get searchNoResultsMessage => '入力内容を確認するか、別のキーワードで検索してください。';

  @override
  String get searchFilterEmptyTitle => 'このカテゴリーには何もありません';

  @override
  String get searchFilterEmptyMessage => '別のフィルターを試してください。';

  @override
  String searchCategoryMix(String name) {
    return '$name ミックス';
  }

  @override
  String searchCategoryMixDescription(String name) {
    return '$name のおすすめを集めたミックス。';
  }

  @override
  String get librarySearchHint => 'マイライブラリを検索';

  @override
  String get libraryCloseSearch => '検索を閉じる';

  @override
  String get libraryCreatePlaylist => 'プレイリストを作成';

  @override
  String get libraryClearFilter => 'フィルターを解除';

  @override
  String get librarySortRecent => '最近追加した順';

  @override
  String get librarySortAlphabetical => '名前順';

  @override
  String get libraryListView => 'リスト表示';

  @override
  String get libraryGridView => 'グリッド表示';

  @override
  String get libraryEmptyTitle => 'まだコンテンツがありません';

  @override
  String get libraryEmptyMessage => '保存したプレイリスト、アーティスト、アルバムがここに表示されます。';

  @override
  String libraryNewPlaylistName(int number) {
    return 'マイプレイリスト #$number';
  }

  @override
  String get playlistDelete => 'プレイリストを削除';

  @override
  String get playlistLikedEmpty => 'お気に入りの曲がここに表示されます。\nハートアイコンを押して曲を保存しましょう。';

  @override
  String get playlistOwnEmpty =>
      'プレイリストに曲を追加しましょう。\n曲のメニューから「プレイリストに追加」を選んでください。';

  @override
  String get playlistEmpty => 'このプレイリストには曲がありません。';

  @override
  String get albumNoTracks => 'このアルバムには再生できる曲がありません。';

  @override
  String albumMoreBy(String name) {
    return '$name の他の作品';
  }

  @override
  String get artistPopular => '人気の曲';

  @override
  String get artistNoPopular => '人気の曲はまだありません。';

  @override
  String get artistNoAlbums => '表示できるアルバムはまだありません。';

  @override
  String get artistNoSongs => '表示できる曲はまだありません。';

  @override
  String get artistDiscography => 'ディスコグラフィー';

  @override
  String get artistFollow => 'フォロー';

  @override
  String get artistFollowing => 'フォロー中';

  @override
  String get playingFromPlaylist => 'プレイリストから再生中';

  @override
  String get playingFromAlbum => 'アルバムから再生中';

  @override
  String get playingFromArtist => 'アーティストから再生中';

  @override
  String get playingFromSearch => '検索結果から再生中';

  @override
  String get playingFromLibrary => 'マイライブラリから再生中';

  @override
  String get nowPlaying => '再生中';

  @override
  String get openNowPlaying => '再生画面を開く';

  @override
  String get playerNothingPlayingTitle => '再生していません';

  @override
  String get playerNothingPlayingMessage => '曲、アルバム、プレイリストを選んで再生しましょう。';

  @override
  String get playerIdleHint => '再生していません。聴きたい曲を選んでください';

  @override
  String get playerThisDevice => 'このデバイスで再生中';

  @override
  String get playerShuffleOn => 'シャッフルをオン';

  @override
  String get playerShuffleOff => 'シャッフルをオフ';

  @override
  String get playerRepeatOn => 'リピートをオン';

  @override
  String get playerRepeatOneOn => '1 曲リピートをオン';

  @override
  String get playerRepeatOff => 'リピートをオフ';

  @override
  String get playerNext => '次へ';

  @override
  String get playerPrevious => '前へ';

  @override
  String get playerMute => 'ミュート';

  @override
  String get playerUnmute => 'ミュートを解除';

  @override
  String get playerLyricsFullscreen => '歌詞を全画面表示';

  @override
  String get playerSwipeHint => 'アートワークをスワイプして曲を切り替え';

  @override
  String get playbackErrorSignIn => '音楽を再生するにはログインしてください';

  @override
  String get playbackErrorWebSignIn => '曲全体を再生するには Web ログインが必要です';

  @override
  String get webLoginAction => 'Web ログイン';

  @override
  String get webLoginSuccess => 'Web ログインが完了しました。曲全体を再生できます';

  @override
  String playbackErrorUnavailable(String track) {
    return '「$track」は現在再生できません';
  }

  @override
  String playbackErrorSkipped(String track) {
    return '「$track」は現在再生できないためスキップしました';
  }

  @override
  String playbackErrorNetwork(String track) {
    return '「$track」を読み込めませんでした。接続を確認してください';
  }

  @override
  String playbackErrorWidevine(String track) {
    return '「$track」を復号できません。このデバイスでは Widevine DRM を利用できません';
  }

  @override
  String playbackErrorFairPlay(String track) {
    return '「$track」を復号できません：このデバイスで FairPlay セッションを作成できませんでした';
  }

  @override
  String playbackErrorAutoPaused(int count) {
    return '$count 曲連続で再生できなかったため、一時停止しました';
  }

  @override
  String get detailSignInRequired => 'ログインしてコンテンツを表示';

  @override
  String get detailLoadFailed => '読み込めませんでした。接続を確認して再試行してください。';

  @override
  String get queueTitle => '再生キュー';

  @override
  String get queueNextInQueue => 'キュー内の次の曲';

  @override
  String get queueClear => 'キューをクリア';

  @override
  String get queueNextUp => '次に再生';

  @override
  String queueNextFrom(String name) {
    return '「$name」から次に再生';
  }

  @override
  String get queueEmpty => '次に再生する曲はありません';

  @override
  String get lyricsTitle => '歌詞';

  @override
  String get lyricsNotPlaying => '再生していません';

  @override
  String get lyricsNothingPlayingMessage => '曲を再生すると、ここに歌詞が表示されます。';

  @override
  String get lyricsUnavailableTitle => '歌詞がありません';

  @override
  String get lyricsUnavailableMessage => 'この曲の歌詞はまだありません。\n音楽をお楽しみください！';

  @override
  String get lyricsUnsynced => 'この歌詞は曲と同期していません。';

  @override
  String get lyricsFromLrclib => '歌詞の提供：LRCLIB';

  @override
  String get lyricsImmersive => '歌詞に集中';

  @override
  String get lyricsExpand => '歌詞を展開';

  @override
  String get lyricsCollapse => '歌詞を折りたたむ';

  @override
  String get lyricsExitImmersive => '歌詞表示を終了 (Esc)';

  @override
  String get lyricsFillScreen => '画面全体に表示 (F11)';

  @override
  String get lyricsFillWindow => 'ウィンドウ内に表示 (F11)';

  @override
  String get deviceConnectTitle => 'デバイスに接続';

  @override
  String get deviceConnectDescription =>
      'Spotify Connect で PC、スマートフォン、スマートスピーカーに再生を切り替えられます。';

  @override
  String get deviceCurrent => '現在の再生デバイス';

  @override
  String get deviceSpotifyConnect => 'Spotify Connect';

  @override
  String get connectThisDevice => 'このデバイス';

  @override
  String get connectTakeOver => 'このデバイスで再生を続ける';

  @override
  String connectPlayingOn(String device) {
    return '$device で再生中';
  }

  @override
  String get connectOtherDevices => '別のデバイスを選択';

  @override
  String get connectNoDevices => '他のデバイスが見つかりません';

  @override
  String get connectNoDevicesHint =>
      '同じアカウントでログインしたスマートフォン、パソコン、スピーカーで Spotify を開いてください';

  @override
  String get connectUnavailable =>
      '他のデバイスの Spotify を操作するには、デスクトップ方式でログインしてください';

  @override
  String get connectConnecting => 'Spotify Connect に接続中…';

  @override
  String get connectOffline => '接続が切れました。再接続中…';

  @override
  String get connectSameNetwork => '同じネットワーク';

  @override
  String get connectCommandFailed =>
      '操作できませんでした。無料アカウントでは、このリモート操作を利用できない場合があります';

  @override
  String connectVolumeUnsupported(String device) {
    return '$device はリモートでの音量調整に対応していません';
  }

  @override
  String get connectVolume => 'デバイスの音量';

  @override
  String get trackAddToPlaylist => 'プレイリストに追加';

  @override
  String get trackAddToQueue => '再生キューに追加';

  @override
  String get trackGoToAlbum => 'アルバムを表示';

  @override
  String get trackGoToRadio => 'ソングラジオを表示';

  @override
  String get trackViewCredits => 'クレジットを表示';

  @override
  String get creditsTitle => 'クレジット';

  @override
  String get creditsSources => '提供元';

  @override
  String get creditsEmpty => 'この曲のクレジットはありません';

  @override
  String get radioUnavailable => 'この曲のソングラジオはありません';

  @override
  String trackGoToArtist(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'アーティストを表示',
    );
    return '$_temp0';
  }

  @override
  String get trackNewPlaylist => '新しいプレイリスト';

  @override
  String get toastLikeAdded => 'お気に入りの曲に追加しました';

  @override
  String get toastLikeRemoved => 'お気に入りの曲から削除しました';

  @override
  String get toastAddedToQueue => '再生キューに追加しました';

  @override
  String get shareCopyLink => 'リンクをコピー';

  @override
  String get shareCopyUri => 'URI をコピー';

  @override
  String get shareOpenWeb => 'ブラウザーで開く';

  @override
  String get shareCopied => 'コピーしました';

  @override
  String get shareEmbedTitle => '埋め込み';

  @override
  String get shareEmbedSubtitle => 'ページの HTML に貼り付けて Spotify プレーヤーを表示';

  @override
  String get shareEmbedStandard => '標準';

  @override
  String get shareEmbedCompact => 'コンパクト';

  @override
  String get shareEmbedDark => 'ダーク';

  @override
  String get shareEmbedCopy => 'コードをコピー';

  @override
  String get shareEmbedUnavailable =>
      'システムの WebView を利用できません。下の埋め込みコードはコピーできます。';

  @override
  String get shareEmbedFailed => 'Spotify の埋め込みを読み込めませんでした。接続を確認して再試行してください。';

  @override
  String toastAddedTo(String name) {
    return '$name に追加しました';
  }

  @override
  String toastAlreadyIn(String name) {
    return '$name に追加済みです';
  }

  @override
  String get createPlaylistTitle => 'プレイリストに名前を付ける';

  @override
  String get createPlaylistHint => 'プレイリスト名';

  @override
  String get createPlaylistDefaultName => 'マイプレイリスト';

  @override
  String get settingsAppearanceSection => '外観';

  @override
  String get settingsThemeMode => 'テーマ';

  @override
  String get settingsThemeSystem => 'システム';

  @override
  String get settingsThemeLight => 'ライト';

  @override
  String get settingsThemeDark => 'ダーク';

  @override
  String get settingsPureBlack => 'ピュアブラック';

  @override
  String get settingsPureBlackSubtitle => 'ダークモードで背景を完全な黒にして、OLED 画面の消費電力を抑えます';

  @override
  String get settingsAccentSection => 'アクセントカラー';

  @override
  String get settingsAccentCustom => 'カスタムカラー';

  @override
  String get settingsDynamicAccent => 'アルバムアートに合わせる';

  @override
  String get settingsDynamicAccentSubtitle => '再生中のアートワークに合わせてアクセントカラーを変更します';

  @override
  String get settingsGlassSection => 'リキッドガラス';

  @override
  String get settingsGlassPreview => 'ガラス効果のプレビュー';

  @override
  String get settingsGlassBlur => 'ぼかし';

  @override
  String get settingsGlassOpacity => '不透明度';

  @override
  String get settingsTextShapeSection => '文字と形';

  @override
  String get settingsFontScale => '文字サイズ';

  @override
  String get settingsFontPreview => '夜空でいちばん明るい星';

  @override
  String get settingsCornerStyle => '角の形';

  @override
  String get settingsCornerRounded => '丸める';

  @override
  String get settingsCornerStandard => '標準';

  @override
  String get settingsCornerSquare => '四角';

  @override
  String get settingsPlaybackSection => '再生';

  @override
  String get settingsPauseAfterFailures => '再生に失敗し続けたら一時停止';

  @override
  String settingsPauseAfterFailuresSubtitle(int count) {
    return '$count 曲連続で再生できなかったら、自動スキップを停止します';
  }

  @override
  String get settingsMotionSection => 'アニメーション';

  @override
  String get settingsReduceMotion => '動きを減らす';

  @override
  String get settingsReduceMotionSubtitle => '動く背景、画面切り替え、ホバー時のアニメーションを無効にします';

  @override
  String get settingsPowerSaving => '省電力モード';

  @override
  String get settingsPowerSavingSubtitle =>
      'ガラスをすりガラス風の塗りに切り替え、歌詞画面の背景を静止します。歌詞のスクロールと演出はそのまま';

  @override
  String get settingsFrameRate => 'フレームレート上限';

  @override
  String get settingsFrameRateSubtitle =>
      '下げると GPU 使用率が大きく減ります。アニメーションの速さは変わりません';

  @override
  String get settingsFrameRateFollow => '画面に合わせる';

  @override
  String get settingsFrameRateCustom => 'カスタム';

  @override
  String settingsFrameRateValue(int fps) {
    return '$fps fps';
  }

  @override
  String get settingsResetAppearance => '外観をリセット';

  @override
  String get settingsCustomColorTitle => 'カスタムアクセントカラー';

  @override
  String get settingsHue => '色相';

  @override
  String get settingsSaturation => '彩度';

  @override
  String get settingsBrightness => '明るさ';

  @override
  String get settingsLanguageSection => '言語';

  @override
  String get settingsLanguage => 'アプリの言語';

  @override
  String get settingsLanguageSubtitle => 'ホームの見出しなど、Spotify から取得するテキストも変更します';

  @override
  String get settingsLanguageSystem => 'システム';

  @override
  String get settingsLanguageZh => '简体中文';

  @override
  String get settingsLanguageEn => 'English';

  @override
  String get settingsStorageSection => 'ストレージ';

  @override
  String get settingsAudioCache => '音声キャッシュ';

  @override
  String settingsAudioCacheUsage(String used, String limit) {
    return '$limit 中 $used 使用中';
  }

  @override
  String get settingsAudioCacheCalculating => '計算中…';

  @override
  String get settingsAudioCacheLimit => 'キャッシュの上限';

  @override
  String get settingsAudioCacheLimitSubtitle => '最後の再生から最も時間が経った曲から削除します';

  @override
  String get settingsClearAudioCache => '音声キャッシュを削除';

  @override
  String get settingsClearAudioCacheTitle => '音声キャッシュを削除しますか？';

  @override
  String get settingsClearAudioCacheMessage =>
      'ダウンロード済みの曲を削除し、再生時に再ダウンロードします。再生中の曲は保持します。';

  @override
  String settingsAudioCacheCleared(String size) {
    return '$size を解放しました';
  }

  @override
  String get settingsLyricsSection => '歌詞';

  @override
  String get settingsLyricsFocusPosition => '現在の歌詞行の位置';

  @override
  String get settingsLyricsFocusPositionSubtitle =>
      '表示領域内で現在の歌詞行の位置を調整します。値を大きくすると下に移動します。';

  @override
  String get lyricsTranslationFromNetease => '訳詞提供：NetEase Music コミュニティ';

  @override
  String get settingsLyricsSize => '歌詞の文字サイズ';

  @override
  String get settingsLyricsAlign => '配置';

  @override
  String get settingsLyricsAlignLeft => '左揃え';

  @override
  String get settingsLyricsAlignCenter => '中央揃え';

  @override
  String get settingsLyricsBlur => '他の行をぼかす';

  @override
  String get settingsLyricsImmersiveScreen => '全画面歌詞を画面いっぱいに表示';

  @override
  String get settingsLyricsImmersiveScreenSubtitle =>
      'オフの場合はウィンドウ内に表示します。全画面歌詞で F11 を押すと切り替えられます';

  @override
  String get settingsLyricsFallback => '見つからない歌詞を補完';

  @override
  String get settingsLyricsFallbackSubtitle =>
      'Spotify に同期歌詞がない場合、公開ライブラリ LRCLIB から曲の原語の歌詞を取得します';

  @override
  String get settingsLyricsBilingual => 'コミュニティの歌詞翻訳';

  @override
  String get settingsLyricsBilingualSubtitle =>
      '歌詞の読み込み時に中国語の訳詞を取得し、タスクバー歌詞にも使用します。オフでも翻訳ボタンや自動翻訳で検索できます。検索時は曲名とアーティスト名を NetEase Music に送信します。';

  @override
  String get settingsTaskbarLyricsSection => 'タスクバー歌詞';

  @override
  String get settingsTaskbarLyrics => 'タスクバーに歌詞を表示';

  @override
  String get settingsTaskbarLyricsSubtitle =>
      'アイコンが中央揃えの場合は左端、左揃えの場合は通知領域の左に表示します。縦型タスクバーでは停止します。ホバーで再生操作、クリックで Flutify を開き、右クリックで歌詞を再読み込みできます';

  @override
  String get settingsTaskbarLyricsColor => '文字色';

  @override
  String get settingsTaskbarLyricsCustomColor => 'カスタムカラー';

  @override
  String get settingsTaskbarLyricsChangeColor => '変更';

  @override
  String get settingsTaskbarLyricsOpacity => '不透明度';

  @override
  String get settingsTaskbarLyricsFontSize => '文字サイズ';

  @override
  String get settingsCopyLog => '診断ログをコピー';

  @override
  String get settingsCopyLogSubtitle =>
      '問題の報告時に貼り付けてください。実行記録が含まれますが、パスワードは含まれません';

  @override
  String get settingsCopyLogDone => 'ログをクリップボードにコピーしました';

  @override
  String get settingsCopyLogEmpty => 'ログはまだありません';

  @override
  String get taskbarLyricsColorAuto => '自動';

  @override
  String get taskbarLyricsColorWhite => '白';

  @override
  String get taskbarLyricsColorBlack => '黒';

  @override
  String get taskbarLyricsColorAccent => 'アクセント';

  @override
  String get taskbarLyricsColorCustom => 'カスタム';

  @override
  String get taskbarLyricsMenuOpen => 'Flutify を開く';

  @override
  String get taskbarLyricsMenuRefetch => '歌詞を再読み込み';

  @override
  String get taskbarLyricsMenuDisable => 'タスクバー歌詞をオフ';

  @override
  String get taskbarLyricsPreviewLine1 => '曲に合わせてここに歌詞が流れます';

  @override
  String get taskbarLyricsPreviewLine2 => 'ホバーしてスキップや一時停止';

  @override
  String get taskbarLyricsPreviewLine3 => '色と不透明度はすぐに反映されます';

  @override
  String get settingsOff => 'オフ';

  @override
  String get settingsNormalize => '音量を均一にする';

  @override
  String get settingsNormalizeSubtitle => 'Spotify の音量データを使い、大きな音の曲の音量を下げて揃えます';

  @override
  String get settingsFade => '曲間のフェード';

  @override
  String get settingsFadeSubtitle => '曲の終わりにフェードアウトし、次の曲をフェードインします';

  @override
  String settingsSeconds(int count) {
    return '$count 秒';
  }

  @override
  String get settingsStartupSection => '起動';

  @override
  String get settingsStartPage => '起動時に開くページ';

  @override
  String get settingsStartPageHome => 'ホーム';

  @override
  String get settingsStartPageLibrary => 'ライブラリ';

  @override
  String get settingsStartPageLast => '前回のページ';

  @override
  String get settingsRememberWindow => 'ウィンドウのサイズと位置を記憶';

  @override
  String get settingsRememberWindowSubtitle =>
      '次回起動時に復元します。前回の画面がない場合は中央に表示します';

  @override
  String get settingsConnectSection => 'Spotify Connect';

  @override
  String get settingsConnectEnabled => 'Spotify Connect を有効にする';

  @override
  String get settingsConnectEnabledSubtitle => '他のデバイスの再生を表示・操作します';

  @override
  String get settingsConnectDeviceName => 'デバイス名';

  @override
  String get settingsConnectDeviceNameSubtitle =>
      '他のデバイスの一覧に表示する Flutify の名前です。空欄の場合は既定の名前を使います';

  @override
  String get settingsConnectUseDeviceName => 'デバイス名を使う';

  @override
  String get settingsConnectReportOnLaunch => '起動時に再生情報を同期';

  @override
  String get settingsConnectReportOnLaunchSubtitle =>
      '再生前でも、起動すると他のデバイスに現在の曲を表示します（待機中のセッションを引き継ぎます）';

  @override
  String get settingsRemoteLyricsLead => 'リモート歌詞の先行時間';

  @override
  String get settingsRemoteLyricsLeadSubtitle =>
      '他のデバイスで再生中、歌詞が歌より遅れる場合は増やし、先行する場合は減らしてください';

  @override
  String get settingsNetworkSection => 'ネットワーク';

  @override
  String get settingsProxy => 'プロキシ';

  @override
  String get settingsProxySystem => 'システム';

  @override
  String get settingsProxyNone => 'なし';

  @override
  String get settingsProxyManual => '手動';

  @override
  String settingsProxySystemDetected(String endpoint) {
    return 'システムプロキシ：$endpoint';
  }

  @override
  String get settingsProxySystemEmpty => 'システムプロキシは未設定です。直接接続します';

  @override
  String get settingsProxySystemAuto => 'システムは自動プロキシ構成（PAC / 自動検出）を使用しています';

  @override
  String get settingsProxyNoneSubtitle => 'プロキシを使わず、すべてのリクエストを直接接続します';

  @override
  String get settingsProxyManualSubtitle => 'HTTP プロキシのアドレスとポートを入力してください';

  @override
  String get settingsProxyServer => 'プロキシサーバー';

  @override
  String get settingsProxyHostHint => '127.0.0.1';

  @override
  String get settingsProxyPortHint => 'ポート';

  @override
  String get settingsProxyInvalid => '有効なアドレスと 1～65535 のポートを入力してください';

  @override
  String get settingsProxyAuth => 'プロキシ認証（任意）';

  @override
  String get settingsProxyUsernameHint => 'ユーザー名';

  @override
  String get settingsProxyPasswordHint => 'パスワード';

  @override
  String get settingsProxyUsernameInvalid =>
      'ユーザー名にコロン（:）は使用できません。ユーザー名とパスワードの区切り文字として扱われるため、認証に失敗します';

  @override
  String get settingsProxyAuthIncomplete =>
      'HTTPS では片方だけでも使用できます。HTTP プロキシ認証には両方の入力が必要です';

  @override
  String get settingsProxyTest => '接続をテスト';

  @override
  String get settingsProxyTesting => 'Spotify に接続中…';

  @override
  String settingsProxyTestOk(int ms) {
    return '$ms ms で接続しました';
  }

  @override
  String settingsProxyTestFailed(String error) {
    return '接続に失敗しました：$error';
  }

  @override
  String get settingsProxyFootnote =>
      'HTTP プロキシに対応しています（Clash、v2rayN などの mixed ポートも利用可能）。ログインページは常にシステムのプロキシ設定に従います。';

  @override
  String get settingsPrivacySection => 'プライバシー';

  @override
  String get settingsClearSearchHistory => '検索履歴を削除';

  @override
  String settingsSearchHistoryCount(int count) {
    return '検索履歴 $count 件';
  }

  @override
  String get settingsSearchHistoryEmpty => '検索履歴はありません';

  @override
  String get settingsClearLyricsCache => '歌詞キャッシュを削除';

  @override
  String get settingsClearLyricsCacheSubtitle => '歌詞を Spotify から再取得します';

  @override
  String get settingsCleared => '削除しました';

  @override
  String get settingsAboutSection => 'アプリについて';

  @override
  String get settingsVersion => 'バージョン';

  @override
  String get settingsShortcuts => 'キーボードショートカット';

  @override
  String get settingsLicenses => 'オープンソースライセンス';

  @override
  String get shortcutPlayPause => '再生 / 一時停止';

  @override
  String get shortcutNext => '次の曲';

  @override
  String get shortcutPrevious => '前の曲';

  @override
  String get shortcutVolumeUp => '音量を上げる';

  @override
  String get shortcutVolumeDown => '音量を下げる';

  @override
  String get shortcutShuffle => 'シャッフル';

  @override
  String get shortcutRepeat => 'リピートモードを変更';

  @override
  String get shortcutSearch => '検索';

  @override
  String get shortcutBack => '戻る';

  @override
  String get shortcutForward => '進む';

  @override
  String get shortcutImmersive => '歌詞を全画面表示';

  @override
  String get shortcutImmersiveMode => '全画面歌詞：画面 / ウィンドウを切り替え';

  @override
  String get shortcutExitImmersive => '全画面歌詞を終了';

  @override
  String get accountTitle => 'Spotify アカウント';

  @override
  String get accountSignedOutMessage => 'ログインしてマイライブラリを同期';

  @override
  String get accountSignIn => 'ログイン';

  @override
  String get accountSignOut => 'ログアウト';

  @override
  String get accountSignOutTitle => 'ログアウトしますか？';

  @override
  String get accountSignOutMessage =>
      'このデバイスのログイン情報とライブラリのキャッシュを削除します。音楽の再生やマイライブラリの表示には再ログインが必要です。';

  @override
  String get accountSignOutConfirm => 'ログアウト';

  @override
  String get sleepTimer => 'スリープタイマー';

  @override
  String sleepTimerMinutes(int count) {
    return '$count 分';
  }

  @override
  String get sleepTimerHour => '1 時間';

  @override
  String get sleepTimerEndOfTrack => '曲の終わりまで';

  @override
  String get sleepTimerOff => 'タイマーをオフ';

  @override
  String sleepTimerRemaining(String time) {
    return 'スリープタイマー：残り $time';
  }

  @override
  String get sleepTimerEndOfTrackActive => 'スリープタイマー：曲の終わりで一時停止';

  @override
  String toastSleepTimerSet(String label) {
    return 'スリープタイマーを設定しました：$label';
  }

  @override
  String get toastSleepTimerOff => 'スリープタイマーをオフにしました';

  @override
  String shortcutOnHoveredTrack(String action) {
    return 'ホバー中の曲：$action';
  }

  @override
  String get trackColumnTitle => 'タイトル';

  @override
  String get trackColumnArtist => 'アーティスト';

  @override
  String get trackColumnAlbum => 'アルバム';

  @override
  String get trackColumnAddedAt => '追加日';

  @override
  String get trackColumnDuration => '再生時間';

  @override
  String get trackSortBy => '並べ替え';

  @override
  String get trackSortCustom => 'カスタム順';

  @override
  String get trackViewAs => '表示形式';

  @override
  String get trackViewList => 'リスト';

  @override
  String get trackViewCompact => 'コンパクト';

  @override
  String get trackSearchHint => 'プレイリスト内を検索';

  @override
  String get trackSearchClose => '検索を閉じる';

  @override
  String trackSearchNoResults(String query) {
    return '「$query」が見つかりませんでした';
  }

  @override
  String get addedToday => '今日';

  @override
  String addedDaysAgo(int count) {
    return '$count 日前';
  }

  @override
  String addedWeeksAgo(int count) {
    return '$count 週間前';
  }

  @override
  String get settingsGateway => 'Spotify ゲートウェイ';

  @override
  String get settingsGatewayDescription =>
      '自分のサーバー経由で Spotify の API、メディア、Connect に接続します。ブラウザーでのログインは Spotify に直接接続します。保存後の新しい接続から適用されます。';

  @override
  String get settingsGatewayUrl => 'ゲートウェイ URL（パスを含む）';

  @override
  String get settingsGatewayUser => 'ゲートウェイのユーザー名';

  @override
  String get settingsGatewayPassword => 'ゲートウェイのパスワード';

  @override
  String get settingsGatewayInvalid =>
      'パスが 1 階層の有効な HTTPS URL、ユーザー名、パスワードを入力してください。';

  @override
  String get settingsApply => '保存';

  @override
  String get settingsCacheLocation => 'キャッシュの保存先';

  @override
  String get settingsAudioCacheLocation => '音声キャッシュの保存先';

  @override
  String get settingsArtworkCacheLocation => 'アートワークキャッシュの保存先';

  @override
  String get settingsLyricsCacheLocation => '歌詞キャッシュの保存先';

  @override
  String get settingsCacheAppData => 'アプリデータ (AppData)';

  @override
  String get settingsCacheApplication => 'インストール先 / ポータブルアプリのフォルダー';

  @override
  String get settingsCacheCustom => 'カスタムフォルダー';

  @override
  String get settingsClearAllCache => 'すべてのキャッシュを削除';

  @override
  String get settingsClearAllCacheHelp =>
      '音声、アートワーク、歌詞、ブラウザーの一時キャッシュを削除します。ログイン、設定、ライブラリ、再生履歴と、使用中・ダウンロード中の音声は保持します。';

  @override
  String get settingsCacheLocationHelp =>
      '既存のキャッシュを移動し、検証後に元のファイルを削除します。使用中・ダウンロード中の音声は解放後に移動します。カスタム保存先では、選択したフォルダー内に FlutifyCache を作成します。';

  @override
  String settingsCacheMigrated(int files, int deferred, int failed) {
    return '$files ファイルを移動、$deferred 件使用中、$failed 件失敗';
  }

  @override
  String settingsCacheCleared(String size, int deferred, int failed) {
    return '$size を解放、$deferred 件使用中、$failed 件失敗';
  }

  @override
  String get settingsCacheLocationInvalid =>
      '書き込みできないか、パスが無効です。アプリがアクセスできるローカルフォルダーを選んでください。';

  @override
  String get settingsCacheLocationSaved => 'キャッシュの保存先を更新しました';

  @override
  String get settingsCacheLocationHint => 'フォルダーの絶対パス';

  @override
  String get settingsCacheChooseDirectory => 'フォルダーを選択';

  @override
  String get settingsCachePickerFailed =>
      'フォルダー選択を開けませんでした。再試行するか、パスを入力してください。';

  @override
  String get settingsGatewayAutomatic => 'ゲートウェイを自動切り替え';

  @override
  String get settingsGatewayAutomaticHelp =>
      '起動時、ネットワーク変更時、復帰時、および 2 分ごとに Cloudflare で接続元の国・地域を確認します。選択したシステム / 手動プロキシを使います。確認に失敗した場合は現在の経路を保持します。';

  @override
  String get settingsGatewayDirectCountries => '直接接続を許可する国・地域';

  @override
  String get settingsGatewayDirectCountriesHelp =>
      '2 文字のコードをカンマかスペースで区切って指定します。空欄の場合は CN のみゲートウェイ経由で、それ以外は直接接続します。指定した場合は一覧内のみ直接接続し、それ以外はゲートウェイ経由になります。';

  @override
  String get settingsGatewayCountriesInvalid =>
      'US、JP、HK などの 2 文字の国・地域コードを入力してください。';

  @override
  String get settingsGatewayLookupFailed => '国・地域を確認できませんでした。現在の経路を保持します。';

  @override
  String get settingsGatewayCountryPending => 'ネットワークの国・地域を確認中です。現在の経路を保持します。';

  @override
  String settingsGatewayCountryStatus(String country, String route) {
    return 'ネットワークの国・地域：$country · $route';
  }

  @override
  String get settingsGatewayRouteProxy => 'ゲートウェイ経由';

  @override
  String get settingsGatewayRouteDirect => '直接接続';

  @override
  String get settingsGatewayRecheck => '国・地域を再確認';

  @override
  String get lyricsTranslate => '訳詞を表示';

  @override
  String get lyricsCancelTranslation => '訳詞を非表示';

  @override
  String get lyricsTranslationFailed => '訳詞を検索できませんでした。タップして再試行';

  @override
  String get lyricsTranslating => '訳詞を検索中 · タップしてキャンセル';

  @override
  String get settingsLyricsAutoTranslate => '訳詞を自動表示';

  @override
  String get settingsLyricsAutoTranslateSubtitle =>
      '歌詞ソースにある訳詞を検索します。中国語の訳詞は曲名とアーティスト名で NetEase を検索し、LRCLIB 補完が有効な場合は対訳版も検索します。簡体字・繁体字は表示言語に従います。';

  @override
  String get settingsLyricsExcludeInterface => 'アプリと同じ言語の曲は除外';

  @override
  String get settingsLyricsExcluded => '他に除外する言語';

  @override
  String get settingsLyricsExcludedHint =>
      'カンマ区切り：en、ja、zh-Hans（簡体字）、zh-Hant（繁体字）。zh は両方を除外します。空欄で解除します。';

  @override
  String get settingsLyricsExcludedInvalid =>
      'en、ja、zh-Hans、zh-Hant などの言語コードを入力してください';

  @override
  String get settingsCanvas => 'Spotify Canvas';

  @override
  String get settingsCanvasSubtitle =>
      '再生中に公式のループ動画を表示します。利用できない場合や「動きを減らす」が有効な場合は静止画を表示します。';

  @override
  String get settingsLanguageZhHant => '繁體中文';

  @override
  String get lyricsTranslationUnavailable => 'この言語の訳詞はありません';

  @override
  String get settingsLanguageJa => '日本語';

  @override
  String get homeRefresh => 'ホームを更新';

  @override
  String get homeRefreshFailed => '更新できませんでした。接続を確認して再試行してください。';

  @override
  String get loginTitle => 'Spotify にログイン';

  @override
  String get loginSubtitle => 'Spotify の公式ページで一度ログインすると、\n残りの認証は自動的に完了します';

  @override
  String get loginTermsNotice =>
      '公式クライアントとしてのログインは Spotify の利用規約に適合しません。サブアカウントの使用をおすすめします。';

  @override
  String get loginPasswordPrivate => 'Flutify はパスワードにアクセスしません';

  @override
  String get loginOfficialPage => 'Spotify の公式ページでログインします';

  @override
  String get loginRemoteDevices => 'ログイン後は他の Spotify デバイスを操作できます';

  @override
  String loginSignedInAs(String name) {
    return '$name としてログインしました';
  }

  @override
  String get loginPlaybackReady => 'フル再生の準備ができました';

  @override
  String get loginBack => '戻る';

  @override
  String get loginFailed => 'ログインに失敗しました';

  @override
  String get webLoginTitle => 'フル再生：Web ログイン';

  @override
  String get webLoginCardTitle => 'フル再生（Web ログイン）';

  @override
  String get webLoginReady => '楽曲をフル再生できます';

  @override
  String get webLoginRequired => 'ログインすると楽曲をフル再生できます';

  @override
  String get webLoginConsentHint =>
      '確認画面が表示された場合は「同意する」を押して認証を完了してください。他の手順は自動的に完了しています。';

  @override
  String get webLoginPreparing => '再生用の認証情報を取得しています…';

  @override
  String get webLoginAuthorizing => 'アカウントの認証を完了しています…';

  @override
  String get webLoginFinishing => 'ログインを完了しています…';

  @override
  String get webLoginBackgroundHint => 'ログインが完了しました。残りの手順は自動的に実行されます。';

  @override
  String get webLoginGoogleHint =>
      'Google で登録した場合は、ここでメールアドレスとパスワードを使ってログインしてください。パスワードがない場合は、Spotify 公式サイトの「パスワードを忘れた場合」から設定できます。';

  @override
  String get loginBrowserFallback =>
      'ブラウザーを開けませんでした。コピーしたログインリンクをブラウザーに貼り付けてください。';

  @override
  String get loginBrowserTitle => 'ブラウザーでログインを完了してください';

  @override
  String get loginBrowserSubtitle => 'ログインしてアクセスを許可すると、自動的に続行します。';

  @override
  String get loginReopen => 'もう一度開く';

  @override
  String get loginLinkCopied => 'ログインリンクをコピーしました';

  @override
  String get loginCopyLink => 'リンクをコピー';

  @override
  String get updatesTitle => 'ソフトウェア更新';

  @override
  String get updatesMode => '更新方法';

  @override
  String get updatesManual => '手動更新';

  @override
  String get updatesAutomatic => '自動ダウンロード';

  @override
  String get updatesDisabled => '更新を確認しない';

  @override
  String get updatesHint =>
      '新しいバージョンと更新内容を自動確認します。自動モードはバックグラウンドでダウンロードし、再生を中断せず、確認後にインストールします。';

  @override
  String get updatesCheck => '更新を確認';

  @override
  String get updatesChecking => '更新を確認中…';

  @override
  String get updatesCurrent => '現在のバージョン';

  @override
  String get updatesUpToDate => '最新バージョンです';

  @override
  String get updatesAvailable => '新しいバージョン';

  @override
  String get updatesNotes => '更新内容';

  @override
  String get updatesNoNotes => '更新内容は公開されていません。';

  @override
  String get updatesDownload => '更新をダウンロード';

  @override
  String get updatesDownloading => 'ダウンロード・検証中…';

  @override
  String get updatesReady => '更新の準備ができました';

  @override
  String get updatesReadyHint =>
      'ダウンロードと検証が完了しました。インストール時にアプリを終了します。設定から後で続行することもできます。';

  @override
  String get updatesAndroidHint =>
      'APK のダウンロードと検証が完了しました。確認するとシステムのインストーラーを開きます。';

  @override
  String get updatesInstall => '再起動してインストール';

  @override
  String get updatesInstallApk => 'APK をインストール';

  @override
  String get updatesInstalling => 'インストールの準備中…';

  @override
  String get updatesSkip => 'このバージョンをスキップ';

  @override
  String get updatesLater => '後で';

  @override
  String get updatesPage => '手動更新・リリースページ';

  @override
  String get updatesFailed => '更新に失敗しました。再試行するかリリースページを開いてください。';

  @override
  String get updatesPermission =>
      'Flutify に不明なアプリのインストールを許可し、戻って「APK をインストール」をもう一度押してください。';

  @override
  String get updatesUnsupported =>
      'このプラットフォームではアプリ内インストールに対応していません。リリースページから手動で更新してください。';

  @override
  String get updatesDetails => '更新を表示';
}
