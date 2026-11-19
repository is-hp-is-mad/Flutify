import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:material_3_expressive/material_3_expressive.dart' show M3ETheme;
import 'package:provider/provider.dart';

import '../core/debug_toggles.dart';
import '../core/perf_flags.dart';
import '../core/render/frame_rate_binding.dart';
import '../core/theme/app_text_scaler.dart';
import '../core/theme/m3e_theme_bridge.dart';
import '../core/theme/md3e_theme.dart';
import '../core/theme/system_bars.dart';
import '../core/utils/local_device_name.dart';
import '../l10n/app_locale.dart';
import '../models/app_preferences.dart';
import '../models/appearance.dart';
import '../models/playback_context.dart';
import '../models/playback_state.dart';
import '../providers/appearance_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/connect_provider.dart';
import '../providers/library_provider.dart';
import '../providers/playback_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/sleep_timer_provider.dart';
import '../providers/spotify_provider.dart';
import '../self_test/e2e_runner.dart';
import '../services/audio/audio_engine.dart';
import '../services/audio/audio_output_service.dart';
import '../services/auth/session_http_client.dart';
import '../services/auth/spotify_auth_service.dart';
import '../services/auth/web_token_service.dart';
import '../services/backup/playlist_backup_service.dart';
import '../services/cache/cache_location.dart';
import '../services/connect/connect_play_request.dart';
import '../services/connect/connect_service.dart';
import '../services/connect/receiver/connect_receiver.dart';
import '../services/connect/receiver/playback_receiver_host.dart';
import '../services/eme/eme_player.dart';
import '../services/updates/update_resume.dart';
import '../services/lyric_bridge/lyric_metadata_controls.dart';
import '../services/lyrics/lrclib_lyrics_source.dart';
import '../services/lyrics/lyrics_resolver.dart';
import '../services/lyrics/netease_translation_source.dart';
import '../services/lyrics/qq_translation_source.dart';
import '../services/media_controls/connect_media_source.dart';
import '../services/media_controls/media_controls_sync.dart';
import '../services/media_controls/system_media_controls.dart';
import '../services/network/network_proxy.dart';
import '../services/playback/playback_region_gate.dart';
import '../services/playback_session_store.dart';
import '../services/protocol/audio_cache_store.dart';
import '../services/protocol/track_audio_loader.dart';
import '../services/spotify_api_service.dart';
import '../services/storage_service.dart';
import '../services/taskbar_lyrics/taskbar_lyrics_controls.dart';
import '../services/updates/update_service.dart';
import '../services/widget/widget_bridge.dart';
import 'navigation/app_routes.dart';
import 'screens/main_shell.dart';
import 'shell/desktop/desktop_window.dart';
import 'shell/desktop/mac_menu_bar.dart';
import 'shell/desktop/window_frame.dart';
import 'widgets/automatic_gateway_binding.dart';
import 'widgets/dynamic_accent_sync.dart';
import 'widgets/hyper_surface.dart';
import 'widgets/lyric_bridge_binding.dart';
import 'widgets/playback_session_keeper.dart';
import 'widgets/taskbar_lyrics_binding.dart';
import 'widgets/update_prompt.dart';

class FlutifyApp extends StatelessWidget {
  final StorageService storageService;
  final AudioEngine audioEngine;

  /// EME 播放器（无头 WebView2，不进 widget 树）。
  final EmePlayer emePlayer;
  final SpotifyApiService spotifyApiService;

  /// Login5 鉴权服务；为空时按 [storageService] 默认创建（测试可注入假实现）。
  final SpotifyAuthService? authService;

  /// Web token 服务（sp_dc + TOTP 铸 Web access_token）；为空时设置页不显示 Web 登录入口（测试默认）。
  final WebTokenService? webTokenService;

  /// 完整曲目音频来源（协议链路）；为空时任何曲目都无法播放（PlaybackProvider 报「请先登录」）。
  final TrackAudioSource? trackAudioLoader;

  /// 上次播放会话的存储；为空时不还原、不保存（测试默认）。
  final PlaybackSessionStore? playbackSessionStore;

  /// 系统媒体控制；为空时不接入（测试、不支持的平台）。
  final SystemMediaControls? mediaControls;

  /// 网络代理策略；为空时设置页只显示模式、不探测系统代理（测试默认）。
  final NetworkProxy? networkProxy;
  final CacheLocation? audioCacheLocation;

  /// LRCLIB 歌词补全；为空时只用 Spotify 官方歌词（测试默认）。
  final LrclibLyricsSource? lyricsFallback;

  /// 网易云歌词译文兜底；为空时不查网易云（测试默认）。
  final NeteaseTranslationSource? lyricsTranslation;

  /// QQ 歌词译文，优先于网易云；为空时不查询 QQ（测试默认）。
  final QqTranslationSource? qqLyricsTranslation;

  /// 任务栏歌词（Windows）；已包含在 [mediaControls] 里，这里供界面层绑定设置与歌词来源。
  final TaskbarLyricsControls? taskbarLyrics;

  /// 蓝牙（车机）歌词 / Flyme 状态栏歌词（Android）；已包含在 [mediaControls] 里，这里供界面层绑定。
  final LyricMetadataControls? lyricBridge;

  /// Android 桌面小组件桥：与媒体控制同一差异同步点，把播放态推给原生 Glance widget；非 Android 为 null。
  final WidgetBridge? widgetBridge;

  /// 起播前的网络出口地区门控；为空时不做地区检测（测试默认）。
  final PlaybackRegionGate? playbackRegionGate;
  final UpdateService? updateService;
  final AudioOutputBackend? audioOutputBackend;
  final bool enableConnectReceiver;
  final E2ERunner? e2eRunner;

  const FlutifyApp({
    super.key,
    required this.storageService,
    required this.audioEngine,
    required this.emePlayer,
    required this.spotifyApiService,
    this.authService,
    this.webTokenService,
    this.trackAudioLoader,
    this.playbackSessionStore,
    this.mediaControls,
    this.networkProxy,
    this.audioCacheLocation,
    this.lyricsFallback,
    this.lyricsTranslation,
    this.qqLyricsTranslation,
    this.taskbarLyrics,
    this.lyricBridge,
    this.widgetBridge,
    this.playbackRegionGate,
    this.updateService,
    this.audioOutputBackend,
    this.enableConnectReceiver = true,
    this.e2eRunner,
  });

  /// 更新后续播：点「安装更新」时正在播放就保存会话并记标记；新版本启动后（已登录、有上次曲目）自动开始播放。
  void _wireResumeAfterUpdate(PlaybackProvider playback, SpotifyAuthService auth) {
    final resume = UpdateResume(storageService.updates);
    updateService?.beforeInstall = () async {
      if (!playback.isPlaybackActive) return;
      await playback.flushSession();
      await resume.mark();
      debugPrint('[Updates] 更新前正在播放：已记下，更新后自动续播');
    };
    unawaited(
      resume.consume().then((shouldResume) {
        if (!shouldResume) return;
        // 首帧之后再播：音频引擎、EME 页面与登录态都已就绪
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!auth.isLoggedIn ||
              playback.currentTrack == null ||
              playback.isPlaybackActive) {
            return;
          }
          debugPrint('[playback] 更新前在播放：自动续播');
          unawaited(playback.togglePlayPause());
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    MediaControlsSync? mediaSync;
    return MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storageService),
        Provider<AuthSessionStore>.value(value: storageService.auth),
        Provider<PreferencesStore>.value(value: storageService.preferences),
        Provider<PlaybackPrefsStore>.value(value: storageService.playback),
        Provider<CachePrefsStore>.value(value: storageService.cache),
        Provider<LibraryCacheStore>.value(value: storageService.library),
        Provider<UpdateStateStore>.value(value: storageService.updates),
        ListenableProvider<UpdateService?>.value(value: updateService),
        Provider<AudioEngine>.value(value: audioEngine),
        Provider<EmePlayer>.value(value: emePlayer),
        Provider<SpotifyApiService>.value(value: spotifyApiService),
        if (webTokenService != null)
          Provider<WebTokenService>.value(value: webTokenService!),
        Provider<NetworkProxy?>.value(value: networkProxy),
        ListenableProvider<CacheLocation?>.value(value: audioCacheLocation),
        Provider<SpotifyAuthService>(
          lazy: false,
          create: (_) {
            final auth =
                authService ?? SpotifyAuthService(storageService.auth);
            spotifyApiService.attachAuth(auth);
            DesktopWindow.addBeforeCloseHook(
              auth.settle,
              timeout: const Duration(seconds: 5),
            );
            return auth;
          },
        ),
        ChangeNotifierProvider(
          create: (ctx) {
            final playback = PlaybackProvider(
              audioEngine,
              storageService.playback,
              audioLoader: trackAudioLoader,
              sessionStore: playbackSessionStore,
              regionGate: playbackRegionGate,
              defaultRepeatMode: AppPreferences.decode(
                storageService.preferences.preferencesJson,
              ).defaultRepeatMode,
            );
            playback.autoplaySource = (seed) async {
              final radio = await spotifyApiService.getSongRadio(seed);
              final full = await spotifyApiService.getPlaylist(radio.id);
              return (
                tracks: full.tracks,
                context: PlaybackContext.playlist(
                  full.name.isNotEmpty ? full.name : seed.name,
                  uri: full.uri.isNotEmpty
                      ? full.uri
                      : 'spotify:playlist:${radio.id}',
                ),
              );
            };
            DesktopWindow.addBeforeCloseHook(playback.flushSession);
            _wireResumeAfterUpdate(playback, ctx.read<SpotifyAuthService>());
            final controls = mediaControls;
            if (controls != null) {
              mediaSync = MediaControlsSync(
                playback,
                controls,
                widget: widgetBridge,
              );
            }
            return playback;
          },
        ),
        ChangeNotifierProvider(
          create: (ctx) => SleepTimerProvider(ctx.read<PlaybackProvider>()),
        ),
        ChangeNotifierProvider(
          create: (_) => LibraryProvider(
            storageService.library,
            source: spotifyApiService.library,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => AppearanceProvider(storageService.preferences),
        ),
        ChangeNotifierProvider(
          create: (_) {
            final preferences = PreferencesProvider(storageService.preferences);
            final bridge = widgetBridge;
            if (bridge != null) {
              unawaited(bridge.syncLanguage(preferences.prefs.language));
              preferences.addListener(
                () =>
                    unawaited(bridge.syncLanguage(preferences.prefs.language)),
              );
            }
            final proxy = networkProxy;
            if (proxy == null) return preferences;
            var proxyKey = _proxyKey(preferences.prefs);
            preferences.addListener(() {
              final key = _proxyKey(preferences.prefs);
              if (key == proxyKey) return;
              proxyKey = key;
              unawaited(
                proxy.configure(
                  mode: preferences.prefs.proxyMode,
                  proxyHost: preferences.prefs.proxyHost,
                  proxyPort: preferences.prefs.proxyPort,
                  gateway: preferences.prefs.gateway,
                  proxyUsername: preferences.prefs.proxyUsername,
                  proxyPassword: storageService.preferences.proxyPassword,
                ),
              );
            });
            return preferences;
          },
        ),
        ChangeNotifierProvider(
          create: (ctx) => PlaylistBackupService(
            storageService.auth,
            storageService.preferences,
            storageService.library,
            library: ctx.read<LibraryProvider>(),
            preferences: ctx.read<PreferencesProvider>(),
            apiService: spotifyApiService,
          ),
        ),
        ChangeNotifierProvider(
          create: (ctx) {
            final preferences = ctx.read<PreferencesProvider>();
            final spotify = SpotifyProvider(
              spotifyApiService,
              storageService.library,
              lyrics: LyricsResolver(
                spotifyApiService.getLyrics,
                fallback: lyricsFallback,
                fallbackEnabled: () => preferences.prefs.lyricsFallback,
                translation: lyricsTranslation,
                qqTranslation: qqLyricsTranslation,
                translationEnabled: () => preferences.prefs.lyricsBilingual,
                sourceOrder: () => preferences.prefs.lyricsSourceOrder,
              ),
            );
            var bilingual = preferences.prefs.lyricsBilingual;
            var sourceOrder = preferences.prefs.lyricsSourceOrder;
            preferences.addListener(() {
              final enabled = preferences.prefs.lyricsBilingual;
              final order = preferences.prefs.lyricsSourceOrder;
              final orderChanged = !listEquals(order, sourceOrder);
              sourceOrder = order;
              if (enabled == bilingual && !orderChanged) return;
              final turnedOn = enabled && !bilingual;
              bilingual = enabled;
              if (turnedOn || orderChanged) spotify.invalidateResolvedLyrics();
            });
            return spotify;
          },
        ),
        ChangeNotifierProvider<AudioOutputService?>(
          lazy: false,
          create: (context) {
            if (!AudioOutputService.platformSupported) return null;
            final preferences = context.read<PreferencesProvider>();
            return AudioOutputService(
              audioOutputBackend ?? MediaKitAudioOutputBackend(),
              initial: preferences.prefs.audioOutputDevice,
              onSelected: (id) => preferences.update(
                preferences.prefs.copyWith(audioOutputDevice: id),
              ),
              labelSink: (label) =>
                  unawaited(EmePlayer.setOutputDeviceLabel(label)),
            );
          },
        ),
        Provider<TaskbarLyricsControls?>.value(value: taskbarLyrics),
        Provider<LyricMetadataControls?>.value(value: lyricBridge),
        Provider<WidgetBridge?>.value(value: widgetBridge),
        Provider<AudioCacheStore?>.value(
          value: trackAudioLoader is AudioCacheStore
              ? trackAudioLoader as AudioCacheStore
              : null,
        ),
        ChangeNotifierProvider(
          lazy: false,
          create: (ctx) {
            final playback = ctx.read<PlaybackProvider>();
            final connect = ConnectProvider(
              spotifyApiService.connect,
              available: () =>
                  spotifyApiService.supportsConnect &&
                  ctx.read<PreferencesProvider>().prefs.connectEnabled,
              resolveTrack: spotifyApiService.getTrackByUri,
            );
            mediaSync?.override = ConnectMediaSource(connect, playback);
            playback.addListener(() {
              if (playback.isPlaying) connect.localPlaybackStarted();
            });
            playback.remotePlay = (context, tracks, start) async {
              final remote = connect.controlsRemote(
                localPlaying: playback.isPlaying,
                localHasTrack: playback.currentTrack != null,
              );
              debugPrint(
                '[Connect] 点歌：request=${remote ? 'remote' : 'ok'} '
                'active=${connect.activeDevice?.name} '
                'localPlaying=${playback.isPlaying} '
                'receiverOnline=${connect.receiverOnline}',
              );
              if (!remote && !connect.receiverOnline) {
                debugPrint(
                  '[Connect] 本机播放端不在设备列表（${connect.receiverDeviceId}），列表：'
                  '${connect.devices.map((d) => '${d.name}:${d.id}').join(', ')}',
                );
                return false;
              }
              final request = ConnectPlayRequest.from(
                context: context,
                tracks: tracks,
                start: start,
                username: ctx.read<SpotifyAuthService>().username,
              );
              if (request == null) return false;
              if (!remote) {
                final ticket = playback.prepareReceiverQueue(
                  context,
                  tracks,
                  start,
                );
                try {
                  final repeat =
                      ctx.read<PreferencesProvider>().prefs.defaultRepeatMode;
                  await connect.playOnReceiver(
                    request,
                    repeatingContext: repeat != SpotifyRepeatMode.off,
                    repeatingTrack: repeat == SpotifyRepeatMode.track,
                  );
                  return true;
                } on ConnectException catch (e) {
                  playback.cancelReceiverQueue(ticket);
                  debugPrint('[Connect] 播放端启动失败，改在本机播放：$e');
                  return false;
                }
              }
              try {
                await connect.play(request);
                return true;
              } on ConnectException catch (e) {
                debugPrint('[Connect] 远程播放失败，改在本机播放：$e');
                return false;
              }
            };
            if (enableConnectReceiver) {
              _startConnectReceiver(ctx, connect, playback);
            } else {
              connect.receiverDeviceId =
                  ctx.read<AuthSessionStore>().receiverDeviceId;
            }
            return connect;
          },
        ),
        ChangeNotifierProvider(
          create: (ctx) {
            late final AuthProvider auth;
            auth = AuthProvider(ctx.read<SpotifyAuthService>())
              ..onSessionChanged = () {
                ctx.read<SpotifyProvider>().loadInitialData();
                ctx.read<LibraryProvider>().refresh();
                ctx.read<ConnectProvider>().sessionChanged();
                if (!auth.isSignedIn) {
                  unawaited(ctx.read<PlaybackProvider>().discardSession());
                }
              };
            return auth;
          },
        ),
      ],
      child: PlaybackSessionKeeper(
        child: AutomaticGatewayBinding(
          regionGate: playbackRegionGate,
          child: DynamicAccentSync(child: _ThemedApp(e2eRunner: e2eRunner)),
        ),
      ),
    );
  }
}

void _startConnectReceiver(
  BuildContext ctx,
  ConnectProvider connect,
  PlaybackProvider playback,
) {
  final tokens = ctx.read<WebTokenService?>();
  if (tokens == null) return;
  final preferences = ctx.read<PreferencesProvider>();
  final deviceId = ctx.read<AuthSessionStore>().receiverDeviceId;
  final host = PlaybackReceiverHost(playback);
  String nameOf() {
    final name = preferences.prefs.connectDeviceName;
    if (name.isNotEmpty) return name;
    return cachedLocalDeviceName.isNotEmpty
        ? cachedLocalDeviceName
        : ConnectReceiver.defaultDeviceName;
  }

  final receiver = ConnectReceiver(
    host: host,
    deviceName: nameOf,
    client: SessionHttpClient(ctx.read<AuthSessionStore>(), http.Client()),
    webToken: tokens.ensureWebAccessToken,
    deviceId: deviceId,
  );
  host.receiver = receiver;
  connect.receiverDeviceId = deviceId;
  Future<bool> handOver(int positionMs, {bool paused = false}) async {
    final current = playback.currentTrack;
    if (current == null || !connect.receiverOnline) return false;
    var context = playback.playbackContext;
    final clusterContext = connect.player.contextUri;
    if (context.uri.isEmpty &&
        clusterContext.isNotEmpty &&
        receiver.hasTrack(current.uri)) {
      context = PlaybackContext.fromUri(clusterContext);
    }
    final request = ConnectPlayRequest.from(
      context: context,
      tracks: [current, for (final e in playback.upNext) e.track],
      start: current,
      username: ctx.read<SpotifyAuthService>().username,
    );
    if (request == null) return false;
    debugPrint(
      '[Receiver] 交接给 Connect：${current.name} @${positionMs}ms paused=$paused',
    );
    final repeat = playback.repeatMode;
    try {
      await connect.playOnReceiver(
        request,
        seekToMs: positionMs,
        paused: paused,
        repeatingContext: repeat != SpotifyRepeatMode.off,
        repeatingTrack: repeat == SpotifyRepeatMode.track,
      );
      return true;
    } catch (e) {
      debugPrint('[Receiver] 交接失败：$e');
      return false;
    }
  }

  host.handOver = handOver;
  connect.addListener(() {
    if (!receiver.isActive || connect.cluster.activeDeviceId != deviceId) return;
    final current = playback.currentTrack;
    if (current == null || !receiver.hasTrack(current.uri)) return;
    playback.adoptReceiverContext(connect.player.contextUri);
  });
  host.onLocalOptions = ({shuffle, repeatContext, repeatTrack}) =>
      connect.setReceiverOptions(
        shuffle: shuffle,
        repeatContext: repeatContext,
        repeatTrack: repeatTrack,
      );

  var launchSynced = false;
  receiver.onRegistered = () async {
    try {
      await connect.refresh();
    } on ConnectException catch (_) {}
    host.onReceiverRegistered();
    if (launchSynced || !preferences.prefs.connectReportOnLaunch) return;
    launchSynced = true;
    for (var i = 0; i < 20 && !connect.receiverOnline; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    final remoteAudible =
        connect.activeDevice != null && connect.player.isAudible;
    if (playback.isPlaying || receiver.isActive || remoteAudible) return;
    await handOver(playback.position.inMilliseconds, paused: true);
  };

  var running = false;
  var name = nameOf();
  void apply() {
    final want = tokens.hasSpDc && preferences.prefs.connectEnabled;
    if (running && want && nameOf() != name) {
      name = nameOf();
      unawaited(receiver.stop().then((_) => receiver.start()));
      return;
    }
    name = nameOf();
    if (want == running) return;
    running = want;
    unawaited(want ? receiver.start() : receiver.stop());
  }

  preferences.addListener(apply);
  tokens.sessionInvalidated.addListener(() {
    receiver.invalidateSession();
    apply();
  });
  apply();
  DesktopWindow.addBeforeCloseHook(
    receiver.stop,
    timeout: const Duration(seconds: 3),
  );
}

Object _proxyKey(AppPreferences prefs) => (
  prefs.proxyMode,
  prefs.proxyHost,
  prefs.proxyPort,
  prefs.proxyUsername,
  prefs.gateway,
);

final bool _excludeWindowsSemantics =
    Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

void _onMouseNavigation(PointerDownEvent event) {
  if (event.buttons & kBackMouseButton != 0) {
    AppRoutes.navigateBack?.call();
  } else if (event.buttons & kForwardMouseButton != 0) {
    AppRoutes.navigateForward?.call();
  }
}

class _ThemedApp extends StatelessWidget {
  final E2ERunner? e2eRunner;

  const _ThemedApp({this.e2eRunner});

  @override
  Widget build(BuildContext context) {
    final appearance = context.watch<AppearanceProvider>();
    final settings = appearance.settings;
    FrameRateBinding.maybeInstance?.frameRateLimit = settings.frameRateLimit;
    if (settings.glassMaterial == GlassMaterial.hyper) warmUpHyperGlass();
    final language = context.select<PreferencesProvider, AppLanguage>(
      (p) => p.prefs.language,
    );

    return E2ERootOverlay(
      runner: e2eRunner,
      child: MaterialApp(
        title: 'Flutify',
        debugShowCheckedModeBanner: false,
        showPerformanceOverlay: PerfFlags.overlay,
        scrollBehavior: settings.glassMaterial == GlassMaterial.hyper
            ? const HyperScrollBehavior()
            : const MaterialScrollBehavior(),
        locale: AppLocale.localeFor(language),
        supportedLocales: AppLocale.supportedLocales,
        localizationsDelegates: AppLocale.delegates,
        themeMode: settings.themeMode,
        darkTheme: appearance.theme(Brightness.dark),
        theme: appearance.theme(Brightness.light),
        themeAnimationDuration: Duration.zero,
        builder: (context, child) {
          AppLocale.resolved(Localizations.localeOf(context));
          final media = MediaQuery.of(context);
          return M3ETheme(
            data: m3eThemeFrom(Theme.of(context)),
            child: DebugTogglesBinding(
              builder: (context, motionOff) {
                return MediaQuery(
                  data: media.copyWith(
                    textScaler: AppTextScaler(
                      media.textScaler,
                      settings.fontScale,
                    ),
                    disableAnimations:
                        media.disableAnimations ||
                        settings.reduceMotion ||
                        motionOff,
                  ),
                  child: AnnotatedRegion<SystemUiOverlayStyle>(
                    value: systemBarsStyle(Theme.of(context).brightness),
                    child: ExcludeSemantics(
                      excluding: _excludeWindowsSemantics,
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: _onMouseNavigation,
                        child: MacMenuBar(
                          child: TaskbarLyricsBinding(
                            child: LyricBridgeBinding(
                              child: E2ERunner.wrapRepaintBoundary(
                                runner: e2eRunner,
                                child: WindowFrame(
                                  child: HyperGlassWarmup(child: child!),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
        home: const UpdatePromptBinding(child: MainShell()),
      ),
    );
  }
}
