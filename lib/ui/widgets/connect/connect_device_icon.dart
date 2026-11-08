import 'package:flutter/material.dart';

import '../../../models/connect_cluster.dart';

/// Connect 设备类型 → 图标（与 Spotify 设备列表的图标语义一致）。
IconData connectDeviceIcon(ConnectDeviceType type) => switch (type) {
  ConnectDeviceType.computer => Icons.laptop_rounded,
  ConnectDeviceType.smartphone => Icons.smartphone_rounded,
  ConnectDeviceType.tablet => Icons.tablet_rounded,
  ConnectDeviceType.speaker => Icons.speaker_rounded,
  ConnectDeviceType.tv => Icons.tv_rounded,
  ConnectDeviceType.castAudio => Icons.cast_rounded,
  ConnectDeviceType.castVideo => Icons.cast_connected_rounded,
  ConnectDeviceType.automobile => Icons.directions_car_rounded,
  ConnectDeviceType.gameConsole => Icons.sports_esports_rounded,
  ConnectDeviceType.smartWatch => Icons.watch_rounded,
  ConnectDeviceType.unknown => Icons.devices_other_rounded,
};
