import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart' show AudioDevice;

/// 本机的一个音频输出设备。
class AudioOutputDevice {
  /// libmpv 设备名（如 `wasapi/{guid}`）；[systemDefault] 为空串。
  final String id;
  final String label;

  const AudioOutputDevice(this.id, this.label);

  static const systemDefault = AudioOutputDevice('', '');

  bool get isSystemDefault => id.isEmpty;
}

/// 列出 / 切换本机音频输出设备的底层能力；测试可替换。
abstract class AudioOutputBackend {
  Future<List<AudioOutputDevice>> list();
  Future<void> select(String id);
}

/// libmpv（just_audio_media_kit，Windows / Linux）输出设备。
class MediaKitAudioOutputBackend implements AudioOutputBackend {
  @override
  Future<List<AudioOutputDevice>> list() async {
    final devices = await JustAudioMediaKit.audioDevices();
    return [
      for (final d in devices)
        // 只要「后端/设备」形式的真实设备（wasapi/{…}、pulse/…、alsa/…）；
        // `auto`（系统默认，界面单独作为第一项）和 `openal` 这类后端默认项都不列出
        if (d.name.contains('/'))
          AudioOutputDevice(d.name, d.description.isEmpty ? d.name : d.description),
    ];
  }

  @override
  Future<void> select(String id) => JustAudioMediaKit.setAudioDevice(
    id.isEmpty ? null : AudioDevice(id, ''),
  );
}

/// 畅联「本机音频设备」：像 Spotify 桌面端一样在设备面板里切换本机的输出设备（扬声器 / 耳机 / 声卡…）。
///
/// 只作用于本机播放引擎（Windows / Linux 的 libmpv）；选择会持久化（[onSelected]），
/// 启动时按 [initial] 恢复，设备已不存在时回落到系统默认。
class AudioOutputService extends ChangeNotifier {
  final AudioOutputBackend _backend;

  /// 选择变化时写回设置。
  final void Function(String id)? onSelected;

  /// 浏览器内核（WebView2 EME）出声时按设备名匹配输出设备：选择或设备列表变化时下发设备名
  /// （空串 = 系统默认）。
  final void Function(String label)? labelSink;

  AudioOutputService(
    this._backend, {
    String initial = '',
    this.onSelected,
    this.labelSink,
  })
    : _selected = initial,
      _preferred = initial {
    if (initial.isNotEmpty) {
      unawaited(_apply(initial));
      // EME 需要设备名：启动时列一次设备，解析出名字后下发
      if (labelSink != null) unawaited(refresh());
    }
  }

  /// 当前平台是否支持（Windows / Linux 走 libmpv）。
  static bool get platformSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  List<AudioOutputDevice> _devices = const [];
  String _selected;

  /// 用户选择（持久化）。设备暂时不在（如 USB 声卡没插）时 [_selected] 临时回落系统默认，
  /// 偏好保留，设备重新出现时自动切回。
  String _preferred;
  bool _loading = false;

  /// 可选设备（不含「系统默认」，界面单独显示）。
  List<AudioOutputDevice> get devices => _devices;

  /// 当前选择；空串为系统默认。
  String get selected => _selected;

  bool get loading => _loading;

  /// 重新列出设备（打开设备面板时调用）。选中的设备暂时不在时本次回落系统默认（不改偏好），
  /// 重新出现时切回。
  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    notifyListeners();
    try {
      _devices = await _backend.list();
    } catch (_) {
      _devices = const [];
    }
    _loading = false;
    final available = _preferred.isEmpty ||
        _devices.any((d) => d.id == _preferred);
    final target = available ? _preferred : '';
    // 列表为空（枚举失败）时不动当前输出
    if (_devices.isNotEmpty && target != _selected) {
      _selected = target;
      await _apply(target);
    }
    _sendLabel();
    notifyListeners();
  }

  void _sendLabel() {
    final sink = labelSink;
    if (sink == null) return;
    if (_selected.isEmpty) {
      sink('');
      return;
    }
    for (final d in _devices) {
      if (d.id == _selected) {
        sink(d.label);
        return;
      }
    }
    // 设备列表还没取到：等 refresh 之后再发
  }

  Future<void> select(String id) async {
    if (id == _selected && id == _preferred) return;
    _selected = id;
    _preferred = id;
    notifyListeners();
    onSelected?.call(id);
    _sendLabel();
    await _apply(id);
  }

  Future<void> _apply(String id) async {
    try {
      await _backend.select(id);
    } catch (e) {
      debugPrint('[audio-output] 切换输出设备失败：$e');
    }
  }
}
