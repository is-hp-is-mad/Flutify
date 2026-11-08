import '../models/album.dart';
import '../models/playback_context.dart';
import 'app_localizations.dart';

/// 数据模型 → 界面标签的本地化映射。
///
/// 模型只保存 Spotify 原始字段（album_type、context type 等），
/// 展示文案统一在这里转换，模型层不包含任何界面语言。
extension ModelLabels on AppLocalizations {
  /// 专辑类型：album / single / compilation → 专辑 / 单曲 / 合辑。
  String albumType(SpotifyAlbum album) => switch (album.albumType) {
        'single' => typeSingle,
        'compilation' => typeCompilation,
        _ => typeAlbum,
      };

  /// 全屏播放器顶部的播放来源小标题。
  String playingFrom(PlaybackContext context) => switch (context.type) {
        'playlist' => playingFromPlaylist,
        'album' => playingFromAlbum,
        'artist' => playingFromArtist,
        'search' => playingFromSearch,
        'collection' => playingFromLibrary,
        _ => nowPlaying,
      };

  /// 主页顶部筛选标签文案拦截。
  ///
  /// 拦截服务端动态下发的英文 chip（如 Following / Music / Podcasts / Audiobooks / Playlists / Albums 等），
  /// 统一转为符合当前语言环境的本地化文案。
  String homeChipLabel(String label, [String? id]) {
    final normId = (id ?? '').trim().toLowerCase();
    final normLabel = label.trim().toLowerCase();
    final isZhHant = localeName.startsWith('zh_Hant') || localeName == 'zh_TW' || localeName == 'zh_HK';
    final isZh = localeName.startsWith('zh');
    final isJa = localeName.startsWith('ja');

    if (normId == 'sub-following' || normId == 'following' || normLabel == 'following') {
      return artistFollowing;
    }
    if (normId == 'music' || normId == 'music-chip' || normLabel == 'music') {
      return filterMusic;
    }
    if (normId == 'podcasts' || normId == 'podcast' || normLabel == 'podcasts' || normLabel == 'podcast') {
      return filterPodcasts;
    }
    if (normId == 'audiobooks' || normId == 'audiobook' || normLabel == 'audiobooks' || normLabel == 'audiobook') {
      if (isZhHant) return '有聲書';
      if (isZh) return '有声书';
      if (isJa) return 'オーディオブック';
      return 'Audiobooks';
    }
    if (normId == 'playlists' || normId == 'playlist' || normLabel == 'playlists' || normLabel == 'playlist') {
      return filterPlaylists;
    }
    if (normId == 'albums' || normId == 'album' || normLabel == 'albums' || normLabel == 'album') {
      return filterAlbums;
    }
    if (normId == 'artists' || normId == 'artist' || normLabel == 'artists' || normLabel == 'artist') {
      return filterArtists;
    }
    if (normId == 'songs' || normId == 'tracks' || normLabel == 'songs' || normLabel == 'tracks') {
      return filterSongs;
    }
    if (normId == 'all' || normLabel == 'all') {
      return filterAll;
    }
    if (normId == 'downloaded' || normLabel == 'downloaded') {
      if (isZhHant) return '已下載';
      if (isZh) return '已下载';
      if (isJa) return 'ダウンロード済み';
      return 'Downloaded';
    }
    return label;
  }

  /// 搜索分类卡片与分类页标题拦截。
  ///
  /// 拦截服务端 slug 或原始英文分类名（如 toplists、pop、rock 等），转为本地化文案。
  String categoryName(String name, [String? id]) {
    final key = ((id != null && id.isNotEmpty) ? id : name).trim().toLowerCase();
    final nameKey = name.trim().toLowerCase();
    final isZhHant = localeName.startsWith('zh_Hant') || localeName == 'zh_TW' || localeName == 'zh_HK';
    final isZh = localeName.startsWith('zh');
    final isJa = localeName.startsWith('ja');

    if (!isZh && !isJa) {
      if (key == 'toplists') return 'Top Lists';
      return name;
    }

    if (key == 'toplists' || key == 'top lists' || key == 'charts' || nameKey == 'top lists' || nameKey == 'charts') {
      if (isJa) return 'ランキング';
      return '排行榜';
    }
    if (key == 'pop' || nameKey == 'pop') {
      if (isJa) return 'ポップ';
      return '流行';
    }
    if (key == 'rock' || nameKey == 'rock') {
      if (isJa) return 'ロック';
      if (isZhHant) return '搖滾';
      return '摇滚';
    }
    if (key == 'hiphop' || key == 'hip-hop' || nameKey == 'hip hop' || nameKey == 'hip-hop') {
      if (isJa) return 'ヒップホップ';
      return '嘻哈';
    }
    if (key == 'edm_dance' || key == 'dance' || key == 'electronic' || nameKey == 'dance' || nameKey == 'electronic' || nameKey == 'dance/electronic') {
      if (isJa) return 'エレクトロニック';
      if (isZhHant) return '電子';
      return '电子';
    }
    if (key == 'indie' || nameKey == 'indie') {
      if (isJa) return 'インディーズ';
      if (isZhHant) return '獨立音樂';
      return '独立音乐';
    }
    if (key == 'classical' || nameKey == 'classical') {
      if (isJa) return 'クラシック';
      return '古典';
    }
    if (key == 'jazz' || nameKey == 'jazz') {
      if (isJa) return 'ジャズ';
      return '爵士';
    }
    if (key == 'kpop' || key == 'k-pop' || nameKey == 'k-pop') {
      if (isJa) return 'K-Pop';
      if (isZhHant) return '韓流';
      return '韩流';
    }
    if (key == 'jpop' || key == 'j-pop' || nameKey == 'j-pop') {
      return 'J-Pop';
    }
    if (key == 'anime' || nameKey == 'anime') {
      if (isJa) return 'アニメ';
      if (isZhHant) return '動漫';
      return '动漫';
    }
    if (key == 'gaming' || nameKey == 'gaming') {
      if (isJa) return 'ゲーム';
      if (isZhHant) return '遊戲';
      return '游戏';
    }
    if (key == 'chill' || nameKey == 'chill') {
      if (isJa) return 'リラックス';
      if (isZhHant) return '放鬆';
      return '放松';
    }
    if (key == 'sleep' || key == 'ambient' || nameKey == 'sleep' || nameKey == 'ambient') {
      if (isJa) return '睡眠';
      return '助眠';
    }
    if (key == 'workout' || nameKey == 'workout') {
      if (isJa) return 'ワークアウト';
      if (isZhHant) return '運動健身';
      return '运动健身';
    }
    if (key == 'party' || nameKey == 'party') {
      if (isJa) return 'パーティー';
      if (isZhHant) return '派對';
      return '派对';
    }
    if (key == 'focus' || nameKey == 'focus') {
      if (isJa) return '集中';
      if (isZhHant) return '專注';
      return '专注';
    }
    if (key == 'mood' || nameKey == 'mood') {
      if (isJa) return '気分';
      return '心情';
    }
    if (key == 'folk' || key == 'acoustic' || nameKey == 'folk' || nameKey == 'folk & acoustic') {
      if (isJa) return 'フォーク';
      if (isZhHant) return '民謠';
      return '民谣';
    }
    if (key == 'metal' || nameKey == 'metal') {
      if (isJa) return 'メタル';
      if (isZhHant) return '重金屬';
      return '重金属';
    }
    if (key == 'punk' || nameKey == 'punk') {
      if (isJa) return 'パンク';
      if (isZhHant) return '龐克';
      return '朋克';
    }
    if (key == 'country' || nameKey == 'country') {
      if (isJa) return 'カントリー';
      if (isZhHant) return '鄉村';
      return '乡村';
    }
    if (key == 'instrumental' || nameKey == 'instrumental') {
      if (isJa) return 'インストゥルメンタル';
      if (isZhHant) return '純音樂';
      return '纯音乐';
    }
    if (key == 'rnb' || key == 'r_and_b' || nameKey == 'r&b') {
      return 'R&B';
    }
    if (key == 'mandopop' || nameKey == 'mandopop' || nameKey == 'mando pop') {
      if (isJa) return 'マンドポップ';
      if (isZhHant) return '華語流行';
      return '华语流行';
    }
    if (key == 'cantopop' || nameKey == 'cantopop' || nameKey == 'canto pop') {
      if (isJa) return '広東ポップ';
      if (isZhHant) return '粵語流行';
      return '粤语流行';
    }
    if (key == 'blues' || nameKey == 'blues') {
      if (isJa) return 'ブルース';
      return '蓝调';
    }
    if (key == 'soul' || nameKey == 'soul') {
      if (isJa) return 'ソウル';
      if (isZhHant) return '靈魂樂';
      return '灵魂乐';
    }
    if (key == 'latin' || nameKey == 'latin') {
      if (isJa) return 'ラテン';
      return '拉丁';
    }
    if (key == 'romance' || nameKey == 'romance') {
      if (isJa) return 'ロマンス';
      return '浪漫';
    }
    if (key == 'wellness' || nameKey == 'wellness') {
      if (isJa) return 'ウェルネス';
      if (isZhHant) return '療癒健康';
      return '疗愈健康';
    }
    if (key == 'in_the_car' || key == 'travel' || nameKey == 'in the car' || nameKey == 'travel') {
      if (isJa) return 'ドライブ';
      if (isZhHant) return '駕駛旅途';
      return '驾驶旅途';
    }

    return name;
  }

  /// 主页动态栏目标题拦截。
  ///
  /// 拦截服务端动态栏目标题（Recently played / Made For You / Jump back in 等）。
  String homeSectionTitle(String title) {
    final key = title.trim().toLowerCase();
    final isZhHant = localeName.startsWith('zh_Hant') || localeName == 'zh_TW' || localeName == 'zh_HK';
    final isZh = localeName.startsWith('zh');
    final isJa = localeName.startsWith('ja');

    if (!isZh && !isJa) return title;

    if (key == 'recently played') {
      if (isJa) return '最近の再生';
      return '最近播放';
    }
    if (key == 'made for you') {
      if (isJa) return 'あなたへのおすすめ';
      if (isZhHant) return '為你打造';
      return '为你打造';
    }
    if (key == 'jump back in') {
      if (isJa) return 'もう一度聴く';
      if (isZhHant) return '繼續收聽';
      return '继续收听';
    }
    if (key == 'your top mixes') {
      if (isJa) return 'あなたのお気に入りMix';
      if (isZhHant) return '你的專屬合輯';
      return '你的专属合辑';
    }
    if (key == 'recommended for today') {
      if (isJa) return '今日のおすすめ';
      if (isZhHant) return '今日推薦';
      return '今日推荐';
    }
    if (key == 'popular artists') {
      if (isJa) return '人気のアーティスト';
      if (isZhHant) return '熱門藝人';
      return '热门艺人';
    }
    if (key == 'popular albums') {
      if (isJa) return '人気のアルバム';
      if (isZhHant) return '熱門專輯';
      return '热门专辑';
    }
    if (key == 'popular radio') {
      if (isJa) return '人気のラジオ';
      if (isZhHant) return '熱門電台';
      return '热门电台';
    }
    if (key == 'featured playlists') {
      if (isJa) return '注目のプレイリスト';
      if (isZhHant) return '精選歌單';
      return '精选歌单';
    }
    if (key == 'uniquely yours') {
      if (isJa) return 'あなただけのプレイリスト';
      if (isZhHant) return '專屬於你';
      return '专属于你';
    }
    if (key == 'heavy rotation') {
      if (isJa) return 'よく聴く曲';
      if (isZhHant) return '經常收聽';
      return '经常收听';
    }
    if (key == 'throwback') {
      if (isJa) return '懐かしのヒット曲';
      if (isZhHant) return '經典回顧';
      return '经典回顾';
    }
    if (key == "today's biggest hits" || key == 'todays biggest hits') {
      if (isJa) return '今日のヒット曲';
      if (isZhHant) return '今日熱門單曲';
      return '今日热门单曲';
    }
    if (key == 'based on your recent listening') {
      if (isJa) return '最近の再生履歴に基づくおすすめ';
      if (isZhHant) return '根據你最近的收聽';
      return '根据你最近的收听';
    }
    if (key == 'more of what you like') {
      if (isJa) return 'あなたの好きな音楽';
      if (isZhHant) return '更多你喜歡的音樂';
      return '更多你喜欢的音乐';
    }
    if (key == 'best of artists') {
      if (isJa) return 'アーティストベスト';
      if (isZhHant) return '藝人精選';
      return '艺人精选';
    }
    if (key == 'shows you might like') {
      if (isJa) return 'おすすめの番組';
      if (isZhHant) return '你可能喜歡的節目';
      return '你可能喜欢的节目';
    }
    if (key == 'episodes for you') {
      if (isJa) return 'おすすめのエピソード';
      if (isZhHant) return '為你推薦的單集';
      return '为你推荐的单集';
    }
    if (key == 'popular playlists' || key == 'top playlists') {
      if (isJa) return '人気のプレイリスト';
      if (isZhHant) return '熱門歌單';
      return '热门歌单';
    }
    if (key == 'trending now' || key == 'trending') {
      if (isJa) return '急上昇中';
      if (isZhHant) return '當前流行';
      return '当前流行';
    }
    if (key == 'new releases' || key == 'new release') {
      if (isJa) return '最新リリース';
      if (isZhHant) return '最新發行';
      return '最新发行';
    }
    if (key == 'charts') {
      if (isJa) return 'ランキング';
      return '排行榜';
    }
    if (key == 'top tracks' || key == 'popular tracks') {
      if (isJa) return '人気の楽曲';
      if (isZhHant) return '熱門單曲';
      return '热门单曲';
    }
    if (key == "editor's picks" || key == "editors' picks") {
      if (isJa) return 'エディターのおすすめ';
      if (isZhHant) return '編輯精選';
      return '编辑精选';
    }
    if (key == 'fresh finds') {
      if (isJa) return '注目の新世代';
      if (isZhHant) return '最新發掘';
      return '最新发掘';
    }
    if (key == 'radar') {
      if (isJa) return 'レーダー';
      if (isZhHant) return '音樂雷達';
      return '音乐雷达';
    }

    return title;
  }
}
