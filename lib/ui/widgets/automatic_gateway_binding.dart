import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../services/network/network_proxy.dart';
import '../../services/playback/playback_region_gate.dart';

/// Owns the app-lifetime triggers; NetworkProxy coalesces concurrent lookups.
class AutomaticGatewayBinding extends StatefulWidget {
  final Widget child;

  /// 当前位置门控，由 main 创建、和 PlaybackProvider 共用；为空时只做代理那一半。
  final PlaybackRegionGate? regionGate;
  const AutomaticGatewayBinding({
    super.key,
    required this.child,
    this.regionGate,
  });

  @override
  State<AutomaticGatewayBinding> createState() =>
      _AutomaticGatewayBindingState();
}

class _AutomaticGatewayBindingState extends State<AutomaticGatewayBinding>
    with WidgetsBindingObserver {
  NetworkProxy? _proxy;
  Timer? _timer;
  Timer? _debounce;
  Timer? _proxyWatcher;
  StreamSubscription<List<ConnectivityResult>>? _network;
  String? _lastProxyKey;

  @override
  void initState() {
    super.initState();
    _proxy = context.read<NetworkProxy?>();
    if (_proxy == null) return;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => _refresh());

    // Windows 切换代理（Clash / v2rayN 开关系统代理）不一定会触发网卡断开重连，
    // 这里每 2.5 秒快速轮询一次系统代理状态与在播实时出口，代理一关即可在数秒内打断播放
    _lastProxyKey = _proxy?.system.toString();
    _proxyWatcher = Timer.periodic(const Duration(milliseconds: 2500), (_) async {
      final proxy = _proxy;
      if (proxy == null) return;
      await proxy.refreshSystem();
      final currentKey = proxy.system.toString();
      final changed = currentKey != _lastProxyKey;
      _lastProxyKey = currentKey;
      if (changed) {
        widget.regionGate?.markNetworkChanged();
      } else if (widget.regionGate?.hasActivePlaybackListener == true) {
        widget.regionGate?.recheckLive();
      }
    });

    // connectivity_plus_linux starts its D-Bus connection in an unawaited async
    // onListen handler; on systems without NetworkManager (e.g. headless CI) it
    // rethrows outside the stream's onError callback into PlatformDispatcher.
    runZonedGuarded(() {
      _network = Connectivity().onConnectivityChanged.listen((_) {
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 1), () {
          unawaited(_proxy?.refreshGatewayCountry(networkChanged: true));
          // 换了网络出口就该重新看一次地区：下一次起播时再检测（这里不主动发起，
          // 免得用户在设置里关掉检测之后还被无头 WebView 打扰）。
          widget.regionGate?.markNetworkChanged();
        });
      }, onError: (Object _) {});
    }, (Object _, StackTrace _) {});
  }

  void _refresh() => unawaited(_proxy?.refreshGatewayCountry());

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _debounce?.cancel();
    _proxyWatcher?.cancel();
    unawaited(_network?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
