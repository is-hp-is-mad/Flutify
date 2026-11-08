import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import 'cover_image.dart';

/// 当前账号头像，全应用统一（设置页账号卡片、桌面顶栏、主页 / 音乐库顶栏）：
///
/// - 有头像图片：圆形图片；
/// - 已登录但无头像：昵称首字 + **按用户名固定的底色**（同一账号在任何主题、
///   强调色、封面取色下颜色都不变，与 Spotify 的默认头像一致）；
/// - 未登录：人形图标。
class UserAvatar extends StatelessWidget {
  final double size;

  const UserAvatar({super.key, required this.size});

  /// 默认头像底色：中等明度、白字对比度足够，深浅色主题下都清晰。
  static const List<Color> _palette = [
    Color(0xFF4F7CF7), // 蓝
    Color(0xFF8E5CF6), // 紫
    Color(0xFFE0457B), // 玫红
    Color(0xFFE8663D), // 橙
    Color(0xFF1F9E89), // 青绿
    Color(0xFF2F8FD0), // 天蓝
    Color(0xFFB8508F), // 洋红
    Color(0xFF5E7D3A), // 橄榄绿
  ];

  /// FNV-1a：跨运行、跨平台稳定（String.hashCode 不保证）。
  static Color colorFor(String seed) {
    var hash = 0x811c9dc5;
    for (final unit in seed.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return _palette[hash % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final (signedIn, username, name, avatar) = context.select<AuthProvider, (bool, String, String, String)>(
      (a) => (a.isSignedIn, a.username, a.displayName, a.avatarUrl),
    );

    if (signedIn && avatar.isNotEmpty) {
      return CoverImage(url: avatar, size: size, circular: true, placeholderIcon: Icons.person_rounded);
    }

    final colorScheme = Theme.of(context).colorScheme;
    final trimmed = name.trim();
    if (!signedIn || trimmed.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: colorScheme.surfaceContainerHighest, shape: BoxShape.circle),
        child: Icon(Icons.person_rounded, size: size * 0.56, color: colorScheme.onSurfaceVariant),
      );
    }

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorFor(username.isNotEmpty ? username : trimmed),
        shape: BoxShape.circle,
      ),
      child: Text(
        trimmed.characters.first.toUpperCase(),
        // 字号随头像缩放，不受用户字号设置影响（否则大字号时溢出圆形）
        textScaler: TextScaler.noScaling,
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: size * 0.42, height: 1),
      ),
    );
  }
}
