import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/home_feed.dart';
import '../../../../providers/library_provider.dart';
import '../../../widgets/expressive_card.dart';
import '../home_item_actions.dart';

/// 主页卡片：把 [HomeItem] 映射为 [ExpressiveCard]（标题 / 副标题 / 封面形状 / 点击与播放）。
class HomeItemCard extends StatelessWidget {
  final HomeItem item;
  final double width;
  final EdgeInsetsGeometry margin;

  const HomeItemCard({
    super.key,
    required this.item,
    required this.width,
    this.margin = const EdgeInsets.only(right: 14.0),
  });

  /// 卡片 / 快捷入口的主标题（「已点赞的歌曲」由界面语言决定）。
  static String titleOf(AppLocalizations l10n, HomeItem item) =>
      item.kind == HomeItemKind.likedSongs ? l10n.likedSongs : item.title;

  /// 副标题：服务端给了就用；艺人 / 播客 / 单集没有时显示类型。
  static String subtitleOf(AppLocalizations l10n, HomeItem item, {int likedCount = 0}) {
    if (item.kind == HomeItemKind.likedSongs) return l10n.songCount(likedCount);
    if (item.subtitle.isNotEmpty) return item.subtitle;
    return switch (item.kind) {
      HomeItemKind.artist => l10n.typeArtist,
      HomeItemKind.podcast => l10n.homeTypePodcast,
      HomeItemKind.episode => l10n.homeTypeEpisode,
      _ => '',
    };
  }

  /// 「已点赞的歌曲」统一用官方的渐变爱心封面。
  static const String likedSongsCover = 'https://misc.scdn.co/liked-songs/liked-songs-640.png';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final liked = item.kind == HomeItemKind.likedSongs;
    final likedCount = liked ? context.select<LibraryProvider, int>((l) => l.likedTracks.length) : 0;
    return ExpressiveCard(
      title: titleOf(l10n, item),
      subtitle: subtitleOf(l10n, item, likedCount: likedCount),
      imageUrl: liked ? likedSongsCover : item.imageUrl,
      isCircular: item.isCircular,
      width: width,
      margin: margin,
      onTap: () => HomeItemActions.open(context, item),
      onPlayTap: HomeItemActions.canPlay(item) ? () => HomeItemActions.play(context, item) : null,
    );
  }
}
