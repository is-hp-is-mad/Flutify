/// GraphQL Pathfinder 持久化查询（persisted query）。
///
/// 服务端按 sha256Hash 匹配查询文档，客户端只传操作名、变量与哈希。
/// 哈希取自官方桌面版 1.3.1.234 的 xpui.spa（完整清单：SpotifyApi/analysis-data/desktop/gql_ops_1.3.1.234.txt），
/// 桌面版升级后若返回 PersistedQueryNotFound，需要按新版本重新提取。
class PathfinderOperation {
  final String name;
  final String sha256Hash;

  const PathfinderOperation(this.name, this.sha256Hash);

  static const canvas = PathfinderOperation(
    'canvas',
    '575138ab27cd5c1b3e54da54d0a7cc8d85485402de26340c2145f0f6bb5e7a9f',
  );

  static const home = PathfinderOperation(
    'home',
    '76243c78b0e20ecdbe41b794dec8cbe73f75e585b0a7201b8d2e84578412847a',
  );
  static const browseAll = PathfinderOperation(
    'browseAll',
    'dbd8b55e09a58afc52eab438bc228ba28fd72ac2f2148c6c26354980e4579001',
  );
  static const browsePage = PathfinderOperation(
    'browsePage',
    'f5c4e6d668f5716464a231c1cc8b22c1cbf6ad68b09929fd7de813a30581298b',
  );
  static const getAlbum = PathfinderOperation(
    'getAlbum',
    '6a74b456cd1735c9193d9e8ec8cc5184cad7ce13572210315229db3975964361',
  );
  static const queryArtistOverview = PathfinderOperation(
    'queryArtistOverview',
    '7bdc7185c219898c7a2b659cfff2f8ce066dd2d9a97f8b7c4bde92ccfec28310',
  );
  static const queryArtistDiscographyAll = PathfinderOperation(
    'queryArtistDiscographyAll',
    '5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599',
  );
  static const searchDesktop = PathfinderOperation(
    'searchDesktop',
    'db61238974d27839a136c9dc02bfdbe3fab7635f21cf85976ebff9a1ee281345',
  );
  static const decorateContextTracks = PathfinderOperation(
    'decorateContextTracks',
    '383de00240775c39a6afe0b1055dc562b2a3930894201f9762f3fc32a74971c7',
  );

  /// 「添加到歌单」可选的歌单：当前账号可编辑的歌单与文件夹，并标出给定曲目是否已在其中。
  /// 这两项的哈希取自 open.spotify.com 的 web-player.632a438d.js（业务请求用的就是 Web 播放器身份）。
  static const editablePlaylists = PathfinderOperation(
    'editablePlaylists',
    'd5c4b8096437dcc2ac9528c91dfcd299e35b747cda2f8f75d28f41f49c5092ba',
  );

  /// 往歌单里加曲目（mutation；与 removeFromPlaylist / moveItemsInPlaylist 同一份文档）。
  static const addToPlaylist = PathfinderOperation(
    'addToPlaylist',
    'b907ad6b088d5bf7680fa81198996d58398c2d55dfcdf59fcc959e0be98a418a',
  );

  /// 「查看制作人员」弹窗：按角色分组的参与者与版权来源。
  static const queryTrackCreditsGroupedModal = PathfinderOperation(
    'queryTrackCreditsGroupedModal',
    'f135fb9be58a72d041ab5d214d817021a272405d883860468e2627afb01a3ca9',
  );

  /// 「已点赞的歌曲」分页（与 open.spotify.com 同一查询，不依赖 username）。
  static const fetchLibraryTracks = PathfinderOperation(
    'fetchLibraryTracks',
    '087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240',
  );

  /// 当前账号资料与 username（与 open.spotify.com 同一查询，不依赖 AP 或 /v1/me）。
  static const profileAttributes = PathfinderOperation(
    'profileAttributes',
    '08ffb4730af3746e04a8301396f20875dbbce10c75243803091a9274eacc8ac0',
  );

  /// 加入媒体库（点赞曲目 / 收藏专辑 / 关注艺人，与 open.spotify.com 同一 mutation）。
  static const addToLibrary = PathfinderOperation(
    'addToLibrary',
    '896ebcb47815681340860d121cb5d494e157e2a78d3950385cd54e0393c67148',
  );

  /// 移出媒体库（取消点赞 / 取消收藏 / 取消关注，与 open.spotify.com 同一 mutation）。
  static const removeFromLibrary = PathfinderOperation(
    'removeFromLibrary',
    '896ebcb47815681340860d121cb5d494e157e2a78d3950385cd54e0393c67148',
  );
}

/// 桌面版在 home / browse 类查询中声明的终端类型（xpui 中 IntegrationDesktop）。
const String kDesktopEndUserIntegration = 'INTEGRATION_DESKTOP';
