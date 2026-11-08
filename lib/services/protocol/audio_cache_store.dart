/// 本地音频缓存的管理接口（设置页「存储」分组使用）。
///
/// 由 TrackAudioLoader 实现；测试可注入假实现。所有方法都不抛错：
/// 文件被占用（如正在播放的歌曲）等情况跳过该文件，其余照常处理。
abstract class AudioCacheStore {
  /// 缓存上限（字节）；调小后立即按「最久未用先删」淘汰到上限以内。
  int get maxCacheBytes;
  set maxCacheBytes(int value);

  /// 当前缓存占用（字节）。
  Future<int> sizeBytes();

  /// 清空缓存，返回实际释放的字节数（正在使用的文件保留）。
  Future<int> clear();
}
