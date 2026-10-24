import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/file_log.dart';
import '../theme/md3e_theme.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton;

/// Paint a frame before opening plugins or touching persistent storage.
/// 初始化期间只绘制窗口底色；首个内容页直接进入应用，异常时才显示诊断。
class AppStartup extends StatefulWidget {
  const AppStartup({super.key, required this.initialize});

  final Future<Widget> Function(ValueChanged<String> reportStage) initialize;

  @override
  State<AppStartup> createState() => _AppStartupState();
}

class _AppStartupState extends State<AppStartup> {
  String _stage = '正在启动';
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
      if (mounted) setState(() => _reason = '初始化超时：$_stage，请关闭并重新打开应用。');
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
                        Text('启动失败：$_stage'),
                        const SizedBox(height: 12),
                        SelectableText(_reason!),
                        ...[
                          const SizedBox(height: 12),
                          Text('请复制诊断信息反馈，然后关闭并重新打开应用。'),
                          const SizedBox(height: 12),
                          M3EButton.outlined(
                            onPressed: _copyDiagnostics,
                            child: const Text('复制诊断信息'),
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
