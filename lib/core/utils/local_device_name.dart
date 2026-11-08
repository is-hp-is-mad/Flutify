import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// 本机的「设备名称」，供 Connect 设备名一键填入：
/// - Windows：计算机名（如 LAPTOP-XXXXXX）；
/// - macOS：系统设置的电脑名（如 俊信的 MacBook Pro），而非 raw hostname；
/// - Android：厂商 + 型号（如 Xiaomi 23127PN0CC），系统里没有可读的用户自定义名；
/// - 其他平台 / 读取失败：主机名，仍拿不到时为空串。
Future<String> localDeviceName() async {
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isWindows) return (await info.windowsInfo).computerName;
    if (Platform.isMacOS) {
      final name = (await info.macOsInfo).computerName.trim();
      if (name.isNotEmpty) return name;
    }
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      final brand = a.manufacturer.trim();
      final model = a.model.trim();
      // 有的型号已以厂商名开头，避免重复
      return model.toLowerCase().startsWith(brand.toLowerCase()) ||
              brand.isEmpty
          ? model
          : '$brand $model';
    }
  } catch (_) {}
  try {
    final host = Platform.localHostname;
    return host == 'localhost' ? '' : host;
  } catch (_) {
    return '';
  }
}

/// 启动时读取并缓存的本机名称，供 Connect 默认设备名同步使用；读取前 / 失败为空串。
String cachedLocalDeviceName = '';

Future<void> loadLocalDeviceName() async {
  cachedLocalDeviceName = (await localDeviceName()).trim();
}
