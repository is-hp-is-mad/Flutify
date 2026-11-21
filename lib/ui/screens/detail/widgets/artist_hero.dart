import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../core/debug_toggles.dart';
import '../../../../core/perf_flags.dart';
import '../../../../core/theme/artist_artwork_scheme.dart';
import '../../../../core/theme/flutify_tokens.dart';
import '../../../../core/theme/system_bars.dart';
import '../../../../l10n/l10n.dart';
import '../../../../models/playback_context.dart';
import '../../../../models/share_target.dart';
import '../../../../models/track.dart';
import '../../../../providers/playback_provider.dart';
import '../../../shell/desktop/desktop_window.dart';
import '../../../shell/shell_breakpoints.dart';
import '../../../widgets/cover_image.dart';
import '../../../widgets/hyper_surface.dart';
import '../../../widgets/motion_video.dart';
import '../../../widgets/player_controls.dart';
import '../../../widgets/share/share_sheet.dart';
import 'artist_info_sheet.dart';

/// Apple Music 7.0（`la.C5429v0` / `la.I0` / `la.J0`）式艺人页顶部头图（Sliver）：
///
/// - 顶部导航浮层：左上圆形毛玻璃返回键 `<`，右上胶囊毛玻璃容器承载「随机播放 + 分享」；
/// - 头图 / 动态视频铺满宽度（手机 1:1，宽屏 2.28:1），下缘经缓动渐变无缝融进整页背景色；
/// - 底部居中排布粗体艺人名与三枚圆形操作钮：`[ (i) 艺人信息 48dp ]  [ (▶) 播放 72dp ]  [ (☆/★) 关注 48dp ]`；
/// - 下拉回弹放大头图，上滑收起为 64dp 着色吸顶标题栏。
class ArtistHero extends StatelessWidget {
  final String name;
  final String imageUrl;
  final ArtistArtworkScheme scheme;
  final Uint8List? video;
  final List<SpotifyTrack> tracks;
  final PlaybackContext playbackContext;
  final bool following;
  final VoidCallback onToggleFollow;
  final ValueChanged<BuildContext> onOpenInfo;
  final ShareTarget shareTarget;

  const ArtistHero({
    super.key,
    required this.name,
    required this.imageUrl,
    required this.scheme,
    required this.tracks,
    required this.playbackContext,
    required this.following,
    required this.onToggleFollow,
    required this.onOpenInfo,
    required this.shareTarget,
    this.video,
  });

  /// 宽屏头图宽高比（`header_page_h_aspect_ratio`）。
  static const double wideAspectRatio = 2.28;
  static const double _wideMinPhotoHeight = 300;
  static const double _phoneExtendBottom = 96;
  static const double _wideExtendBottom = 92;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;
    final inDesktopShell = ShellBreakpoints.isDesktop(
      MediaQuery.sizeOf(context).width,
    );
    final showBack =
        !inDesktopShell && (ModalRoute.of(context)?.canPop ?? false);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final wide = width >= 600;
        final photoHeight = wide
            ? (width / wideAspectRatio).clamp(_wideMinPhotoHeight, 520.0)
            : width.clamp(topPadding + 220.0, 620.0);
        final extend = wide ? _wideExtendBottom : _phoneExtendBottom;
        return SliverPersistentHeader(
          pinned: true,
          delegate: _ArtistHeroDelegate(
            hero: this,
            photoHeight: photoHeight,
            extendBottom: extend,
            topPadding: topPadding,
            showBack: showBack,
            wide: wide,
          ),
        );
      },
    );
  }
}

class _ArtistHeroDelegate extends SliverPersistentHeaderDelegate {
  final ArtistHero hero;
  final double photoHeight;
  final double extendBottom;
  final double topPadding;
  final bool showBack;
  final bool wide;

  _ArtistHeroDelegate({
    required this.hero,
    required this.photoHeight,
    required this.extendBottom,
    required this.topPadding,
    required this.showBack,
    required this.wide,
  });

  static const double _barHeight = 64;

  @override
  double get minExtent => _barHeight + topPadding;

  @override
  double get maxExtent => photoHeight + extendBottom;

  @override
  OverScrollHeaderStretchConfiguration? get stretchConfiguration =>
      OverScrollHeaderStretchConfiguration();

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final scheme = hero.scheme;
    final pageColor = scheme.backgroundColor;
    final range = maxExtent - minExtent;
    final t = range <= 0 ? 1.0 : (shrinkOffset / range).clamp(0.0, 1.0);
    final contentOpacity = (1 - t * 1.38).clamp(0.0, 1.0);
    final barOpacity = ((t - 0.62) / 0.38).clamp(0.0, 1.0);
    final tokens = context.tokens;
    final hyper = tokens.hyperMaterial;
    final barColor = Color.lerp(pageColor, Colors.black, 0.16)!;

    // 浅色棚拍头图（如白底肖像）未收起时顶栏用浅底深字；深色头图或收起后统一用深底白字。
    final lightPhotoTop = scheme.sourceIsLight && hero.imageUrl.isNotEmpty;
    final lightTopFactor = lightPhotoTop ? (1.0 - barOpacity) : 0.0;
    final topIconColor = Color.lerp(
      Colors.white,
      const Color(0xFF15161B),
      lightTopFactor,
    )!;
    final statusBrightness = lightTopFactor > 0.5
        ? Brightness.light
        : Brightness.dark;

    // 头图淡出（`la.M`）：滚过 180dp 后开始，380dp 处完全融进背景色
    final fadeStart = range < 400 ? range * 0.45 : 180.0;
    final fadeEnd = range < 400 ? range * 0.95 : 380.0;
    final photoOpacity = fadeEnd <= fadeStart
        ? 1.0
        : (1 - (shrinkOffset - fadeStart) / (fadeEnd - fadeStart)).clamp(
            0.0,
            1.0,
          );

    final photo = CoverImage(
      url: hero.imageUrl,
      placeholderIcon: Icons.person_rounded,
    );
    // 视频只有这一处；淡出后暂停（播放器保留，滚回来接着播）
    final media = hero.video == null
        ? photo
        : MotionVideo(
            bytes: hero.video!,
            placeholder: photo,
            playing: photoOpacity > 0,
          );

    final shareable = hero.shareTarget.isShareable;
    // 右侧胶囊宽度：随机播放 + 分享约 100dp，只有随机播放时约 56dp，给吸顶标题留出安全右边距
    final rightReserved = shareable ? 116.0 : 72.0;

    final layers = LayoutBuilder(
      builder: (context, box) {
        final stretch = box.maxHeight > maxExtent
            ? box.maxHeight - maxExtent
            : 0.0;
        // 下拉放大；滚过淡出起点后再缓慢放大到 1.05
        final scale =
            (1.0 + stretch / photoHeight) *
            (1.0 + (shrinkOffset - fadeStart) * 0.00025).clamp(1.0, 1.05);
        final parallax = -shrinkOffset * 0.4;
        // 只用现有的 20 段缓动渐变融入页底色。移除静态照片的模糊镜像叠层，
        // 避免照片 / 视频被横向磨砂条遮住，也避免视频换场景时与静态镜像出现色块接缝。
        final easedHeight = photoHeight * 0.64 < 250.0
            ? photoHeight * 0.64
            : 250.0;

        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: pageColor),

            // 头图与底部延展；淡出后不再绘制，但保留状态（视频播放器不重建）
            Positioned(
              left: 0,
              right: 0,
              top: parallax,
              height: maxExtent,
              child: Visibility(
                visible: photoOpacity > 0,
                maintainState: true,
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topCenter,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: photoHeight,
                        child: media,
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        top: photoHeight - easedHeight,
                        height: easedHeight,
                        child: DecoratedBox(
                          key: const Key('artist-hero-media-fade'),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: scheme.heroGradientColors,
                              stops: ArtistArtworkScheme.heroGradientStops,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        top: photoHeight - 1,
                        bottom: 0,
                        child: ColoredBox(color: pageColor),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 滚动淡出：盖一层背景色，效果等同于让头图变透明，但不必把整组图层离屏合成
            if (photoOpacity < 1)
              IgnorePointer(
                child: ColoredBox(
                  color: pageColor.withValues(alpha: 1 - photoOpacity),
                ),
              ),

            // 深色头图顶部轻微压暗，确保白色状态栏与胶囊在局部高光上依然稳妥；浅色棚拍图不加黑雾以免发脏
            if (!lightPhotoTop && photoOpacity > 0)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: topPadding + 68,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color.fromRGBO(0, 0, 0, 0.22 * photoOpacity),
                          const Color(0x00000000),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // 居中艺人名 + 三枚圆形操作按钮：`[ (i)  (▶)  (☆/★) ]`
            Positioned(
              left: wide ? 34 : 20,
              right: wide ? 34 : 20,
              bottom: 14 - shrinkOffset * 0.85,
              child: IgnorePointer(
                ignoring: contentOpacity < 0.05,
                child: Opacity(
                  opacity: contentOpacity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hero.name,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: wide ? 40 : 32,
                          fontWeight: FontWeight.w700,
                          height: 1.12,
                          letterSpacing: -0.5,
                          shadows: const [
                            Shadow(color: Color(0x42000000), blurRadius: 14),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ArtistInfoSource(
                            child: Builder(
                              builder: (infoContext) => _HeroSideCircleButton(
                                buttonKey: const Key('artist-info-button'),
                                tooltip: context.l10n.shellAboutArtist,
                                onPressed: () => hero.onOpenInfo(infoContext),
                                child: const CustomPaint(
                                  size: Size.square(48),
                                  painter: _AppleArtistInfoPainter(
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 24),
                          _ArtistHeroPlayButton(
                            tracks: hero.tracks,
                            playbackContext: hero.playbackContext,
                            cutoutColor: pageColor,
                          ),
                          const SizedBox(width: 24),
                          _HeroSideCircleButton(
                            buttonKey: const Key('artist-follow-star-button'),
                            tooltip: hero.following
                                ? context.l10n.artistFollowing
                                : context.l10n.artistFollow,
                            onPressed: hero.onToggleFollow,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              transitionBuilder: (child, anim) =>
                                  ScaleTransition(scale: anim, child: child),
                              child: CustomPaint(
                                key: ValueKey<bool>(hero.following),
                                size: const Size(22, 19),
                                painter: _AppleFavoriteStarPainter(
                                  filled: hero.following,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 收起后的吸顶标题栏
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: minExtent,
              child: IgnorePointer(
                ignoring: barOpacity == 0,
                child: Opacity(
                  opacity: barOpacity,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hyper)
                        HyperAppBarBackground(
                          tintColor: pageColor,
                          showBottomLine: !wide,
                          isDesktop: wide,
                        )
                      else
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: barColor,
                            border: Border(
                              bottom: BorderSide(
                                color: scheme.dividerColor,
                                width: 0.5,
                              ),
                            ),
                          ),
                        ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          showBack ? 72 : 20,
                          topPadding,
                          rightReserved,
                          0,
                        ),
                        child: Align(
                          alignment: showBack
                              ? Alignment.center
                              : Alignment.centerLeft,
                          child: Text(
                            hero.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 17,
                                  color: Colors.white,
                                ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 左上角圆形毛玻璃返回键 `<`
            if (showBack)
              Positioned(
                left: 16,
                top: topPadding + 10,
                child: _TopGlassSurface(
                  borderRadius: BorderRadius.circular(22),
                  lightFactor: lightTopFactor,
                  child: IconButton(
                    key: const Key('artist-back-button'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    constraints: const BoxConstraints.tightFor(
                      width: 44,
                      height: 44,
                    ),
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 19,
                      color: topIconColor,
                    ),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),

            // 右上角毛玻璃胶囊：随机播放 + 分享（与参考图一致）
            Positioned(
              right: 16,
              top: topPadding + 10,
              child: _TopGlassSurface(
                key: const Key('artist-top-actions'),
                borderRadius: BorderRadius.circular(22),
                lightFactor: lightTopFactor,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ShuffleButton(
                      size: 21,
                      inactiveColor: topIconColor,
                      constraints: const BoxConstraints.tightFor(
                        width: 46,
                        height: 44,
                      ),
                    ),
                    if (shareable) ...[
                      Container(
                        width: 0.6,
                        height: 20,
                        color: topIconColor.withValues(alpha: 0.16),
                      ),
                      IconButton(
                        key: const Key('artist-share-button'),
                        tooltip: context.l10n.commonShare,
                        constraints: const BoxConstraints.tightFor(
                          width: 46,
                          height: 44,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.ios_share_rounded,
                          size: 20,
                          color: topIconColor,
                        ),
                        onPressed: () =>
                            ShareSheet.show(context, hero.shareTarget),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemBarsStyle(statusBrightness),
      child: ClipRect(child: layers),
    );
  }

  @override
  bool shouldRebuild(_ArtistHeroDelegate old) =>
      old.hero.name != hero.name ||
      old.hero.imageUrl != hero.imageUrl ||
      old.hero.scheme != hero.scheme ||
      !identical(old.hero.video, hero.video) ||
      !identical(old.hero.tracks, hero.tracks) ||
      old.hero.playbackContext.uri != hero.playbackContext.uri ||
      old.hero.following != hero.following ||
      old.hero.shareTarget != hero.shareTarget ||
      old.photoHeight != photoHeight ||
      old.extendBottom != extendBottom ||
      old.topPadding != topPadding ||
      old.showBack != showBack ||
      old.wide != wide;
}

// -----------------------------------------------------------------------------
// 顶部毛玻璃浮层与头图按钮（Apple Music 7.0 `la.I0` / `la.J0`）
// -----------------------------------------------------------------------------

class _TopGlassSurface extends StatelessWidget {
  final BorderRadius borderRadius;
  final double lightFactor;
  final Widget child;

  const _TopGlassSurface({
    super.key,
    required this.borderRadius,
    required this.lightFactor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final darkFill = Color.alphaBlend(
      Colors.white.withValues(alpha: 0.14),
      Colors.black.withValues(alpha: 0.28),
    );
    final lightFill = Colors.white.withValues(alpha: 0.64);
    final fill = Color.lerp(darkFill, lightFill, lightFactor)!;
    final borderColor = Color.lerp(
      Colors.white.withValues(alpha: 0.16),
      Colors.black.withValues(alpha: 0.08),
      lightFactor,
    )!;

    final inner = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: borderRadius,
        border: Border.all(color: borderColor, width: 0.75),
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );

    final noBlur =
        tokens.powerSaving ||
        PerfFlags.noBackdrop ||
        DebugToggles.of(context).isOff(DebugToggle.glassBackdrop);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x24000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: noBlur
            ? inner
            : ValueListenableBuilder<bool>(
                valueListenable: DesktopWindow.fullscreenTransition,
                builder: (context, transitioning, _) {
                  if (transitioning) return inner;
                  return BackdropFilter.grouped(
                    filter: ImageFilter.blur(
                      sigmaX: 18,
                      sigmaY: 18,
                      tileMode: TileMode.mirror,
                    ),
                    child: inner,
                  );
                },
              ),
      ),
    );
  }
}

/// 两侧 48dp 半透明玻璃圆钮（`J0.f63618a = 48`）：左 `i` 信息、右 `☆/★` 关注。
class _HeroSideCircleButton extends StatelessWidget {
  final Key? buttonKey;
  final String tooltip;
  final VoidCallback onPressed;
  final Widget child;

  const _HeroSideCircleButton({
    this.buttonKey,
    required this.tooltip,
    required this.onPressed,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final noBlur =
        tokens.powerSaving ||
        PerfFlags.noBackdrop ||
        DebugToggles.of(context).isOff(DebugToggle.glassBackdrop);

    final body = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: buttonKey,
          customBorder: const CircleBorder(),
          mouseCursor: SystemMouseCursors.click,
          onTap: onPressed,
          child: SizedBox.square(dimension: 48, child: Center(child: child)),
        ),
      ),
    );

    return Tooltip(
      message: tooltip,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: ClipOval(
          child: noBlur
              ? body
              : ValueListenableBuilder<bool>(
                  valueListenable: DesktopWindow.fullscreenTransition,
                  builder: (context, transitioning, _) {
                    if (transitioning) return body;
                    return BackdropFilter.grouped(
                      filter: ImageFilter.blur(
                        sigmaX: 20,
                        sigmaY: 20,
                        tileMode: TileMode.mirror,
                      ),
                      child: body,
                    );
                  },
                ),
        ),
      ),
    );
  }
}

/// 中央 72dp 纯白实心播放圆钮（`J0.f63619b = 72`，`artist_headerbutton_play.xml`）：
/// 内部三角形与双竖线采用整页背景色填充，呈现与 Apple Music 7.0 `evenOdd` 镂空完全一致的视觉效果。
class _ArtistHeroPlayButton extends StatelessWidget {
  final List<SpotifyTrack> tracks;
  final PlaybackContext playbackContext;
  final Color cutoutColor;

  const _ArtistHeroPlayButton({
    required this.tracks,
    required this.playbackContext,
    required this.cutoutColor,
  });

  @override
  Widget build(BuildContext context) {
    final uri = playbackContext.uri;
    final (isPlayingThis, isThisContext) = context
        .select<PlaybackProvider, (bool, bool)>(
          (p) => (p.isPlayingContext(uri), p.playbackContext.uri == uri),
        );
    final enabled = tracks.isNotEmpty;

    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 16,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Material(
          color: Colors.white,
          shape: const CircleBorder(),
          child: InkWell(
            key: const Key('artist-hero-play-button'),
            customBorder: const CircleBorder(),
            mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
            onTap: !enabled
                ? null
                : () {
                    final playback = context.read<PlaybackProvider>();
                    if (isPlayingThis || isThisContext) {
                      playback.togglePlayPause();
                    } else {
                      playback.playContext(tracks, playbackContext);
                    }
                  },
            child: SizedBox.square(
              dimension: 72,
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: child),
                  child: CustomPaint(
                    key: ValueKey<bool>(isPlayingThis),
                    size: const Size.square(72),
                    painter: _AppleArtistPlayPausePainter(
                      playing: isPlayingThis,
                      color: cutoutColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Apple Music 7.0 APK 矢量图标路径（直接提取自 `res/drawable/*.xml`）
// -----------------------------------------------------------------------------

class _AppleArtistInfoPainter extends CustomPainter {
  final Color color;

  const _AppleArtistInfoPainter({required this.color});

  static final Path _path = _parseSvgPath(
    'M20.055,29.554C20.058,29.863 20.159,30.109 20.358,30.293'
    'C20.557,30.477 20.823,30.569 21.157,30.569L27.072,30.569'
    'C27.409,30.569 27.677,30.477 27.876,30.293'
    'C28.075,30.109 28.176,29.863 28.18,29.554'
    'C28.183,29.239 28.084,28.988 27.884,28.803'
    'C27.685,28.617 27.414,28.525 27.072,28.525'
    'L25.437,28.525L25.437,21.756'
    'C25.437,21.432 25.341,21.175 25.147,20.986'
    'C24.954,20.797 24.699,20.702 24.382,20.702L21.449,20.702'
    'C21.107,20.702 20.837,20.795 20.638,20.98'
    'C20.439,21.166 20.341,21.416 20.344,21.732'
    'C20.346,22.04 20.447,22.286 20.646,22.47'
    'C20.846,22.654 21.114,22.746 21.449,22.746'
    'L23.263,22.746L23.263,28.525L21.157,28.525'
    'C20.819,28.525 20.55,28.617 20.35,28.803'
    'C20.15,28.988 20.052,29.239 20.055,29.554Z'
    'M22.511,17.115C22.511,17.39 22.578,17.641 22.711,17.868'
    'C22.844,18.095 23.022,18.274 23.246,18.406'
    'C23.47,18.538 23.722,18.604 24.001,18.604'
    'C24.28,18.604 24.531,18.538 24.755,18.406'
    'C24.98,18.274 25.158,18.095 25.291,17.868'
    'C25.424,17.641 25.489,17.39 25.486,17.115'
    'C25.486,16.836 25.42,16.582 25.289,16.354'
    'C25.157,16.126 24.98,15.946 24.755,15.813'
    'C24.531,15.681 24.28,15.615 24.001,15.615'
    'C23.722,15.615 23.47,15.681 23.246,15.813'
    'C23.022,15.946 22.844,16.126 22.711,16.354'
    'C22.578,16.582 22.511,16.836 22.511,17.115Z',
  );

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 48.0, size.height / 48.0);
    canvas.drawPath(_path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AppleArtistInfoPainter old) => old.color != color;
}

class _AppleArtistPlayPausePainter extends CustomPainter {
  final bool playing;
  final Color color;

  const _AppleArtistPlayPausePainter({
    required this.playing,
    required this.color,
  });

  static final Path _playTriangle = _parseSvgPath(
    'M27.155,21.396C26.506,21.396 25.966,21.629 25.536,22.096'
    'C25.106,22.563 24.891,23.201 24.891,24.011L24.891,47.695'
    'C24.891,48.505 25.106,49.142 25.536,49.606'
    'C25.966,50.07 26.506,50.302 27.155,50.302'
    'C27.491,50.302 27.815,50.247 28.125,50.138'
    'C28.436,50.028 28.78,49.865 29.157,49.647L48.711,38.285'
    'C49.382,37.898 49.873,37.523 50.184,37.16'
    'C50.495,36.797 50.651,36.36 50.651,35.847'
    'C50.651,35.339 50.495,34.903 50.184,34.538'
    'C49.873,34.172 49.382,33.796 48.711,33.409L29.157,22.059'
    'C28.78,21.841 28.436,21.676 28.125,21.564'
    'C27.815,21.452 27.491,21.396 27.155,21.396Z',
  );

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    canvas.save();
    canvas.scale(size.width / 72.0, size.height / 72.0);
    if (!playing) {
      canvas.drawPath(_playTriangle, paint);
    } else {
      const barRadius = Radius.circular(3.2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(25.2, 22.0, 7.6, 28.0),
          barRadius,
        ),
        paint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(39.2, 22.0, 7.6, 28.0),
          barRadius,
        ),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AppleArtistPlayPausePainter old) =>
      old.playing != playing || old.color != color;
}

class _AppleFavoriteStarPainter extends CustomPainter {
  final bool filled;
  final Color color;

  const _AppleFavoriteStarPainter({required this.filled, required this.color});

  static final Path _outlineStar = _parseSvgPath(
    'M16.3515,17.8467C16.7748,17.5313 16.8578,17 16.6254,16.311'
    'L14.9403,11.3057L19.2401,8.2261'
    'C19.8378,7.8027 20.0868,7.3213 19.9208,6.8149'
    'C19.7465,6.3169 19.2733,6.0679 18.5346,6.0762'
    'L13.2719,6.1177L11.6615,1.0791'
    'C11.4374,0.3735 11.0722,0 10.5409,0'
    'C10.0097,0 9.6361,0.3735 9.412,1.0791'
    'L7.81,6.1177L2.5307,6.0762'
    'C1.8085,6.0679 1.3271,6.3169 1.1527,6.8149'
    'C0.9784,7.3213 1.2441,7.8027 1.8334,8.2261'
    'L6.1332,11.3057L4.4482,16.311'
    'C4.2157,17 4.2987,17.5313 4.7221,17.8467'
    'C5.1537,18.1787 5.6767,18.0708 6.2743,17.6392'
    'L10.5409,14.5098L14.7992,17.6392'
    'C15.3969,18.0708 15.9198,18.1787 16.3515,17.8467Z'
    'M14.6249,15.564L11.0722,12.7998'
    'C10.682,12.4927 10.3915,12.4927 10.0014,12.7998'
    'L6.4486,15.564C6.4154,15.5806 6.3905,15.5972 6.3822,15.5806'
    'C6.3656,15.564 6.3656,15.5557 6.3822,15.5059'
    'L7.9013,11.2725C8.059,10.8076 8.0258,10.5586 7.5858,10.2681'
    'L3.8671,7.7363C3.8339,7.7197 3.8173,7.7031 3.8256,7.6782'
    'C3.8339,7.6616 3.8505,7.6533 3.892,7.6533L8.391,7.7778'
    'C8.8808,7.7944 9.1049,7.6616 9.246,7.1802'
    'L10.4911,2.8638C10.5077,2.814 10.516,2.8057 10.5409,2.8057'
    'C10.5575,2.8057 10.5658,2.814 10.5824,2.8638'
    'L11.8275,7.1802C11.9687,7.6616 12.1928,7.7944 12.6908,7.7778'
    'L17.1816,7.6533C17.2231,7.6533 17.248,7.6616 17.2563,7.6782'
    'C17.2563,7.7031 17.248,7.7114 17.2148,7.7363'
    'L13.4877,10.2681C13.0561,10.5586 13.0146,10.8076 13.1806,11.2725'
    'L14.6913,15.5059C14.7079,15.5557 14.7079,15.564 14.6913,15.5806'
    'C14.683,15.5972 14.6581,15.5806 14.6249,15.564Z',
  );

  static final Path _filledStar = _parseSvgPath(
    'M16.2007,17.4648C16.541,17.2075 16.6157,16.7842 16.4082,16.1782'
    'L14.6734,11.0151L19.106,7.8276'
    'C19.6206,7.4624 19.8281,7.0806 19.6953,6.6655'
    'C19.5625,6.2671 19.1724,6.0679 18.5332,6.0762'
    'L13.0962,6.1094L11.4444,0.9214'
    'C11.2451,0.3071 10.9463,0 10.5147,0'
    'C10.0913,0 9.7925,0.3071 9.5933,0.9214'
    'L7.9414,6.1094L2.5044,6.0762'
    'C1.8653,6.0679 1.4751,6.2671 1.3423,6.6655'
    'C1.2012,7.0806 1.417,7.4624 1.9317,7.8276'
    'L6.3643,11.0151L4.6294,16.1782'
    'C4.4219,16.7842 4.4966,17.2075 4.8369,17.4648'
    'C5.1773,17.7305 5.6089,17.6392 6.1236,17.2656'
    'L10.5147,14.0366L14.9141,17.2656'
    'C15.4287,17.6392 15.8521,17.7305 16.2007,17.4648Z',
  );

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 21.0, size.height / 18.0);
    canvas.drawPath(
      filled ? _filledStar : _outlineStar,
      Paint()..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AppleFavoriteStarPainter old) =>
      old.filled != filled || old.color != color;
}

final RegExp _svgToken = RegExp(r'[MLCZ]|[-+]?\d*\.?\d+');

/// 解析 Android VectorDrawable 中仅含绝对 `M` / `L` / `C` / `Z` 指令的路径字符串。
Path _parseSvgPath(String data) {
  final path = Path();
  final tokens = _svgToken.allMatches(data).map((m) => m.group(0)!).toList();
  var i = 0;
  var cmd = '';
  double nextNum() => double.parse(tokens[i++]);

  while (i < tokens.length) {
    final token = tokens[i];
    if (token == 'M' || token == 'L' || token == 'C' || token == 'Z') {
      cmd = token;
      i++;
      if (cmd == 'Z') {
        path.close();
        cmd = '';
      }
      continue;
    }
    switch (cmd) {
      case 'M':
        path.moveTo(nextNum(), nextNum());
        cmd = 'L';
      case 'L':
        path.lineTo(nextNum(), nextNum());
      case 'C':
        path.cubicTo(
          nextNum(),
          nextNum(),
          nextNum(),
          nextNum(),
          nextNum(),
          nextNum(),
        );
      default:
        i++;
    }
  }
  return path;
}
