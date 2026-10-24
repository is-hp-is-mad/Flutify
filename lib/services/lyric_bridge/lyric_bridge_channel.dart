import 'dart:async';

import 'package:flutter/services.dart';

/// 已连接的蓝牙音频（A2DP）设备。
class BluetoothAudioDevice {
  final String address;
  final String name;

  /// 设备类别为车载音响 / 车载免提。
  final bool isCar;

  const BluetoothAudioDevice({
    required this.address,
    required this.name,
    required this.isCar,
  });

  static BluetoothAudioDevice? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final address = raw['address'];
    if (address is! String || address.isEmpty) return null;
    final name = raw['name'];
    return BluetoothAudioDevice(
      address: address,
      name: name is String ? name : '',
      isCar: raw['isCar'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BluetoothAudioDevice &&
      other.address == address &&
      other.name == name &&
      other.isCar == isCar;

  @override
  int get hashCode => Object.hash(address, name, isCar);
}

/// 歌词外显的原生能力（Android，见 `LyricBridgePlugin.kt`）。测试可替换为替身。
abstract class LyricBridgePlatform {
  Future<bool> isFlyme();

  /// 写入 / 清除（null）Flyme 状态栏歌词。
  Future<void> setTicker(String? text);

  Future<bool> hasBluetoothPermission();
  Future<void> requestBluetoothPermission();
  Future<List<BluetoothAudioDevice>> connectedDevices();

  /// 已连接设备的快照；订阅时先推送一次当前状态。
  Stream<List<BluetoothAudioDevice>> get devices;
}

class MethodChannelLyricBridge implements LyricBridgePlatform {
  static const _methods = MethodChannel('flutify/lyric_bridge');
  static const _events = EventChannel('flutify/bluetooth_audio');

  @override
  Future<bool> isFlyme() async =>
      await _methods.invokeMethod<bool>('isFlyme') ?? false;

  @override
  Future<void> setTicker(String? text) =>
      _methods.invokeMethod<void>('setTicker', {'text': text});

  @override
  Future<bool> hasBluetoothPermission() async =>
      await _methods.invokeMethod<bool>('hasBluetoothPermission') ?? false;

  @override
  Future<void> requestBluetoothPermission() =>
      _methods.invokeMethod<void>('requestBluetoothPermission');

  @override
  Future<List<BluetoothAudioDevice>> connectedDevices() async =>
      _parse(await _methods.invokeMethod<List<Object?>>('connectedDevices'));

  @override
  Stream<List<BluetoothAudioDevice>> get devices =>
      _events.receiveBroadcastStream().map(_parse);

  static List<BluetoothAudioDevice> _parse(Object? raw) => [
    if (raw is List)
      for (final item in raw) ?BluetoothAudioDevice.fromMap(item),
  ];
}
