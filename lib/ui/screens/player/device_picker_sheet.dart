import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../../providers/connect_provider.dart';
import '../../../providers/playback_provider.dart';
import '../../../services/audio/audio_engine.dart';
import '../../../services/audio/audio_output_service.dart';
import '../../widgets/toast/app_toast.dart';
import '../../../services/connect/connect_service.dart' show ConnectStatus;
import '../../shell/shell_breakpoints.dart';
import '../../widgets/connect/connect_actions.dart';
import '../../widgets/connect/connect_device_icon.dart';
import '../../widgets/connect/equalizer_bars.dart';
import '../../widgets/flutify_progress.dart';

/// 「连接到设备」面板（Spotify Connect 遥控）。
///
/// - 桌面端：贴在播放栏右下方的浮层（与官方桌面端位置一致）；移动端：底部面板；
/// - 顶部为「当前收听设备」卡片：远程设备在用时显示它的名字、跳动音柱与音量滑块，否则为「此设备」；
/// - 下方列出其他设备：点按转移播放；远程在用时额外提供「此设备」（暂停远程、本机从同一进度继续）；
/// - 非桌面版会话、连接中、断线、没有其他设备时各有说明。
class DevicePickerSheet extends StatelessWidget {
  const DevicePickerSheet({super.key});

  /// 桌面浮层宽度。
  static const double panelWidth = 360;

  static Future<void> show(BuildContext context) {
    context.read<ConnectProvider?>()?.refresh();
    if (ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width)) {
      final tokens = context.tokens;
      return showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierColor: Colors.black26,
        builder: (dialogContext) => Dialog(
          alignment: Alignment.bottomRight,
          // 贴在播放栏（90）之上、右侧留白与播放栏内边距一致
          insetPadding: const EdgeInsets.fromLTRB(24, 24, 16, 100),
          backgroundColor: Theme.of(
            dialogContext,
          ).colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(borderRadius: tokens.radius(24)),
          clipBehavior: Clip.antiAlias,
          child: const SizedBox(width: panelWidth, child: DevicePickerSheet()),
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const DevicePickerSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final connect = context.watch<ConnectProvider?>();
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.deviceConnectTitle,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              if (connect == null || !connect.available)
                _Notice(
                  icon: Icons.devices_rounded,
                  title: l10n.connectUnavailable,
                )
              else
                _DeviceList(connect: connect),
              // 本机播放时可切换本机音频输出设备（远程设备在放时不相关）
              if (!(connect?.hasRemoteSession ?? false))
                const _LocalOutputSection(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 已接入 Connect 时的内容：当前设备卡片 + 其他设备列表 / 状态说明。
class _DeviceList extends StatelessWidget {
  final ConnectProvider connect;

  const _DeviceList({required this.connect});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final active = connect.activeDevice;
    final remoteInUse = connect.hasRemoteSession;
    final others = connect.devices
        .where((d) => d.id != active?.id && d.canPlay)
        .toList();

    final status = switch (connect.status) {
      ConnectStatus.connecting || ConnectStatus.idle => l10n.connectConnecting,
      ConnectStatus.offline => l10n.connectOffline,
      ConnectStatus.online => null,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CurrentDeviceCard(connect: connect),
        if (status != null) ...[
          const SizedBox(height: 12),
          _StatusLine(
            text: status,
            busy: connect.status != ConnectStatus.offline,
          ),
        ],
        const SizedBox(height: 20),
        if (remoteInUse || others.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              l10n.connectOtherDevices,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (remoteInUse)
          _DeviceTile(
            icon: Icons.computer_rounded,
            title: l10n.connectThisDevice,
            subtitle: l10n.connectTakeOver,
            onTap: () {
              Navigator.of(context).pop();
              ConnectActions.takeOver(context);
            },
          ),
        for (final device in others)
          _DeviceTile(
            icon: connectDeviceIcon(device.type),
            title: device.name,
            subtitle: device.isSameNetwork
                ? l10n.connectSameNetwork
                : l10n.deviceSpotifyConnect,
            onTap: () {
              Navigator.of(context).pop();
              ConnectActions.transferTo(context, device);
            },
          ),
        if (!remoteInUse &&
            others.isEmpty &&
            connect.status == ConnectStatus.online)
          _Notice(
            icon: Icons.devices_other_rounded,
            title: l10n.connectNoDevices,
            subtitle: l10n.connectNoDevicesHint,
          ),
      ],
    );
  }
}

/// 「当前收听设备」卡片：强调色色调容器 + 设备徽章 + 名称 / 曲目 + 音柱；远程设备支持时附音量滑块。
class _CurrentDeviceCard extends StatelessWidget {
  final ConnectProvider connect;

  const _CurrentDeviceCard({required this.connect});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final l10n = context.l10n;
    final remote = connect.hasRemoteSession ? connect.activeDevice : null;
    final localPlaying = context.select<PlaybackProvider, bool>(
      (p) => p.isPlaying,
    );
    final playing = remote != null ? connect.player.isAudible : localPlaying;
    final nowPlaying = remote != null
        ? (connect.remoteTrack?.name ?? connect.player.title)
        : '';
    final accent = tokens.accent;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withAlpha(30),
          theme.colorScheme.surfaceContainerHighest,
        ),
        borderRadius: tokens.radius(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: tokens.radius(16),
                ),
                child: Icon(
                  remote != null
                      ? connectDeviceIcon(remote.type)
                      : Icons.computer_rounded,
                  color: tokens.onAccent,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.deviceCurrent,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      remote?.name ?? l10n.connectThisDevice,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (nowPlaying.isNotEmpty)
                      Text(
                        nowPlaying,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              EqualizerBars(playing: playing, color: accent, size: 18),
            ],
          ),
          if (remote != null && remote.supportsVolume) ...[
            const SizedBox(height: 10),
            _RemoteVolume(connect: connect),
          ],
        ],
      ),
    );
  }
}

/// 远程设备音量：拖动时本地即时生效，请求由 Provider 节流。
class _RemoteVolume extends StatelessWidget {
  final ConnectProvider connect;

  const _RemoteVolume({required this.connect});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final volume = connect.volume;
    return Row(
      children: [
        Icon(
          volume == 0
              ? Icons.volume_off_rounded
              : (volume < 0.5
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded),
          size: 20,
          color: colorScheme.onSurfaceVariant,
        ),
        Expanded(
          child: Slider(
            value: volume,
            semanticFormatterCallback: (v) =>
                '${context.l10n.connectVolume} ${(v * 100).round()}%',
            onChanged: connect.setVolume,
          ),
        ),
      ],
    );
  }
}

/// 设备行：图标徽章 + 名称 + 副标题；整行可点。
class _DeviceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  /// 选中态（本机输出设备）：徽章换强调色。
  final bool selected;

  const _DeviceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    return InkWell(
      borderRadius: tokens.radius(16),
      mouseCursor: SystemMouseCursors.click,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: selected
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 20,
                color: selected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: selected ? theme.colorScheme.primary : null,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 连接中 / 断线的一行状态。
class _StatusLine extends StatelessWidget {
  final String text;
  final bool busy;

  const _StatusLine({required this.text, required this.busy});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox.square(
          dimension: 14,
          child: busy
              ? const FlutifySpinner(size: 14)
              : Icon(
                  Icons.cloud_off_rounded,
                  size: 14,
                  color: theme.colorScheme.error,
                ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// 说明块：图标 + 标题 + 可选副标题（未接入、没有其他设备）。
class _Notice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const _Notice({required this.icon, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 嵌在播放器控制卡片底部的设备列表（类似 Apple 控制中心的设备区域）：
/// 当前收听设备 + 其他设备，点按直接转移播放并收起，不再弹出浮层。
class InlineDevicePanel extends StatelessWidget {
  final VoidCallback onClose;

  const InlineDevicePanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connect = context.watch<ConnectProvider?>();
    if (connect == null || !connect.available) {
      return _InlineRow(
        icon: Icons.devices_rounded,
        title: l10n.connectUnavailable,
      );
    }
    final active = connect.activeDevice;
    final remote = connect.hasRemoteSession ? active : null;
    final others = connect.devices
        .where((d) => d.id != active?.id && d.canPlay)
        .toList();
    final localPlaying = context.select<PlaybackProvider, bool>(
      (p) => p.isPlaying,
    );
    final playing = remote != null ? connect.player.isAudible : localPlaying;
    final accent = context.tokens.accent;
    final status = switch (connect.status) {
      ConnectStatus.connecting || ConnectStatus.idle => l10n.connectConnecting,
      ConnectStatus.offline => l10n.connectOffline,
      ConnectStatus.online => null,
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 190),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _InlineRow(
              icon: remote != null
                  ? connectDeviceIcon(remote.type)
                  : Icons.computer_rounded,
              title: remote?.name ?? l10n.connectThisDevice,
              subtitle: l10n.deviceCurrent,
              highlight: accent,
              trailing: EqualizerBars(
                playing: playing,
                color: accent,
                size: 14,
              ),
            ),
            if (status != null)
              _InlineRow(icon: Icons.sync_rounded, title: status),
            if (remote != null)
              _InlineRow(
                icon: Icons.computer_rounded,
                title: l10n.connectThisDevice,
                subtitle: l10n.connectTakeOver,
                onTap: () {
                  ConnectActions.takeOver(context);
                  onClose();
                },
              ),
            for (final device in others)
              _InlineRow(
                icon: connectDeviceIcon(device.type),
                title: device.name,
                subtitle: device.isSameNetwork
                    ? l10n.connectSameNetwork
                    : l10n.deviceSpotifyConnect,
                onTap: () {
                  ConnectActions.transferTo(context, device);
                  onClose();
                },
              ),
            if (remote == null &&
                others.isEmpty &&
                connect.status == ConnectStatus.online)
              _InlineRow(
                icon: Icons.devices_other_rounded,
                title: l10n.connectNoDevices,
              ),
          ],
        ),
      ),
    );
  }
}

/// 内嵌设备列表的一行：小图标徽章 + 名称 + 副标题（白字，跟随播放器的深色背景）。
class _InlineRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? highlight;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _InlineRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.highlight,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = highlight ?? Colors.white;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      mouseCursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: highlight != null
                    ? highlight!.withValues(alpha: 0.22)
                    : Colors.white12,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 「本机音频设备」：本机正在播放时切换输出设备（Spotify 同款）。
/// - Windows / Linux：列出 libmpv 输出设备直接切换；WebView 出声时浏览器内核不跟随，如实提示；
/// - Android：打开系统输出切换面板（手机扬声器 / 蓝牙 / 耳机）；
/// - 同时显示当前实际出声的播放引擎，便于确认走的是哪条播放路径。
class _LocalOutputSection extends StatefulWidget {
  const _LocalOutputSection();

  @override
  State<_LocalOutputSection> createState() => _LocalOutputSectionState();
}

class _LocalOutputSectionState extends State<_LocalOutputSection> {
  static const _android = MethodChannel('flutify/audio_output');

  @override
  void initState() {
    super.initState();
    // 每次打开面板重新列出设备（可能刚插上耳机）
    final service = _read(context);
    if (service != null) unawaited(service.refresh());
  }

  static AudioOutputService? _read(BuildContext context) {
    try {
      return context.read<AudioOutputService?>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _openSystemSwitcher() async {
    bool shown;
    try {
      shown = await _android.invokeMethod<bool>('showSystemOutputSwitcher') ?? false;
    } catch (_) {
      shown = false;
    }
    if (!shown && mounted) {
      AppToast.show(
        context,
        context.l10n.audioOutputSystemUnavailable,
        icon: Icons.speaker_rounded,
        tone: ToastTone.warning,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = !kIsWeb && Platform.isAndroid;
    final hasService = _read(context) != null;
    if (!isAndroid && !hasService) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return ValueListenableBuilder<PlaybackEngineKind?>(
      valueListenable: activePlaybackEngine,
      builder: (context, engine, _) {
        final header = Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6, top: 20),
          child: Text(
            l10n.audioOutputTitle,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
        final engineLine = engine == null
            ? null
            : Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(
                  l10n.playbackEngineCurrent(_engineLabel(l10n, engine)),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              );
        if (isAndroid) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              _DeviceTile(
                icon: Icons.speaker_group_rounded,
                title: l10n.audioOutputSystemSwitcher,
                subtitle: l10n.audioOutputSystemSwitcherSubtitle,
                onTap: () => unawaited(_openSystemSwitcher()),
              ),
              ?engineLine,
            ],
          );
        }
        final service = context.watch<AudioOutputService?>()!;
        // Windows 的 WebView2 已能按设备名切换；Linux 的 Chrome EME 宿主暂不支持
        final webView =
            engine == PlaybackEngineKind.webView && Platform.isLinux;
        final options = [AudioOutputDevice.systemDefault, ...service.devices];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: header),
                if (service.loading)
                  const Padding(
                    padding: EdgeInsets.only(top: 14),
                    child: SizedBox.square(
                      dimension: 16,
                      child: FlutifySpinner(size: 16),
                    ),
                  ),
              ],
            ),
            if (webView)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(
                  l10n.audioOutputWebViewNote,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            Opacity(
              opacity: webView ? 0.5 : 1,
              child: IgnorePointer(
                ignoring: webView,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final device in options)
                      _DeviceTile(
                        icon: device.isSystemDefault
                            ? Icons.settings_suggest_rounded
                            : _outputIcon(device.label),
                        title: device.isSystemDefault
                            ? l10n.audioOutputSystemDefault
                            : device.label,
                        subtitle: device.id == service.selected
                            ? l10n.audioOutputSelected
                            : null,
                        selected: device.id == service.selected,
                        onTap: () => unawaited(service.select(device.id)),
                      ),
                  ],
                ),
              ),
            ),
            ?engineLine,
          ],
        );
      },
    );
  }

  static String _engineLabel(AppLocalizations l10n, PlaybackEngineKind kind) =>
      switch (kind) {
        PlaybackEngineKind.localPlayer => l10n.playbackEngineLocal,
        PlaybackEngineKind.webView => l10n.playbackEngineWebView,
        PlaybackEngineKind.androidDrm => l10n.playbackEngineAndroid,
      };

  /// 按设备名粗略区分耳机 / 扬声器图标。
  static IconData _outputIcon(String label) {
    final name = label.toLowerCase();
    if (name.contains('headphone') ||
        name.contains('headset') ||
        name.contains('耳机') ||
        name.contains('airpods') ||
        name.contains('buds')) {
      return Icons.headphones_rounded;
    }
    if (name.contains('hdmi') || name.contains('display')) {
      return Icons.tv_rounded;
    }
    return Icons.speaker_rounded;
  }
}
