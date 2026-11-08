import 'package:flutter/foundation.dart';

/// 桌面曲目表格的列配置；列表头（[TrackTableHeader]）与每一行（TrackTile）共用同一份，保证列对齐。
///
/// 列从左到右：序号 / 封面 · 标题（列表视图含艺人第二行）· 艺人（仅紧凑视图）· 专辑 · 添加日期 · 爱心 · 时长 · ⋯
///
/// 随宽度收起（与 Spotify 桌面端一致，越窄越先隐藏靠右的信息列）：
/// - 添加日期：宽度 ≥ [addedAtMinWidth] 且歌单有加入时间；
/// - 专辑：宽度 ≥ [albumMinWidth]；
/// - 艺人列：紧凑视图下宽度 ≥ [artistMinWidth]，更窄时艺人回到标题下方。
@immutable
class TrackTableColumns {
  /// 紧凑视图：没有封面、行更矮。
  final bool compact;
  final bool artist;
  final bool album;
  final bool addedAt;

  const TrackTableColumns({this.compact = false, this.artist = false, this.album = false, this.addedAt = false});

  static const double addedAtMinWidth = 880;
  static const double albumMinWidth = 640;
  static const double artistMinWidth = 560;

  /// 行左右内边距（与 TrackTile 一致）。
  static const double horizontalPadding = 16;

  /// 序号列宽（紧凑视图与列表头的「#」）；列表视图里这一格是 48 的封面。
  static const double indexWidth = 32;
  static const double coverWidth = 48;
  static const double leadGap = 14;
  static const double addedAtWidth = 120;
  static const double durationWidth = 52;

  /// 爱心 / ⋯ 按钮格（与 TrackTile 悬停按钮的固定格一致）。
  static const double actionWidth = 40;

  static const int titleFlex = 4;
  static const int artistFlex = 3;
  static const int albumFlex = 3;

  factory TrackTableColumns.forWidth(double width, {required bool compact, required bool hasAddedAt}) =>
      TrackTableColumns(
        compact: compact,
        artist: compact && width >= artistMinWidth,
        album: width >= albumMinWidth,
        addedAt: hasAddedAt && width >= addedAtMinWidth,
      );

  double get leadWidth => compact ? indexWidth : coverWidth;

  @override
  bool operator ==(Object other) =>
      other is TrackTableColumns &&
      other.compact == compact &&
      other.artist == artist &&
      other.album == album &&
      other.addedAt == addedAt;

  @override
  int get hashCode => Object.hash(compact, artist, album, addedAt);
}
