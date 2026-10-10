import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/widgets.dart';

import 'player_lyrics_motion.dart';

enum PlayerSceneSlot {
  top,
  title,
  controls,
  footer,
  artwork,
  lyrics,
  toolbar,
  surface,
  queue,
}

/// Layout and clipping share the same measurements, including scaled text.
class PlayerLyricsGeometry {
  final Map<PlayerSceneSlot, Offset> _positions = {};
  double _footerTop = double.infinity;
  bool _retracting = false;

  Rect bodyClip(PlayerSceneSlot slot, Size size) => _retracting
      ? Rect.fromLTWH(
          0,
          0,
          size.width,
          (_footerTop - (_positions[slot]?.dy ?? 0)).clamp(0, size.height),
        )
      : Offset.zero & size;
}

/// The body slides below the fixed footer, clipped in paint AND hit testing.
class PlayerCardBodyClipper extends CustomClipper<Rect> {
  const PlayerCardBodyClipper({required this.geometry, required this.slot});

  final PlayerLyricsGeometry geometry;
  final PlayerSceneSlot slot;

  @override
  Rect getClip(Size size) => geometry.bodyClip(slot, size);

  // Geometry is filled during this frame's parent layout, after widget build.
  @override
  bool shouldReclip(PlayerCardBodyClipper oldClipper) => true;
}

/// Measures the controls first so text scaling never relies on a guessed height.
class PlayerLyricsLayout extends MultiChildLayoutDelegate {
  PlayerLyricsLayout({
    required this.progress,
    required this.chrome,
    required this.geometry,
    this.controlsHeightReduction = 0,
    this.footerHeightReduction = 0,
    this.lyricsProgress,
    this.queueProgress = 0,
  });

  final double progress;
  final double chrome;
  final PlayerLyricsGeometry geometry;
  final double controlsHeightReduction;
  final double footerHeightReduction;
  final double? lyricsProgress;
  final double queueProgress;

  void _position(PlayerSceneSlot slot, Offset position) {
    geometry._positions[slot] = position;
    positionChild(slot, position);
  }

  @override
  void performLayout(Size size) {
    const margin = 16.0;
    const inset = 12.0;
    final width = size.width;
    final landscape = width >= 600 && width > size.height;
    final cardWidth = landscape
        ? math.min(360.0, width * 0.46)
        : math.max(0.0, width - margin * 2);
    final cardLeft = width - margin - cardWidth;
    final contentWidth = landscape ? cardLeft - margin : width;
    final detailWidth = landscape ? cardWidth : width;
    final detailLeft = landscape ? cardLeft : 0.0;
    final controlsWidth = lerpDouble(detailWidth, cardWidth, progress)!;
    // Rows containing a Column must receive an unbounded vertical constraint
    // while measuring, just as they did inside the original player Column.
    const loose = BoxConstraints();
    final top = layoutChild(PlayerSceneSlot.top, loose.tighten(width: width));
    _position(PlayerSceneSlot.top, Offset.zero);
    final footer = layoutChild(
      PlayerSceneSlot.footer,
      loose.tighten(width: controlsWidth),
    );
    final controls = layoutChild(
      PlayerSceneSlot.controls,
      loose.tighten(width: controlsWidth),
    );
    final coverSize = width < 360 ? 56.0 : 64.0;
    // Recover both endpoint heights from the current, interpolated children.
    // Using their live height as BOTH endpoints makes the cover/text destination
    // drift while the scrubber compacts, creating a visible bend or reversal.
    final detailFooterHeight = footer.height + progress * footerHeightReduction;
    final cardFooterHeight = detailFooterHeight - footerHeightReduction;
    final detailControlsHeight =
        controls.height + progress * controlsHeightReduction;
    final cardControlsHeight = detailControlsHeight - controlsHeightReduction;
    final detailFooterY = size.height - detailFooterHeight;
    final cardFooterY = size.height - 8 - cardFooterHeight;
    final detailControlsY = detailFooterY - detailControlsHeight;
    final cardControlsY = cardFooterY - cardControlsHeight;
    final footerY = lerpDouble(detailFooterY, cardFooterY, progress)!;
    final controlsY = lerpDouble(detailControlsY, cardControlsY, progress)!;
    final contentTop = top.height + 8;
    // Metadata shares the cover's eased progress without a second timing curve
    // or a moving destination. It must never overshoot and then slide back.
    final titleStart = landscape ? cardLeft + inset : 24.0;
    final titleLeft = lerpDouble(
      titleStart,
      cardLeft + inset + coverSize + 12,
      progress,
    )!;
    final title = layoutChild(
      PlayerSceneSlot.title,
      loose.tighten(
        width: math.max(0, width - titleLeft - lerpDouble(12, 24, progress)!),
      ),
    );
    final headerHeight = math.max(coverSize, title.height);
    geometry._footerTop = footerY;
    final detailTitleY = detailControlsY - 8 - title.height;
    final headerY = cardControlsY - 8 - headerHeight;
    final surfaceY = headerY - inset;
    final hiddenOffset = (cardFooterY - surfaceY) * progress * (1 - chrome);
    geometry._retracting = hiddenOffset > 0;
    final surface = Rect.lerp(
      Rect.fromLTRB(
        detailLeft,
        detailTitleY - 8,
        detailLeft + detailWidth,
        size.height,
      ),
      Rect.fromLTRB(cardLeft, surfaceY, cardLeft + cardWidth, size.height - 8),
      progress,
    )!;
    final visibleSurface = Rect.fromLTRB(
      surface.left,
      surface.top + hiddenOffset,
      surface.right,
      surface.bottom,
    );
    layoutChild(
      PlayerSceneSlot.surface,
      BoxConstraints.tight(visibleSurface.size),
    );
    _position(PlayerSceneSlot.surface, visibleSurface.topLeft);
    final controlsLeft = lerpDouble(detailLeft, cardLeft, progress)!;
    _position(PlayerSceneSlot.footer, Offset(controlsLeft, footerY));
    _position(
      PlayerSceneSlot.controls,
      Offset(controlsLeft, controlsY + hiddenOffset),
    );
    _position(
      PlayerSceneSlot.title,
      Offset(
        titleLeft,
        lerpDouble(
              detailTitleY,
              headerY + (headerHeight - title.height) / 2,
              progress,
            )! +
            hiddenOffset,
      ),
    );

    final contentHeight = math.max(
      0.0,
      (landscape ? size.height - 16 : detailTitleY - 8) - contentTop,
    );
    final largeSize = math.min(
      math.min(contentWidth * 0.86, 400.0),
      contentHeight * 0.9,
    );
    final large = Rect.fromLTWH(
      (contentWidth - largeSize) / 2,
      contentTop + (contentHeight - largeSize) / 2,
      largeSize,
      largeSize,
    );
    final small = Rect.fromLTWH(
      cardLeft + inset,
      headerY + (headerHeight - coverSize) / 2,
      coverSize,
      coverSize,
    );
    // The controller already applies Apple easing. Interpolate the whole rect
    // once so its center follows a straight line while size changes in sync.
    final artwork = Rect.lerp(
      large,
      small,
      progress,
    )!.shift(Offset(0, hiddenOffset));
    layoutChild(PlayerSceneSlot.artwork, BoxConstraints.tight(artwork.size));
    _position(PlayerSceneSlot.artwork, artwork.topLeft);

    final toolbar = layoutChild(
      PlayerSceneSlot.toolbar,
      BoxConstraints.loose(Size(cardWidth, 48)),
    );
    final toolbarInHeader =
        landscape && surfaceY < top.height + toolbar.height + 8;
    _position(
      PlayerSceneSlot.toolbar,
      Offset(
        width - margin - toolbar.width - (toolbarInHeader ? 56 : 0),
        (toolbarInHeader ? 6 : surfaceY - 8 - toolbar.height) +
            16 * (1 - chrome),
      ),
    );

    if (hasChild(PlayerSceneSlot.lyrics)) {
      // Tall screens can scroll behind the floating card. Compact screens keep
      // the focused line above the controls. Folding never changes this size.
      final lyricsHeight = size.height < 600 && !landscape
          ? math.max(0.0, surfaceY - toolbar.height - 16 - contentTop)
          : math.max(0.0, size.height - contentTop);
      layoutChild(
        PlayerSceneSlot.lyrics,
        BoxConstraints.tight(Size(contentWidth, lyricsHeight)),
      );
      _position(
        PlayerSceneSlot.lyrics,
        Offset(
          0,
          contentTop + (1 - (lyricsProgress ?? progress)) * lyricsHeight,
        ),
      );
    }
    layoutChild(
      PlayerSceneSlot.queue,
      BoxConstraints.tight(
        Size(
          contentWidth,
          // Reveal rows in the space released by the retracting card. The top
          // and row widths stay fixed, preserving the list's scroll anchor.
          landscape
              ? contentHeight
              : math.max(0, surfaceY + hiddenOffset - 8 - contentTop),
        ),
      ),
    );
    _position(
      PlayerSceneSlot.queue,
      Offset(0, contentTop + PlayerQueueMotion.rise * (1 - queueProgress)),
    );
  }

  @override
  bool shouldRelayout(PlayerLyricsLayout oldDelegate) =>
      progress != oldDelegate.progress ||
      chrome != oldDelegate.chrome ||
      lyricsProgress != oldDelegate.lyricsProgress ||
      queueProgress != oldDelegate.queueProgress ||
      controlsHeightReduction != oldDelegate.controlsHeightReduction ||
      footerHeightReduction != oldDelegate.footerHeightReduction ||
      geometry != oldDelegate.geometry;
}
