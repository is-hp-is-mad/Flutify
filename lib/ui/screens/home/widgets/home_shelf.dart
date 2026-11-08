import 'package:flutter/material.dart';

import '../../../../models/home_feed.dart';
import '../../../widgets/cover_image.dart';
import '../../../widgets/expressive_card.dart';
import 'home_item_card.dart';
import 'home_section_header.dart';

/// 主页卡架：分区标题（可带艺人头像、副标题、「显示全部」）+ 横向滚动的卡片。
///
/// 卡片宽度随布局：桌面 [desktopCardWidth]、手机 [mobileCardWidth]；
/// 卡架高度由 [ExpressiveCard.heightFor] 按当前字号实测，字号放大不溢出。
class HomeShelf extends StatelessWidget {
  final HomeSection section;
  final bool desktop;
  final VoidCallback? onShowAll;

  const HomeShelf({super.key, required this.section, required this.desktop, this.onShowAll});

  static const double desktopCardWidth = 180;
  static const double mobileCardWidth = 148;

  @override
  Widget build(BuildContext context) {
    final cardWidth = desktop ? desktopCardWidth : mobileCardWidth;
    final height = ExpressiveCard.heightFor(context, cardWidth);
    final artist = section.headerArtist;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HomeSectionHeader(
          title: section.title,
          subtitle: section.subtitle,
          leading: artist == null
              ? null
              : SizedBox.square(
                  dimension: 44,
                  child: CoverImage(
                    url: artist.avatarUrl,
                    size: 44,
                    circular: true,
                    placeholderIcon: Icons.person_rounded,
                  ),
                ),
          onShowAll: section.hasMore ? onShowAll : null,
        ),
        SizedBox(
          height: height,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            // 卡片自带 6px 内边距：左侧补到与标题对齐
            padding: const EdgeInsets.symmetric(horizontal: 10),
            itemCount: section.items.length,
            itemBuilder: (context, index) =>
                HomeItemCard(item: section.items[index], width: cardWidth, margin: const EdgeInsets.only(right: 4)),
          ),
        ),
      ],
    );
  }
}
