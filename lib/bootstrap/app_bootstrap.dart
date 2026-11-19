import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../core/rust_core.dart';
import '../core/utils/local_device_name.dart';
import '../core/utils/orientation_policy.dart';
import '../models/app_preferences.dart';
import '../models/appearance.dart';
import '../self_test/e2e_runner.dart';
import '../self_test/launch_args.dart';
import '../self_test/mock_services.dart';
import '../services/audio/audio_engine.dart';
import '../services/audio/routed_audio_engine.dart';
import '../services/audio_player_service.dart';
import '../services/auth/login_region_check.dart';
import '../services/auth/session_http_client.dart';
import '../services/auth/spotify_auth_service.dart';
import '../services/auth/web_token_service.dart';
import '../services/backup/playlist_backup_service.dart';
import '../services/cache/artwork_cache.dart';
import '../services/cache/cache_directory_access.dart';
import '../services/cache/cache_location.dart';
import '../services/eme/eme_audio_engine.dart';
import '../services/eme/eme_player.dart';
import '../services/eme/license_client.dart';
import '../services/eme/native_drm_audio_engine.dart';
import '../services/eme/native_drm_player.dart';
import '../services/lyric_bridge/lyric_bridge_channel.dart';
import '../services/lyric_bridge/lyric_metadata_controls.dart';
import '../services/lyrics/lrclib_client.dart';
import '../services/lyrics/lrclib_lyrics_source.dart';
import '../services/lyrics/lyrics_disk_cache.dart';
import '../services/lyrics/netease_client.dart';
import '../services/lyrics/netease_translation_source.dart';
import '../services/lyrics/qq_music_client.dart';
import '../services/lyrics/qq_translation_source.dart';
import '../services/media_controls/multi_media_controls.dart';
import '../services/media_controls/system_media_controls.dart';
import '../services/network/network_proxy.dart';
import '../services/network/system_proxy_channel.dart';
import '../services/network/windows_trust_store.dart';
import '../services/playback/playback_region_gate.dart';
import '../services/playback_session_store.dart';
import '../services/protocol/eme_track_audio_source.dart';
import '../services/spotify_api_service.dart';
import '../services/storage_service.dart';
import '../services/taskbar_lyrics/taskbar_lyrics_channel.dart';
import '../services/taskbar_lyrics/taskbar_lyrics_controls.dart';
import '../services/updates/update_installer.dart';
import '../services/updates/update_service.dart';
import '../services/widget/widget_bridge.dart';
import '../ui/flutify_app.dart';
import '../ui/shell/desktop/desktop_window.dart';
import '../ui/widgets/hyper_icons.dart';

bool _savedHyperMaterial(PreferencesStore preferences) {
  try {
    final json = jsonDecode(preferences.appearanceJson);
    return json is Map<String, dynamic> &&
        AppearanceSettings.fromJson(json).glassMaterial == GlassMaterial.hyper;
  } catch (_) {
    return false;
  }
}

Future<Widget> _initializeMockApp(
  ValueChanged<String> reportStage,
  LaunchArgs launchArgs,
) async {
  reportStage('准备 Mock 自测环境');
  await RustCore.initialize();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await OrientationPolicy.apply();

  reportStage('初始化 Mock 数据与本地封面服务');
  final mock = await MockBootstrap.create();

  reportStage('准备窗口');
  await DesktopWindow.init(mock.storageService.preferences);
  DesktopWindow.addBeforeCloseHook(() => mock.coverServer.close());

  final e2eRunner = launchArgs.e2eOutputDir == null
      ? null
      : E2ERunner(
          requestedOutputDir: launchArgs.e2eOutputDir!,
          bootstrap: mock,
          onCompleteExit: (_) async {
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
              await DesktopWindow.quit();
              await Future<void>.delayed(const Duration(milliseconds: 600));
              await ServicesBinding.instance.exitApplication(
                ui.AppExitType.required,
              );
            } else {
              await SystemNavigator.pop();
            }
          },
        );

  return FlutifyApp(
    storageService: mock.storageService,
    audioEngine: mock.audioEngine,
    emePlayer: mock.emePlayer,
    spotifyApiService: mock.spotifyApiService,
    authService: mock.authService,
    webTokenService: WebTokenService(
      mock.storageService.auth,
      MockOfflineHttpClient(),
    ),
    trackAudioLoader: mock.trackAudioLoader,
    playbackSessionStore: mock.playbackSessionStore,
    networkProxy: NetworkProxy.instance,
    audioCacheLocation: mock.audioCacheLocation,
    playbackRegionGate: mock.playbackRegionGate,
    updateService: mock.updateService,
    audioOutputBackend: mock.audioOutputBackend,
    enableConnectReceiver: false,
    e2eRunner: e2eRunner,
  );
}

/// 应用启动依赖装配：依次准备运行环境、持久化存储、网络代理、DRM 音频引擎、媒体控制及缓存目录。
Future<Widget> initializeFlutifyApp(
  ValueChanged<String> reportStage,
  LaunchArgs launchArgs,
) async {
  if (launchArgs.mockMode) {
    return _initializeMockApp(reportStage, launchArgs);
  }
  reportStage('准备运行环境');
  await WindowsTrustStore.initialize();

  // just_audio 自身没有 Windows / Linux 实现，需在创建任何 AudioPlayer 之前
  // 注册 media_kit 后端；Android / iOS 仍使用 just_audio 原生实现。
  JustAudioMediaKit.ensureInitialized();

  // Rust 核心（试点：LRC 解析）；失败时各调用点自动回退到 Dart 实现
  await RustCore.initialize();

  // 系统栏透明、内容铺满（edge-to-edge）；图标深浅由 FlutifyApp 按当前主题设置
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // 手机锁定竖屏（平板 / 桌面不限制）
  await OrientationPolicy.apply();

  reportStage('读取设置');
  final storageService = await StorageService.init();
  // 柔光玻璃的图标要在第一帧之前就位，否则启动时先闪一下 Material 图标
  if (_savedHyperMaterial(storageService.preferences)) {
    await HyperIcons.ensure();
  }
  storageService.auth.clearWebViewCookies = EmePlayer.clearSessionCookies;
  try {
    await storageService.auth.retryCookieCleanup();
  } catch (_) {
    debugPrint('[auth] WebView Cookie 清理未完成，下次登录前重试');
  }
  await CacheDirectoryAccess.restore();

  installMacOSSystemProxyReader();
  installWindowsSystemProxyReader();
  ProxyHttpOverrides.install(NetworkProxy.instance);
  ProxyHttpOverrides.certificateRejectionLogger = debugPrint;
  if (Platform.isWindows) {
    ProxyHttpOverrides.certificateRejectionHandler = (certificate) =>
        unawaited(WindowsTrustStore.learnRootFor(certificate));
  }
  reportStage('配置网络');
  await loadLocalDeviceName();
  final initialPrefs = AppPreferences.decode(
    storageService.preferences.preferencesJson,
  );
  await NetworkProxy.instance
      .configure(
        mode: initialPrefs.proxyMode,
        proxyHost: initialPrefs.proxyHost,
        proxyPort: initialPrefs.proxyPort,
        gateway: initialPrefs.gateway,
        proxyUsername: initialPrefs.proxyUsername,
        proxyPassword: storageService.preferences.proxyPassword,
      )
      .timeout(const Duration(milliseconds: 1500), onTimeout: () {});

  reportStage('初始化音频服务');
  final audioPlayerService = AudioPlayerService();
  final spotifyApiService = SpotifyApiService(storageService.auth);
  final authService = SpotifyAuthService(storageService.auth);

  // --- EME（Widevine）全曲播放链路 ---
  final webTokenService = WebTokenService(storageService.auth);
  final emePlayer = EmePlayer();
  reportStage('启动本地播放服务');
  await emePlayer.init();
  final licenseClient = WidevineLicenseClient(
    client: SessionHttpClient(storageService.auth, http.Client()),
    webToken: webTokenService.ensureWebAccessToken,
    clientToken: authService.ensureClientToken,
  );
  final AudioEngine drmEngine;
  if (Platform.isAndroid) {
    drmEngine = NativeDrmAudioEngine(
      server: emePlayer,
      player: NativeDrmPlayer(),
      licensePoster: licenseClient.postLicense,
      certFetcher: licenseClient.fetchCert,
    );
  } else {
    await EmePlayer.ensureEnvironment();
    final webEngine = EmeAudioEngine(
      player: emePlayer,
      licensePoster: licenseClient.postLicense,
      certFetcher: licenseClient.fetchCert,
      initialize: () async {
        EmePlayer.hlsJsSource = await rootBundle.loadString(
          'assets/js/hls.min.js',
        );
        await EmePlayer.ensureEnvironment();
        await emePlayer.start();
      },
    );
    drmEngine = webEngine;
  }
  final audioEngine = RoutedAudioEngine(
    local: audioPlayerService,
    eme: drmEngine,
  );

  reportStage('读取应用目录');
  final supportDir = await getApplicationSupportDirectory();
  PlaylistBackupService.defaultDiskFile = File(
    '${supportDir.path}${Platform.pathSeparator}playlist_backups.json',
  );
  final legacyArtworkDirectory =
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}libCachedImageData';
  final audioCacheLocation = CacheLocation(
    storageService.cache,
    supportDir.path,
    legacyArtworkDirectory: legacyArtworkDirectory,
  );
  reportStage('准备缓存目录');
  await audioCacheLocation.initialize();
  final artworkCache = ArtworkCache(audioCacheLocation);
  final sessionStore = FilePlaybackSessionStore(
    File('${supportDir.path}${Platform.pathSeparator}playback_session.json'),
  );

  reportStage('准备窗口');
  await DesktopWindow.init(storageService.preferences);
  DesktopWindow.addBeforeCloseHook(EmePlayer.disposeExternalBrowser);

  reportStage('连接系统媒体控制');
  final systemControls = await SystemMediaControls.create(
    artworkFile: (url) async => (await artworkCache.getSingleFile(url)).path,
  );
  final taskbarLyrics = Platform.isWindows
      ? TaskbarLyricsControls(MethodChannelTaskbarLyrics())
      : null;
  final lyricBridge = Platform.isAndroid && systemControls != null
      ? LyricMetadataControls(systemControls, MethodChannelLyricBridge())
      : null;
  final widgetBridge = Platform.isAndroid
      ? WidgetBridge(
          artworkFile: (url) async =>
              (await artworkCache.getSingleFile(url)).path,
        )
      : null;
  final baseControls = lyricBridge ?? systemControls;
  final mediaControls = taskbarLyrics == null
      ? baseControls
      : MultiMediaControls([?baseControls, taskbarLyrics]);

  final lyricsFallback = LrclibLyricsSource(
    LrclibClient(http.Client(), useRustBackend: true),
    cache: LyricsDiskCache(
      audioCacheLocation.lyricsDirectory,
      directoryProvider: () => audioCacheLocation.lyricsDirectory,
      lock: audioCacheLocation.lock,
    ),
  );
  final qqLyricsTranslation = QqTranslationSource(
    QqMusicClient(http.Client(), useRustBackend: true),
    cache: LyricsDiskCache(
      audioCacheLocation.lyricsDirectory,
      directoryProvider: () => audioCacheLocation.lyricsDirectory,
      lock: audioCacheLocation.lock,
    ),
  );
  final lyricsTranslation = NeteaseTranslationSource(
    NeteaseClient(http.Client(), useRustBackend: true),
    cache: LyricsDiskCache(
      audioCacheLocation.lyricsDirectory,
      directoryProvider: () => audioCacheLocation.lyricsDirectory,
      lock: audioCacheLocation.lock,
    ),
  );

  final emeTrackSource = EmeTrackAudioSource(
    client: SessionHttpClient(storageService.auth, http.Client()),
    cacheDirectory: supportDir.path,
    cacheDirectoryProvider: () =>
        audioCacheLocation.rootFor(CacheCategory.audio),
    playingPath: () => emePlayer.currentAudioPath,
    cacheLock: audioCacheLocation.lock,
    webSessionReady: () => webTokenService.hasSpDc,
    accessToken: () async {
      try {
        await authService.ensureAccessToken();
      } catch (_) {}
      return storageService.auth.accessToken;
    },
    clientToken: () => authService.ensureClientToken(),
  );

  audioCacheLocation.audioInUse = emeTrackSource.isCacheFileInUse;
  audioCacheLocation.prepareLegacyArtwork = () =>
      ArtworkCache.prepareLegacy(audioCacheLocation.legacyArtworkDirectory!);
  reportStage('迁移旧缓存');
  await audioCacheLocation.resumeMigrations();
  emeTrackSource.maxCacheBytes =
      storageService.cache.audioCacheLimitMb * 1024 * 1024;
  audioCacheLocation.addListener(() => unawaited(emeTrackSource.trimCache()));
  audioCacheLocation.artworkMaintenance = artworkCache.maintain;
  CachedNetworkImageProvider.defaultCacheManager = artworkCache;

  final playbackRegionGate = PlaybackRegionGate(
    enabled: () => AppPreferences.decode(
      storageService.preferences.preferencesJson,
    ).regionCheckEnabled,
    recheckOnNetworkChange: () => AppPreferences.decode(
      storageService.preferences.preferencesJson,
    ).regionCheckOnNetworkChange,
    skipThisRun: () => LoginRegionCheck.skippedThisRun,
  );
  EmePlayer.environmentReady = playbackRegionGate.attachEnvironment;

  return FlutifyApp(
    storageService: storageService,
    audioEngine: audioEngine,
    emePlayer: emePlayer,
    spotifyApiService: spotifyApiService,
    authService: authService,
    webTokenService: webTokenService,
    trackAudioLoader: emeTrackSource,
    playbackSessionStore: sessionStore,
    mediaControls: mediaControls,
    networkProxy: NetworkProxy.instance,
    audioCacheLocation: audioCacheLocation,
    lyricsFallback: lyricsFallback,
    lyricsTranslation: lyricsTranslation,
    qqLyricsTranslation: qqLyricsTranslation,
    taskbarLyrics: taskbarLyrics,
    lyricBridge: lyricBridge,
    widgetBridge: widgetBridge,
    playbackRegionGate: playbackRegionGate,
    updateService: UpdateService(
      storage: storageService.updates,
      installer: PlatformUpdateInstaller(
        closeWindows: DesktopWindow.closeForUpdate,
      ),
    ),
  );
}
