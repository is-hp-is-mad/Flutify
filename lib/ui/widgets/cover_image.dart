import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 统一的封面/头像图片组件。
///
/// 性能要点：按实际显示尺寸 × 设备像素比设置 memCacheWidth，
/// 让 44dp 的缩略图不再解码整张 600px 原图，显著降低内存与解码耗时。
class CoverImage extends StatelessWidget {
  final String url;

  /// 显示边长（dp）。为空时通过 LayoutBuilder 取父约束宽度。
  final double? size;

  /// 解码缓存参考边长（dp）。封面动画缩放（飞行、歌词小图切换）时固定它，
  /// 避免布局边长变化触发重复解码；大封面（≥ 240dp）保留原图分辨率。
  final double? cacheSize;
  final BorderRadius? borderRadius;
  final bool circular;
  final IconData placeholderIcon;
  final FilterQuality? filterQuality;

  const CoverImage({
    super.key,
    required this.url,
    this.size,
    this.cacheSize,
    this.borderRadius,
    this.circular = false,
    this.placeholderIcon = Icons.music_note_rounded,
    this.filterQuality,
  });

  @override
  Widget build(BuildContext context) {
    Widget child = size != null
        ? SizedBox(width: size, height: size, child: _buildImage(context, size))
        : LayoutBuilder(
            builder: (context, constraints) => _buildImage(
              context,
              constraints.maxWidth.isFinite ? constraints.maxWidth : null,
            ),
          );

    if (circular) {
      child = ClipOval(child: child);
    } else if (borderRadius != null) {
      child = ClipRRect(borderRadius: borderRadius!, child: child);
    }
    return child;
  }

  Widget _buildImage(BuildContext context, double? logicalWidth) {
    final colorScheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: colorScheme.surfaceContainerHigh,
      child: Center(
        child: Icon(
          placeholderIcon,
          color: colorScheme.onSurfaceVariant.withAlpha(120),
        ),
      ),
    );

    if (url.isEmpty) return placeholder;

    // 淡入由 Ticker 驱动。封面所在子树被 TickerMode 暂停时（例如歌词视图里的小封面），
    // 淡入动画停在透明、旧图又立刻移除，换歌后就只剩深色占位。暂停时直接显示新图。
    final fadeIn = TickerMode.valuesOf(context).enabled
        ? const Duration(milliseconds: 150)
        : Duration.zero;

    // CachedNetworkImage 默认 FilterQuality.low（无 mipmap 的单次双线性插值）：
    // 大封面（如展开播放页把 640px 原图放大到 1000+ 物理像素）会明显发糊，改用双三次采样；
    // 缩略图与缩小动画改用带硬件 mipmap 的 medium，避免锯齿与模糊。
    final effectiveQuality =
        filterQuality ??
        ((logicalWidth == null || logicalWidth >= 160)
            ? FilterQuality.high
            : FilterQuality.medium);

    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      filterQuality: effectiveQuality,
      memCacheWidth: _cacheWidth(context, cacheSize ?? logicalWidth),
      fadeInDuration: fadeIn,
      fadeOutDuration: Duration.zero,
      placeholder: (_, _) =>
          ColoredBox(color: colorScheme.surfaceContainerHigh),
      errorWidget: (_, _, _) => placeholder,
    );
  }

  /// 小缩略图按 1.5 倍显示像素解码并按 64px 取整；大封面（≥ 240dp）直接解码原图（如 Spotify 640px），
  /// 既保留全部细节，也让专辑页、封面飞行与播放页命中同一份内存缓存而不重复解码。
  int? _cacheWidth(BuildContext context, double? logicalWidth) {
    if (logicalWidth == null || logicalWidth <= 0 || logicalWidth >= 240) {
      return null;
    }
    final px = logicalWidth * MediaQuery.devicePixelRatioOf(context) * 1.5;
    return ((px / 64).ceil() * 64);
  }
}
