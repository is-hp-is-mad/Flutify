import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../models/playback_retry.dart';
import '../../providers/playback_provider.dart';
import '../../services/audio/audio_engine.dart';
import '../../services/eme/fairplay.dart';
import '../../services/protocol/track_playback_exception.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/web_login_screen.dart';
import 'toast/app_toast.dart';

/// 订阅 [PlaybackProvider.playbackErrors]，每次播放失败弹一条 [AppToast]。
///
/// - 未登录：提示登录，并带「登录」按钮；
/// - 不可播放：说明哪首歌不能播放、是否已自动跳过；连续多首失败已自动暂停时带「下一首」；
/// - 网络错误：提示检查网络，带「重试」按钮（重新播放当前曲目）。
///
/// 放在 [MainShell] 的 Scaffold 之内，桌面与移动端共用。
class PlaybackErrorListener extends StatefulWidget {
  final Widget child;

  const PlaybackErrorListener({super.key, required this.child});

  @override
  State<PlaybackErrorListener> createState() => _PlaybackErrorListenerState();
}

class _PlaybackErrorListenerState extends State<PlaybackErrorListener> {
  StreamSubscription<PlaybackError>? _subscription;
  late PlaybackProvider _playback;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _retryToast;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackProvider>();
    _subscription = _playback.playbackErrors.listen(_show);
    _playback.retryNotifier.addListener(_showRetry);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _playback.retryNotifier.removeListener(_showRetry);
    super.dispose();
  }

  void _showRetry() {
    if (!mounted) return;
    _retryToast?.close();
    _retryToast = null;
    final retry = _playback.retryNotifier.value;
    if (retry == null) return;
    final l10n = context.l10n;
    _retryToast = AppToast.show(
      context,
      retry.waiting
          ? l10n.playbackRetryWaiting(
              retry.attempt,
              PlaybackRetry.limit,
              retry.delay.inSeconds,
            )
          : l10n.playbackRetryRunning(retry.attempt, PlaybackRetry.limit),
      icon: Icons.wifi_off_rounded,
      actionLabel: l10n.commonCancel,
      onAction: _playback.pause,
      duration: retry.waiting
          ? retry.delay + const Duration(seconds: 1)
          : const Duration(minutes: 1),
    );
  }

  /// 打开统一登录页（Web 登录 + 无感桌面授权）；成功后提示并重试播放当前曲目。
  Future<void> _openWebLogin(PlaybackProvider playback) async {
    final result = await WebLoginScreen.open(context);
    if (!mounted || !(result?.webSignedIn ?? false)) return;
    AppToast.show(
      context,
      context.l10n.webLoginSuccess,
      icon: Icons.check_circle_rounded,
      tone: ToastTone.success,
    );
    await playback.togglePlayPause();
  }

  void _show(PlaybackError error) {
    if (!mounted) return;
    // 播放器还在这首歌上退避重放（「正在重试」提示条已经说明了情况）：
    // 这次不弹错误条，免得一断流就盖住重试提示。
    if (error.retryable) return;
    final l10n = context.l10n;
    final track = error.track.name;
    final playback = context.read<PlaybackProvider>();

    final (
      String message,
      IconData icon,
      ToastTone tone,
      String? actionLabel,
      VoidCallback? onAction,
    ) = switch (error.kind) {
      // 连续多首不可播放、已按设置暂停：给「下一首」让用户手动继续
      TrackPlaybackFailure.unavailable when error.autoPaused => (
        l10n.playbackErrorAutoPaused(error.consecutiveFailures),
        Icons.pause_circle_rounded,
        ToastTone.warning,
        l10n.playerNext,
        playback.nextTrack,
      ),
      TrackPlaybackFailure.notSignedIn => (
        l10n.playbackErrorSignIn,
        Icons.lock_rounded,
        ToastTone.info,
        l10n.shellSignIn,
        () => LoginScreen.open(context),
      ),
      // 缺 sp_dc（Web 登录态）：引导完成 Web 登录，成功后即可重试播放
      TrackPlaybackFailure.webSignInRequired => (
        l10n.playbackErrorWebSignIn,
        Icons.key_rounded,
        ToastTone.info,
        l10n.webLoginAction,
        () => _openWebLogin(playback),
      ),
      TrackPlaybackFailure.unavailable => (
        error.skipped
            ? l10n.playbackErrorSkipped(track)
            : l10n.playbackErrorUnavailable(track),
        Icons.music_off_rounded,
        ToastTone.warning,
        null,
        null,
      ),
      // 设备缺 DRM / CDM（Windows 是 Widevine，macOS / iOS 是 FairPlay）：解密无从谈起，重试无意义，只提示
      TrackPlaybackFailure.network when _isDrmMissing(error) => (
        useFairPlay
            ? l10n.playbackErrorFairPlay(track)
            : l10n.playbackErrorWidevine(track),
        Icons.shield_outlined,
        ToastTone.error,
        null,
        null,
      ),
      TrackPlaybackFailure.network => (
        l10n.playbackErrorNetwork(track),
        Icons.wifi_off_rounded,
        ToastTone.error,
        l10n.commonRetry,
        playback.togglePlayPause,
      ),
    };

    // 连续跳过多首时 AppToast 只保留最新一条，不排队刷屏
    AppToast.show(
      context,
      message,
      icon: icon,
      tone: tone,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  /// 本次失败是不是「设备缺 DRM / CDM」（EME 引擎错误归类标记，
  /// Windows 缺 Widevine、macOS 缺 FairPlay 都走这个 flag）。
  bool _isDrmMissing(PlaybackError error) {
    final cause = error.exception.cause;
    return cause is EmePlaybackException && cause.isWidevineMissing;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
