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

  /// 「查看制作人员」弹窗：按角色分组的参与者与版权来源。
  static const queryTrackCreditsGroupedModal = PathfinderOperation(
    'queryTrackCreditsGroupedModal',
    'f135fb9be58a72d041ab5d214d817021a272405d883860468e2627afb01a3ca9',
  );

  /// 实体竖滑视频流（艺人 / 专辑 / 歌单页「观看」入口，桌面网页版 1.3.9 抓包）：
  /// 变量 watchFeedUri = `spotify:watch-feed:{artist|album|playlist}:<id>`、offset、limit。
  /// 只接受实体 feed，`discovery-feed`（#标签）会被服务端判为类型不符。
  static const watchFeedEntity = PathfinderOperation(
    'watchFeedEntity',
    'd1a805f815ee0c20281330317d8c00c8fce9026686a86c38bc700ccaefb9ac5c',
  );
}

/// 桌面版在 home / browse 类查询中声明的终端类型（xpui 中 IntegrationDesktop）。
const String kDesktopEndUserIntegration = 'INTEGRATION_DESKTOP';
