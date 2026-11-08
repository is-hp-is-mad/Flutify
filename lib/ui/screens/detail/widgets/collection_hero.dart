import 'package:flutter/material.dart';

import '../../../../core/theme/flutify_tokens.dart';
import '../../../widgets/hyper_surface.dart';
import '../../../../core/utils/artwork_palette.dart';
import '../../../shell/shell_breakpoints.dart';
import '../../../widgets/cover_image.dart';

// 歌单 / 专辑 / 艺人详情页的大头图（Spotify 新版桌面端风格）。
//
// 结构：
//   CollectionTintScope（取封面主色，向下传递色调）
//     └ CustomScrollView
//         ├ CollectionHero（吸顶头部，滚动收起为 64px 标题栏）
//         └ CollectionHeroFade（操作行底色：承接头部渐变淡出到页面底色）

/// 取一次封面主色，供 [CollectionHero] 与 [CollectionHeroFade] 共用。
class CollectionTintScope extends StatelessWidget {
  final String imageUrl;

  /// 无封面 / 取色完成前使用的颜色（例如「已点赞的歌曲」的紫色）。
  final Color fallback;
  final Widget child;

  const CollectionTintScope({super.key, required this.imageUrl, required this.fallback, required this.child});

  @override
  Widget build(BuildContext context) {
    return ArtworkColorBuilder(
      imageUrl: imageUrl,
      fallback: fallback,
      builder: (context, color) => CollectionTint(artColor: color, child: child),
    );
  }
}

/// 详情页色调。取色结果是深色主题下的 primaryContainer（偏暗的饱和色），
/// 这里按当前深浅色换算成适合放文字的底色。
class CollectionTint extends InheritedWidget {
  final Color artColor;

  const CollectionTint({super.key, required this.artColor, required super.child});

  static Color? maybeOf(BuildContext context) {
    final tint = context.dependOnInheritedWidgetOfExactType<CollectionTint>();
    if (tint == null) return null;
    return toneFor(tint.artColor, Theme.of(context).brightness);
  }

  /// 头部底色：深色主题略压暗（配浅色文字），浅色主题提亮成淡彩（配深色文字）。
  static Color toneFor(Color art, Brightness brightness) =>
      brightness == Brightness.dark ? Color.lerp(art, Colors.black, 0.05)! : Color.lerp(art, Colors.white, 0.45)!;

  /// 头部底边的颜色（已向页面底色过渡一段），[CollectionHeroFade] 从这里接着淡出。
  static Color heroBottom(Color tone, ColorScheme scheme) => Color.lerp(tone, scheme.surface, 0.35)!;

  @override
  bool updateShouldNotify(CollectionTint oldWidget) => oldWidget.artColor != artColor;
}

/// 操作行（播放 / 收藏 / 更多）的底色：从头部底边颜色渐变到页面底色，避免头部下沿出现硬边。
class CollectionHeroFade extends StatelessWidget {
  final Widget child;

  const CollectionHeroFade({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final tone = CollectionTint.maybeOf(context);
    if (tone == null) return child;
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [CollectionTint.heroBottom(tone, scheme).withAlpha(150), scheme.surface.withAlpha(0)],
        ),
      ),
      child: child,
    );
  }
}

/// 吸顶大头图（Sliver）。
///
/// - 宽（内容区 ≥ 600）：左侧 232px 封面，右侧「类型 / 超大标题 / 元信息」底部对齐；
/// - 窄（手机）：封面居中，标题与元信息在下方；
/// - 向上滚动时内容淡出，收起为 64px 标题栏：封面主色底 + [collapsedAction]（播放键）+ 标题；
/// - 移动端（非桌面框架）左上角常驻返回键；桌面端由顶栏负责后退。
class CollectionHero extends StatefulWidget {
  /// 标题上方的小字：歌单 / 专辑 / 单曲 / 艺人。
  final String typeLabel;
  final String title;
  final String imageUrl;

  /// 替代网络封面的组件（「已点赞的歌曲」的渐变爱心）。
  final Widget? coverOverride;

  /// 艺人头像使用圆形封面。
  final bool circularCover;

  /// 标题下方的元信息（作者 / 艺人、年份、歌曲数与时长等）。
  final Widget? meta;

  /// 收起后标题栏左侧的操作（通常是 36–44px 的播放键）。
  final Widget? collapsedAction;

  const CollectionHero({
    super.key,
    required this.typeLabel,
    required this.title,
    required this.imageUrl,
    this.coverOverride,
    this.circularCover = false,
    this.meta,
    this.collapsedAction,
  });

  @override
  State<CollectionHero> createState() => _CollectionHeroState();
}

/// 性能：SliverLayoutBuilder 的约束里含滚动偏移，每滚一帧都会回调 builder。
/// 这里按宽度缓存同一个组件实例，宽度不变时直接返回，框架会跳过整棵头部子树。
/// 缓存只在 build（组件参数或依赖的主题 / 媒体查询变化）时失效。
class _CollectionHeroState extends State<CollectionHero> {
  double? _cachedWidth;
  Widget? _cachedSliver;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final tone = CollectionTint.maybeOf(context) ?? CollectionTint.toneFor(const Color(0xFF3A3A48), brightness);
    final topPadding = MediaQuery.paddingOf(context).top;
    final inDesktopShell = ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width);
    final showBack = !inDesktopShell && (ModalRoute.of(context)?.canPop ?? false);
    _cachedSliver = null;

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        if (_cachedSliver != null && _cachedWidth == width) return _cachedSliver!;
        _cachedWidth = width;
        return _cachedSliver = SliverPersistentHeader(
          pinned: true,
          delegate: _HeroDelegate(
            hero: widget,
            tone: tone,
            wide: width >= 600,
            width: width,
            topPadding: topPadding,
            showBack: showBack,
          ),
        );
      },
    );
  }
}

class _HeroDelegate extends SliverPersistentHeaderDelegate {
  final CollectionHero hero;
  final Color tone;
  final bool wide;
  final double width;
  final double topPadding;
  final bool showBack;

  _HeroDelegate({
    required this.hero,
    required this.tone,
    required this.wide,
    required this.width,
    required this.topPadding,
    required this.showBack,
  });

  static const double _barHeight = 64;

  /// 宽布局封面边长：窄一些的内容区用 192，避免标题被挤成一列。
  double get _wideCover => width >= 760 ? 232 : 192;

  @override
  double get minExtent => _barHeight + topPadding;

  @override
  double get maxExtent => wide ? _wideCover + 72 : topPadding + 400;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final scheme = Theme.of(context).colorScheme;
    final range = maxExtent - minExtent;
    final t = range <= 0 ? 1.0 : (shrinkOffset / range).clamp(0.0, 1.0);
    // 内容先淡出，标题栏在后半程淡入，两者不同时出现
    final contentOpacity = (1 - t * 1.6).clamp(0.0, 1.0);
    final barOpacity = ((t - 0.55) / 0.45).clamp(0.0, 1.0);

    final brightness = Theme.of(context).brightness;
    final barColor = brightness == Brightness.dark
        ? Color.lerp(tone, Colors.black, 0.3)!
        : Color.lerp(tone, Colors.black, 0.08)!;
    final barForeground = ThemeData.estimateBrightnessForColor(barColor) == Brightness.dark
        ? Colors.white
        : const Color(0xFF15161B);

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 背景随内容一起上移并淡出，吸顶后完全退场让给着色玻璃（否则会变成实色遮挡下方曲目）
          Positioned(
            left: 0,
            right: 0,
            top: -shrinkOffset,
            height: maxExtent,
            child: Opacity(
              opacity: contentOpacity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [tone, CollectionTint.heroBottom(tone, scheme)],
                  ),
                ),
              ),
            ),
          ),
          // 内容随页面一起上移（top 跟随 shrinkOffset），同时淡出
          Positioned(
            left: 0,
            right: 0,
            top: -shrinkOffset,
            height: maxExtent,
            child: IgnorePointer(
              ignoring: contentOpacity == 0,
              child: Opacity(
                opacity: contentOpacity,
                child: wide
                    ? _WideContent(hero: hero, coverSize: _wideCover)
                    : _NarrowContent(hero: hero, topPadding: topPadding),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: minExtent,
            child: IgnorePointer(
              ignoring: barOpacity == 0,
              child: Opacity(
                opacity: barOpacity,
                child: context.tokens.hyperMaterial
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          HyperAppBarBackground(
                            tintColor: tone,
                            showBottomLine: !wide,
                            isDesktop: wide,
                          ),
                          Padding(
                            padding: EdgeInsets.fromLTRB(showBack ? 60 : 16, topPadding, 16, 0),
                            child: Row(
                              children: [
                                if (hero.collapsedAction != null) ...[hero.collapsedAction!, const SizedBox(width: 12)],
                                Expanded(
                                  child: Text(
                                    hero.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: barForeground),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : ColoredBox(
                        color: barColor,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(showBack ? 60 : 16, topPadding, 16, 0),
                          child: Row(
                            children: [
                              if (hero.collapsedAction != null) ...[hero.collapsedAction!, const SizedBox(width: 12)],
                              Expanded(
                                child: Text(
                                  hero.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: barForeground),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
          ),
          if (showBack)
            Positioned(
              left: 8,
              top: topPadding + 12,
              child: _BackCircle(floating: shrinkOffset > 10),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_HeroDelegate old) =>
      old.hero != hero ||
      old.tone != tone ||
      old.wide != wide ||
      old.width != width ||
      old.topPadding != topPadding ||
      old.showBack != showBack;
}

/// 宽布局：封面 + 标题区底部对齐。
class _WideContent extends StatelessWidget {
  final CollectionHero hero;
  final double coverSize;

  const _WideContent({required this.hero, required this.coverSize});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // 左右 16 与下方操作行、曲目列表对齐
      padding: const EdgeInsets.fromLTRB(16, 48, 16, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _HeroCover(hero: hero, size: coverSize),
          const SizedBox(width: 24),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final titleStyle = theme.textTheme.displayLarge!.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                  letterSpacing: -0.5,
                );
                // 预留类型小字与元信息（最多两行）的高度，剩下的给标题
                final reserved = 30 + (hero.meta != null ? 58 : 0);
                final fontSize = _TitleFitter.fit(
                  context,
                  hero.title,
                  titleStyle,
                  box.maxWidth,
                  box.maxHeight - reserved,
                );
                return Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (hero.typeLabel.isNotEmpty)
                      Text(hero.typeLabel, style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Flexible(
                      child: Text(
                        hero.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle.copyWith(fontSize: fontSize),
                      ),
                    ),
                    if (hero.meta != null) ...[
                      const SizedBox(height: 14),
                      DefaultTextStyle.merge(
                        style: theme.textTheme.bodyMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        child: hero.meta!,
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 选出标题能在两行内、且不超过可用高度的最大字号（海报级 88 → 最小 26）。
///
/// 头部在滚动时每帧重建，测量结果按「标题 + 宽 + 高 + 字体缩放」缓存。
class _TitleFitter {
  _TitleFitter._();

  static const List<double> _sizes = [88, 72, 60, 48, 40, 32, 26];
  static final Map<String, double> _cache = {};

  static double fit(BuildContext context, String title, TextStyle style, double maxWidth, double maxHeight) {
    final scaler = MediaQuery.textScalerOf(context);
    final key = '$title|${maxWidth.round()}|${maxHeight.round()}|${scaler.scale(10)}';
    final hit = _cache[key];
    if (hit != null) return hit;

    var result = _sizes.last;
    for (final size in _sizes) {
      final painter = TextPainter(
        text: TextSpan(
          text: title,
          style: style.copyWith(fontSize: size),
        ),
        maxLines: 2,
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout(maxWidth: maxWidth);
      final fits = !painter.didExceedMaxLines && painter.height <= maxHeight;
      painter.dispose();
      if (fits) {
        result = size;
        break;
      }
    }
    if (_cache.length > 200) _cache.clear();
    return _cache[key] = result;
  }
}

/// 窄布局：返回键行 + 居中封面（可随空间缩小）+ 标题 + 元信息。
class _NarrowContent extends StatelessWidget {
  final CollectionHero hero;
  final double topPadding;

  const _NarrowContent({required this.hero, required this.topPadding});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, topPadding + 56, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Center(
              child: LayoutBuilder(
                builder: (context, box) => _HeroCover(hero: hero, size: box.maxHeight.clamp(96.0, 240.0)),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            hero.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (hero.meta != null) ...[
            const SizedBox(height: 6),
            DefaultTextStyle.merge(style: theme.textTheme.bodySmall, child: hero.meta!),
          ],
        ],
      ),
    );
  }
}

/// 带投影的封面；[CollectionHero.coverOverride] 按比例缩放到同样尺寸。
class _HeroCover extends StatelessWidget {
  final CollectionHero hero;
  final double size;

  const _HeroCover({required this.hero, required this.size});

  @override
  Widget build(BuildContext context) {
    final radius = context.tokens.radius(size >= 200 ? 12 : 10);
    final cover = hero.coverOverride != null
        ? SizedBox.square(
            dimension: size,
            child: FittedBox(child: hero.coverOverride),
          )
        : CoverImage(
            url: hero.imageUrl,
            size: size,
            circular: hero.circularCover,
            borderRadius: hero.circularCover ? null : radius,
            placeholderIcon: hero.circularCover ? Icons.person_rounded : Icons.music_note_rounded,
          );
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: hero.circularCover ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: hero.circularCover ? null : radius,
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(110), blurRadius: 40, offset: const Offset(0, 12))],
      ),
      child: cover,
    );
  }
}

/// 移动端返回键：半透明黑底圆钮，在任何封面色上都清晰。
class _BackCircle extends StatelessWidget {
  final bool floating;
  const _BackCircle({this.floating = false});

  @override
  Widget build(BuildContext context) {
    if (context.tokens.hyperMaterial) {
      return Tooltip(
        message: MaterialLocalizations.of(context).backButtonTooltip,
        child: HyperBackButton(
          floating: floating,
          color: Colors.white,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.arrow_back_rounded),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      onPressed: () => Navigator.of(context).maybePop(),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withAlpha(90),
        foregroundColor: Colors.white,
        fixedSize: const Size.square(40),
        minimumSize: const Size.square(40),
      ),
    );
  }
}
