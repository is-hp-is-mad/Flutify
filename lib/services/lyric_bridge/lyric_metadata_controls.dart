import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/app_preferences.dart';
import '../../models/lyrics.dart';
import '../../models/lyrics_query.dart';
import '../media_controls/system_media_controls.dart';
import 'lyric_bridge_channel.dart';

/// 把当前歌词行送到系统媒体信息之外的地方（Android）：
///
/// - **蓝牙歌词**：连接符合条件的蓝牙音频设备（车载 / 手动加入 / 全部，见 [BluetoothLyricsMode]）时，
///   交给系统的标题换成当前歌词行（可附译文），艺人 / 专辑换成「歌名 - 艺人」。
///   车机通过 AVRCP 读媒体信息，屏幕上就会逐句显示歌词。
/// - **Flyme 状态栏歌词**：在魅族 Flyme 上把当前歌词行写进播放通知的 ticker。
///
/// 包在真正的系统媒体控制（audio_service）外面：曲目 / 播放状态照常转发，
/// 只在需要时把曲目信息改写后再交给内层。歌词与任务栏歌词同源（[lyricsLoader]）。
class LyricMetadataControls implements SystemMediaControls {
  final SystemMediaControls _inner;
  final LyricBridgePlatform _platform;
  final DateTime Function() _now;

  LyricMetadataControls(
    this._inner,
    this._platform, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _deviceSub = _platform.devices.listen(
      _onDevices,
      onError: (Object _) {},
    );
    unawaited(_detectFlyme());
  }

  /// 取歌词（由界面层接到 SpotifyProvider）。
  Future<SpotifyLyrics> Function(LyricsQuery query)? lyricsLoader;

  StreamSubscription<List<BluetoothAudioDevice>>? _deviceSub;
  List<BluetoothAudioDevice> _devices = const [];
  bool _isFlyme = false;

  BluetoothLyricsMode _mode = BluetoothLyricsMode.off;
  bool _withTranslation = false;
  Set<String> _extraDevices = const {};
  bool _flymeEnabled = false;

  MediaTrackInfo? _track;
  MediaPlaybackInfo? _playback;
  DateTime _playbackAt = DateTime.now();
  List<LyricLine>? _lines;
  int _generation = 0;
  Timer? _tick;

  /// 最近一次交给内层的曲目信息 / 状态栏文字，避免重复下发。
  MediaTrackInfo? _sentTrack;
  bool _trackSent = false;
  String? _sentTicker;
  Timer? _tickerRepost;
  bool _tickerShown = false;

  /// 当前连接的蓝牙音频设备（设置页显示 / 手动加入用）。
  final ValueNotifier<List<BluetoothAudioDevice>> connectedDevices =
      ValueNotifier(const []);

  /// 是否运行在 Flyme 上（设置页据此显示开关）。
  final ValueNotifier<bool> flyme = ValueNotifier(false);

  Future<void> _detectFlyme() async {
    try {
      _isFlyme = await _platform.isFlyme();
    } catch (_) {
      _isFlyme = false;
    }
    flyme.value = _isFlyme;
    // 检测是异步的：开着 Flyme 状态栏歌词时，检测完成才知道需要歌词，这里补取
    _loadLyrics();
    _refresh();
  }

  /// 界面层在偏好变化时调用。
  void configure({
    required BluetoothLyricsMode mode,
    required bool withTranslation,
    required List<String> extraDevices,
    required bool flymeStatusBar,
  }) {
    final extra = extraDevices.toSet();
    final needLyricsBefore = _needsLyrics;
    if (mode == _mode &&
        withTranslation == _withTranslation &&
        setEquals(extra, _extraDevices) &&
        flymeStatusBar == _flymeEnabled) {
      return;
    }
    _mode = mode;
    _withTranslation = withTranslation;
    _extraDevices = extra;
    _flymeEnabled = flymeStatusBar;
    if (!needLyricsBefore && _needsLyrics) _loadLyrics();
    _refresh();
  }

  /// 有任何一个出口需要歌词时才去取。
  bool get _needsLyrics =>
      _mode != BluetoothLyricsMode.off || (_flymeEnabled && _isFlyme);

  /// 当前是否把媒体信息换成歌词。
  @visibleForTesting
  bool get bluetoothActive {
    switch (_mode) {
      case BluetoothLyricsMode.off:
        return false;
      case BluetoothLyricsMode.all:
        return _devices.isNotEmpty;
      case BluetoothLyricsMode.car:
        return _devices.any(
          (d) => d.isCar || _extraDevices.contains(d.address),
        );
    }
  }

  void _onDevices(List<BluetoothAudioDevice> devices) {
    _devices = devices;
    connectedDevices.value = devices;
    _refresh();
  }

  /// Android 12+ 读取蓝牙设备名称 / 类别需要「附近的设备」权限。
  Future<bool> hasBluetoothPermission() async {
    try {
      return await _platform.hasBluetoothPermission();
    } catch (_) {
      return false;
    }
  }

  Future<void> requestBluetoothPermission() async {
    try {
      await _platform.requestBluetoothPermission();
    } catch (_) {}
  }

  /// 刷新已连接设备（设置页授权后调用）。
  Future<void> reloadDevices() async {
    try {
      _onDevices(await _platform.connectedDevices());
    } catch (_) {}
  }

  /// 歌词加载器就绪（界面层首次绑定）后补取当前曲目的歌词。
  void lyricsSourceReady() => _loadLyrics();

  /// App 内取到某首歌的歌词时调用：当前曲目还没有歌词就立即补上。
  void lyricsCached(String trackId) {
    if (_lines == null && _track?.id == trackId) _loadLyrics();
  }

  // ---------------------------------------------------------------------------
  // SystemMediaControls
  // ---------------------------------------------------------------------------

  @override
  Stream<MediaControlEvent> get events => _inner.events;

  @override
  bool get needsPeriodicTimeline => _inner.needsPeriodicTimeline;

  @override
  Future<void> setTrack(MediaTrackInfo? track) async {
    _track = track;
    _generation++;
    _lines = null;
    _trackSent = false;
    _loadLyrics();
    await _push();
  }

  @override
  Future<void> setPlayback(MediaPlaybackInfo info) async {
    _playback = info;
    _playbackAt = _now();
    await _inner.setPlayback(info);
    _refresh();
    _repostTicker();
  }

  /// audio_service 每次更新状态都会重建播放通知，ticker 与 Flyme 标志随之丢失：
  /// 等它发完通知后再补写一次当前歌词。
  void _repostTicker() {
    if (!_tickerShown) return;
    _tickerRepost?.cancel();
    _tickerRepost = Timer(const Duration(milliseconds: 400), () {
      final text = _sentTicker;
      if (text != null) unawaited(_safeTicker(text));
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _tickerRepost?.cancel();
    unawaited(_deviceSub?.cancel());
    if (_tickerShown) unawaited(_safeTicker(null));
    connectedDevices.dispose();
    flyme.dispose();
    _inner.dispose();
  }

  // ---------------------------------------------------------------------------
  // 歌词
  // ---------------------------------------------------------------------------

  void _loadLyrics() {
    final track = _track;
    final loader = lyricsLoader;
    if (track == null || loader == null || !_needsLyrics || _lines != null) {
      return;
    }
    final generation = _generation;
    unawaited(() async {
      SpotifyLyrics lyrics;
      try {
        lyrics = await loader(
          LyricsQuery(
            trackId: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            durationMs: track.duration.inMilliseconds,
          ),
        );
      } catch (_) {
        return;
      }
      if (generation != _generation || !lyrics.isSynced) return;
      _lines = lyrics.lines;
      _refresh();
    }());
  }

  Duration get _position {
    final info = _playback;
    if (info == null) return Duration.zero;
    if (!info.playing || info.buffering) return info.position;
    return info.position + _now().difference(_playbackAt);
  }

  /// 当前歌词行下标；前奏（第一句之前）为 -1。
  int _lineIndex(List<LyricLine> lines, int posMs) {
    var index = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startTimeMs > posMs) break;
      index = i;
    }
    return index;
  }

  void _refresh() {
    _tick?.cancel();
    _tick = null;
    unawaited(_push());
    // 播放中：在下一句开始时再刷新一次
    final lines = _lines;
    final info = _playback;
    if (lines == null || info == null || !info.playing || info.buffering) {
      return;
    }
    final posMs = _position.inMilliseconds;
    final next = lines.indexWhere((l) => l.startTimeMs > posMs);
    if (next < 0) return;
    final wait = Duration(milliseconds: lines[next].startTimeMs - posMs + 20);
    _tick = Timer(wait, _refresh);
  }

  /// 当前行文字；没有同步歌词 / 前奏 / 空行时为 null。
  LyricLine? _currentLine() {
    final lines = _lines;
    if (lines == null) return null;
    final index = _lineIndex(lines, _position.inMilliseconds);
    if (index < 0) return null;
    final line = lines[index];
    return line.words.trim().isEmpty ? null : line;
  }

  Future<void> _push() async {
    final track = _track;
    final line = _currentLine();

    // 蓝牙：换标题；条件不满足时还原为原始曲目信息
    MediaTrackInfo? outgoing = track;
    if (track != null && line != null && bluetoothActive) {
      final translation = line.translation.trim();
      final title = _withTranslation && translation.isNotEmpty
          ? '${line.words.trim()} / $translation'
          : line.words.trim();
      final subtitle = track.artist.isEmpty
          ? track.title
          : '${track.title} - ${track.artist}';
      outgoing = MediaTrackInfo(
        id: track.id,
        title: title,
        artist: subtitle,
        album: subtitle,
        artUrl: track.artUrl,
        duration: track.duration,
      );
    }
    if (!_trackSent || !_sameTrack(outgoing, _sentTrack)) {
      _trackSent = true;
      _sentTrack = outgoing;
      await _inner.setTrack(outgoing);
      _repostTicker();
    }

    // Flyme：只在播放中显示状态栏歌词，暂停 / 无歌词时清除
    final playing = _playback?.playing == true;
    final ticker = _flymeEnabled && _isFlyme && playing
        ? line?.words.trim()
        : null;
    if (ticker != _sentTicker && (ticker != null || _tickerShown)) {
      _sentTicker = ticker;
      _tickerShown = ticker != null;
      await _safeTicker(ticker);
    }
  }

  Future<void> _safeTicker(String? text) async {
    try {
      await _platform.setTicker(text);
    } catch (_) {}
  }

  static bool _sameTrack(MediaTrackInfo? a, MediaTrackInfo? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.id == b.id &&
        a.title == b.title &&
        a.artist == b.artist &&
        a.album == b.album &&
        a.artUrl == b.artUrl &&
        a.duration == b.duration;
  }
}
