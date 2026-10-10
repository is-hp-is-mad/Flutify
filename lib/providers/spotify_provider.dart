import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/artist.dart';
import '../models/catalog_page.dart';
import '../models/category.dart';
import '../models/device.dart';
import '../models/home_feed.dart';
import '../models/lyrics.dart';
import '../models/lyrics_query.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../models/user_profile.dart';
import '../services/lyrics/lyrics_resolver.dart';
import '../services/lyrics/lyrics_translation.dart';
import '../services/cache/cache_location.dart';
import '../services/spotify_api_service.dart';
import '../services/storage_service.dart';

enum SearchResultType { tracks, artists, playlists }

/// 远端内容：主页数据、搜索、歌词与 Spotify Connect 设备。
class SpotifyProvider extends ChangeNotifier {
  static const Duration _searchDebounce = Duration(milliseconds: 300);

  final SpotifyApiService _api;
  final StorageService _storage;

  SpotifyUser _user = SpotifyUser.guest;
  HomeFeed _home = HomeFeed.empty;
  List<SpotifyCategory> _categories = [];
  List<SpotifyDevice> _devices = [];
  SpotifyDevice? _activeDevice;
  bool _isLoadingHome = false;
  String? _homeError;

  // 主页筛选标签：切换时只重新请求主页，不动用户 / 分类 / 设备
  String _homeFacet = '';
  bool _isLoadingFeed = false;
  int _feedGeneration = 0;
  Future<void>? _feedRequest;
  int _initialGeneration = 0;

  // Search
  Timer? _searchTimer;
  int _searchGeneration = 0;
  String _searchQuery = '';
  bool _isSearching = false;
  String? _searchError;
  final Map<SearchResultType, int> _searchNextOffsets = {};
  final Set<SearchResultType> _searchLoadingMore = {};
  final Map<SearchResultType, String> _searchPageErrors = {};
  List<SpotifyTrack> _searchTracks = [];
  List<SpotifyArtist> _searchArtists = [];
  List<SpotifyPlaylist> _searchPlaylists = [];
  List<String> _recentSearches = [];

  // Lyrics（按曲目 ID 缓存，避免重复打开歌词页时重复请求）
  final LyricsResolver _lyrics;
  final Map<String, SpotifyLyrics> _lyricsCache = {};
  final Map<String, Future<SpotifyLyrics>> _lyricsInFlight = {};
  int _lyricsGeneration = 0;

  /// [invalidateResolvedLyrics] 时递增：在那之前发出、还没返回的请求结果作废，不再写入缓存。
  int _lyricsEpoch = 0;
  final StreamController<String> _lyricsCached = StreamController.broadcast();

  /// dispose 之后异步回调不得再 notifyListeners。
  bool _disposed = false;

  /// [lyrics] 为空时只用 Spotify 官方歌词（测试默认）；App 里注入带 LRCLIB 补全的合并器。
  SpotifyProvider(this._api, this._storage, {LyricsResolver? lyrics})
    : _lyrics = lyrics ?? LyricsResolver(_api.getLyrics) {
    _recentSearches = _storage.recentSearches;
    loadInitialData();
  }

  SpotifyUser get user => _user;
  HomeFeed get home => _home;
  List<SpotifyCategory> get categories => _categories;
  List<SpotifyDevice> get devices => _devices;
  SpotifyDevice? get activeDevice => _activeDevice;
  bool get isLoadingHome => _isLoadingHome;

  /// 当前主页筛选标签 id（空 = 全部）。
  String get homeFacet => _homeFacet;

  /// 主页内容加载中（首次加载或切换筛选标签）。
  bool get isLoadingFeed => _isLoadingHome || _isLoadingFeed;

  /// 主页数据加载失败的说明（简体中文）；成功或未登录为 null。
  /// 未登录时各列表为空且不算错误，UI 应展示登录引导而不是错误。
  String? get homeError => _homeError;

  String get searchQuery => _searchQuery;
  bool get isSearching => _isSearching;
  String? get searchError => _searchError;
  bool get searchRequiresSignIn => _searchError != null && !_api.isConfigured;
  bool searchHasMore(SearchResultType type) =>
      _searchNextOffsets.containsKey(type);
  bool isLoadingMoreSearch(SearchResultType type) =>
      _searchLoadingMore.contains(type);
  String? searchPageError(SearchResultType type) => _searchPageErrors[type];
  List<SpotifyTrack> get searchTracks => _searchTracks;
  List<SpotifyArtist> get searchArtists => _searchArtists;
  List<SpotifyPlaylist> get searchPlaylists => _searchPlaylists;
  List<String> get recentSearches => _recentSearches;

  /// 加载主页数据（用户、主页分区、分类、设备）。登录 / 登出后应再次调用。
  ///
  /// 四个请求互不依赖，并行发出；任意一个失败只影响自己的那部分数据，
  /// 失败原因记入 [homeError]（取第一条）。
  Future<void> loadInitialData() async {
    final initialGeneration = ++_initialGeneration;
    _isLoadingHome = true;
    _homeError = null;
    final feedGeneration = ++_feedGeneration;
    _feedRequest = null;
    String? error;
    notifyListeners();

    Future<T> guard<T>(Future<T> request, T fallback) async {
      try {
        return await request;
      } catch (e) {
        error ??= e is SpotifyDataException ? e.toString() : '加载失败：$e';
        return fallback;
      }
    }

    final results = await Future.wait<Object>([
      guard<SpotifyUser>(_api.getCurrentUser(), SpotifyUser.guest),
      guard<HomeFeed>(_api.getHome(facet: _homeFacet), HomeFeed.empty),
      guard<List<SpotifyCategory>>(_api.getCategories(), const []),
      guard<List<SpotifyDevice>>(_api.getDevices(), const []),
    ]);
    if (_disposed || initialGeneration != _initialGeneration) return;
    _user = results[0] as SpotifyUser;
    // 加载期间用户已切换筛选标签：以那次请求的结果为准
    if (feedGeneration == _feedGeneration) {
      _home = results[1] as HomeFeed;
      _homeError = error;
      _isLoadingFeed = false;
    }
    _categories = results[2] as List<SpotifyCategory>;
    _devices = results[3] as List<SpotifyDevice>;
    _activeDevice = _devices.isEmpty
        ? null
        : _devices.firstWhere((d) => d.isActive, orElse: () => _devices.first);

    _isLoadingHome = false;
    notifyListeners();
  }

  /// 切换主页筛选标签（[facet] 为空 = 全部）：只重新请求主页分区。
  ///
  /// 连续点击时丢弃过期请求的结果；失败时保留旧内容并记入 [homeError]。
  Future<void> selectHomeFacet(String facet) {
    if (facet == _homeFacet) {
      if (_feedRequest != null) return _feedRequest!;
      if (!_home.isEmpty) return Future.value();
    }
    _homeFacet = facet;
    return _requestHome();
  }

  /// 保留当前筛选，仅刷新主页；同一次请求完成前合并重复刷新。
  Future<void> refreshHome() => _feedRequest ?? _requestHome();

  Future<void> _requestHome() {
    final generation = ++_feedGeneration;
    final facet = _homeFacet;
    _isLoadingFeed = true;
    _homeError = null;
    final completion = Completer<void>();
    _feedRequest = completion.future;
    notifyListeners();
    unawaited(_fetchHome(facet, generation).whenComplete(completion.complete));
    return completion.future;
  }

  Future<void> _fetchHome(String facet, int generation) async {
    HomeFeed? feed;
    String? error;
    try {
      feed = await _api.getHome(facet: facet);
    } catch (e) {
      error = e is SpotifyDataException ? e.toString() : '加载失败：$e';
    }
    if (_disposed || generation != _feedGeneration) return;
    if (feed != null) _home = feed;
    _homeError = error;
    _feedRequest = null;
    _isLoadingFeed = false;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  /// 输入时调用：300ms 防抖，并丢弃过期请求的返回结果（避免乱序覆盖）。
  void performSearch(String query) {
    if (_disposed) return;
    _searchTimer?.cancel();
    _searchQuery = query;
    final generation = ++_searchGeneration;
    _searchTracks = [];
    _searchArtists = [];
    _searchPlaylists = [];
    _searchNextOffsets.clear();
    _searchLoadingMore.clear();
    _searchPageErrors.clear();
    _searchError = null;
    _isSearching = query.trim().isNotEmpty;
    notifyListeners();
    if (!_isSearching) return;
    _searchTimer = Timer(_searchDebounce, () => _runSearch(query, generation));
  }

  Future<void> _runSearch(String query, int generation) async {
    SearchPage? results;
    String? error;
    try {
      results = await _api.searchPage(query);
    } catch (e) {
      error = e.toString();
    }

    if (_disposed || generation != _searchGeneration) return;
    if (results != null) _applySearchPage(results);
    _searchError = error;
    _isSearching = false;
    notifyListeners();
  }

  /// 只重试失败的首屏；各类型后续页仍通过 [loadMoreSearch] 重试。
  Future<void> retrySearch() async {
    if (_disposed || _isSearching || _searchError == null) return;
    _isSearching = true;
    _searchError = null;
    final generation = ++_searchGeneration;
    notifyListeners();
    await _runSearch(_searchQuery, generation);
  }

  /// 各类型独立分页；失败保留已有结果与游标，重试仍取同一页。
  Future<void> loadMoreSearch(SearchResultType type) async {
    if (_disposed || _isSearching || _searchLoadingMore.contains(type)) return;
    final offset = _searchNextOffsets[type];
    if (offset == null) return;
    final generation = _searchGeneration;
    _searchLoadingMore.add(type);
    _searchPageErrors.remove(type);
    notifyListeners();
    SearchPage? page;
    String? error;
    try {
      page = await _api.searchPage(
        _searchQuery,
        offset: offset,
        type: type.name,
      );
    } catch (e) {
      error = e.toString();
    }
    if (_disposed || generation != _searchGeneration) return;
    if (page != null) _applySearchPage(page, type: type, offset: offset);
    if (error != null) _searchPageErrors[type] = error;
    _searchLoadingMore.remove(type);
    notifyListeners();
  }

  void _applySearchPage(
    SearchPage page, {
    SearchResultType? type,
    int offset = 0,
  }) {
    void updateOffset(SearchResultType type, int? nextOffset) {
      // 服务端偏移量按原始条目计数，不能用去重后的 UI 列表长度代替。
      if (nextOffset != null && nextOffset > offset) {
        _searchNextOffsets[type] = nextOffset;
      } else {
        _searchNextOffsets.remove(type);
      }
    }

    if (type == null || type == SearchResultType.tracks) {
      _searchTracks = _mergeSearchResults(
        _searchTracks,
        page.tracks.items,
        (t) => t.id.isNotEmpty ? t.id : t.uri,
      );
      updateOffset(SearchResultType.tracks, page.tracks.nextOffset);
    }
    if (type == null || type == SearchResultType.artists) {
      _searchArtists = _mergeSearchResults(
        _searchArtists,
        page.artists.items,
        (a) => a.id.isNotEmpty ? a.id : a.uri,
      );
      updateOffset(SearchResultType.artists, page.artists.nextOffset);
    }
    if (type == null || type == SearchResultType.playlists) {
      _searchPlaylists = _mergeSearchResults(
        _searchPlaylists,
        page.playlists.items,
        (p) => p.id.isNotEmpty ? p.id : p.uri,
      );
      updateOffset(SearchResultType.playlists, page.playlists.nextOffset);
    }
  }

  List<T> _mergeSearchResults<T>(
    List<T> current,
    List<T> incoming,
    String Function(T) idOf,
  ) {
    final seen = current.map(idOf).where((id) => id.isNotEmpty).toSet();
    return [
      ...current,
      for (final item in incoming)
        if (idOf(item).isEmpty || seen.add(idOf(item))) item,
    ];
  }

  /// 用户确认搜索（回车或点击结果）时记录历史。
  void commitRecentSearch(String query) {
    final clean = query.trim();
    if (clean.isEmpty) return;
    _recentSearches = [
      clean,
      ..._recentSearches.where((q) => q != clean),
    ].take(20).toList();
    _storage.addRecentSearch(clean);
    notifyListeners();
  }

  void removeRecentSearch(String query) {
    _recentSearches = _recentSearches.where((q) => q != query).toList();
    _storage.removeRecentSearch(query);
    notifyListeners();
  }

  void clearRecentSearches() {
    _recentSearches = [];
    _storage.clearRecentSearches();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Lyrics
  // ---------------------------------------------------------------------------
  SpotifyLyrics? cachedLyrics(String trackId) => _lyricsCache[trackId];

  Future<LyricsTranslation?> fetchLyricsTranslation(
    LyricsQuery query,
    SpotifyLyrics lyrics,
    String target,
  ) => _lyrics.translate(query, lyrics, target);

  /// 某首歌的歌词取到并写入缓存时发出曲目 ID（任务栏歌词据此补上之前没取到的歌词）。
  Stream<String> get lyricsCached => _lyricsCached.stream;

  /// 已缓存歌词的曲目数（设置页「隐私」分组展示）。
  int get cachedLyricsCount => _lyricsCache.length;

  /// 歌词缓存被清空 / 作废，或某首歌被要求重新获取时递增；歌词视图据此重新加载。
  int get lyricsGeneration => _lyricsGeneration;

  /// 清空歌词缓存（含 LRCLIB 补全的本地缓存）：已打开的歌词视图随之重新请求。
  Future<CacheResult> clearLyricsCache({
    Future<CacheResult> Function()? clearDisk,
  }) async {
    _lyricsCache.clear();
    _lyricsInFlight.clear();
    _lyrics.fallback?.clearCandidates();
    _lyricsGeneration++;
    final cache = _lyrics.fallback?.cache;
    final result = cache != null
        ? await cache.clear(clearFiles: clearDisk)
        : await clearDisk?.call() ?? CacheResult();
    final cleared = {?cache};
    for (final source in _lyrics.translationSources) {
      final translationCache = source.cache;
      if (translationCache != null && cleared.add(translationCache)) {
        result.add(await translationCache.clear());
      }
    }
    if (!_disposed) notifyListeners();
    return result;
  }

  /// 作废内存里已解析的歌词（含进行中的请求），LRCLIB / QQ / 网易云的本地缓存保留：
  /// 开启「双语歌词」时调用——关闭期间解析的歌词没查过译文，已打开的歌词视图随之重新解析。
  void invalidateResolvedLyrics() {
    _lyricsEpoch++;
    _lyricsCache.clear();
    _lyricsInFlight.clear();
    _lyricsGeneration++;
    if (!_disposed) notifyListeners();
  }

  /// 重新获取一首歌的歌词：丢掉内存与本地缓存后重新查（补全歌词选错语言 / 版本时用）。
  Future<SpotifyLyrics> refetchLyrics(LyricsQuery query) async {
    _lyricsCache.remove(query.trackId);
    _lyricsInFlight.clear();
    _lyricsGeneration++;
    await _lyrics.forget(query);
    final lyrics = fetchLyrics(query);
    if (!_disposed) notifyListeners();
    return lyrics;
  }

  /// 获取歌词（Spotify 官方优先，没有逐行同步歌词时按设置用 LRCLIB 补全，见 [LyricsResolver]）：
  /// 命中缓存直接返回，并发请求合并为同一个 Future。
  Future<SpotifyLyrics> fetchLyrics(LyricsQuery query) {
    final generation = _lyricsGeneration;
    final trackId = query.trackId;
    final cached = _lyricsCache[trackId];
    if (cached != null) return Future.value(cached);

    // whenComplete 回调必须是块体：箭头函数会返回 remove() 取出的 Future 本身，
    // whenComplete 会等待该 Future，形成自我等待的死锁。
    //
    // 只缓存确定的结果（含「这首歌没有歌词」）；网络 / 鉴权错误不缓存，下次打开歌词页会重试，
    // 本次对 UI 返回空歌词（显示「暂无歌词」）。
    //
    // 请求期间内存歌词被作废（[invalidateResolvedLyrics]）：结果照常返回给这次的调用方，但可能缺译文，
    // 不写缓存，也不能把作废之后同一首歌新发出的请求从 _lyricsInFlight 里移除。
    final epoch = _lyricsEpoch;
    return _lyricsInFlight[trackId] ??= _lyrics
        .resolve(query)
        .then((resolved) {
          if (resolved.cacheable &&
              !_disposed &&
              generation == _lyricsGeneration &&
              epoch == _lyricsEpoch) {
            // 先删再写：命中的歌排到最新；只留最近 40 首，连续播放很久也不会无限增长
            _lyricsCache.remove(trackId);
            _lyricsCache[trackId] = resolved.lyrics;
            while (_lyricsCache.length > 40) {
              _lyricsCache.remove(_lyricsCache.keys.first);
            }
            if (!_disposed) _lyricsCached.add(trackId);
          }
          return resolved.lyrics;
        })
        .catchError((Object _) => const SpotifyLyrics(lines: []))
        .whenComplete(() {
          if (generation == _lyricsGeneration && epoch == _lyricsEpoch)
            _lyricsInFlight.remove(trackId);
        });
  }

  // ---------------------------------------------------------------------------
  // Devices
  // ---------------------------------------------------------------------------
  void setActiveDevice(SpotifyDevice device) {
    _activeDevice = device;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _searchTimer?.cancel();
    unawaited(_lyricsCached.close());
    super.dispose();
  }
}
