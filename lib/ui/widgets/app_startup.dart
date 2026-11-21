import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/file_log.dart';
import '../../l10n/app_localizations.dart';
import '../../core/theme/md3e_theme.dart';
import 'app_button.dart';

/// Paint a frame before opening plugins or touching persistent storage.
/// 初始化期间只绘制窗口底色；首个内容页直接进入应用，异常时才显示诊断。
class AppStartup extends StatefulWidget {
  const AppStartup({super.key, required this.initialize});

  final Future<Widget> Function(ValueChanged<String> reportStage) initialize;

  @override
  State<AppStartup> createState() => _AppStartupState();
}

class _AppStartupState extends State<AppStartup> {
  String _stage = 'starting';
  String? _failure;
  String? _reason;
  Widget? _app;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  Future<void> _start() async {
    _timer = Timer(const Duration(seconds: 60), () {
      if (mounted) setState(() => _reason = _l10n.startupTimeout(_stage));
    });
    try {
      final app = await widget.initialize((stage) {
        debugPrint('[Startup] $stage');
        if (mounted) _stage = stage;
      });
      if (mounted) setState(() => _app = app);
      debugPrint('[Startup] Ready');
    } catch (error, stack) {
      debugPrint('[Startup] Failed at $_stage: $error\n$stack');
      if (mounted) {
        setState(() {
          _failure = '$error\n$stack';
          _reason = '$error';
        });
      }
    } finally {
      _timer?.cancel();
    }
  }

  Future<void> _copyDiagnostics() async {
    final log = await readLogTail().timeout(
      const Duration(seconds: 2),
      onTimeout: () => '',
    );
    await Clipboard.setData(
      ClipboardData(
        text: 'Flutify startup: $_stage\n${_failure ?? _reason}\n$log',
      ),
    );
  }

  /// 启动失败页在本地化代理就绪前显示，按系统语言取文案（不支持的语言回退英文）。
  AppLocalizations get _l10n {
    final locale = PlatformDispatcher.instance.locale;
    try {
      return lookupAppLocalizations(locale);
    } catch (_) {
      return lookupAppLocalizations(const Locale('en'));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_app != null) return _app!;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: MD3ETheme.light,
      darkTheme: MD3ETheme.dark,
      home: Scaffold(
        body: _reason == null
            ? const SizedBox.expand()
            : SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Flutify', style: TextStyle(fontSize: 28)),
                        const SizedBox(height: 24),
                        Text(_l10n.startupFailed(_stage)),
                        const SizedBox(height: 12),
                        SelectableText(_reason!),
                        ...[
                          const SizedBox(height: 12),
                          Text(_l10n.startupCopyHint),
                          const SizedBox(height: 12),
                          AppButton.outlined(
                            onPressed: _copyDiagnostics,
                            child: Text(_l10n.startupCopyDiagnostics),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
