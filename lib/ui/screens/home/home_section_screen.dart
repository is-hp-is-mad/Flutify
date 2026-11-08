import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/home_feed.dart';
import '../../../services/spotify_api_service.dart';
import '../../shell/shell_breakpoints.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../../widgets/expressive_card.dart';
import 'widgets/home_item_card.dart';
import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/hyper_surface.dart';

/// 主页分区的「显示全部」：网格展示该分区的全部条目。
///
/// 先用主页上已有的条目立即渲染，再向服务端取完整列表替换（失败则保持已有条目）。
class HomeSectionScreen extends StatefulWidget {
  final HomeSection section;

  /// 打开时主页所处的筛选标签（同一分区在不同 facet 下内容不同）。
  final String facet;

  const HomeSectionScreen({super.key, required this.section, this.facet = ''});

  @override
  State<HomeSectionScreen> createState() => _HomeSectionScreenState();
}

class _HomeSectionScreenState extends State<HomeSectionScreen> {
  late HomeSection _section = widget.section;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    try {
      final full = await context.read<SpotifyApiService>().getHomeSection(widget.section.uri, facet: widget.facet);
      if (mounted && full.items.length > _section.items.length) setState(() => _section = full);
    } catch (_) {
      // 主页已换了一批推荐等情况：保留已有条目
    }
  }

  static const double _spacing = 4;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktop = ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width);
    final minCell = desktop ? 180.0 : 150.0;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: context.tokens.hyperMaterial
                ? Colors.transparent
                : null,
            flexibleSpace: context.tokens.hyperMaterial
                ? const HyperAppBarBackground()
                : null,
            title: Text(
              context.l10n.homeSectionTitle(_section.title),
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.crossAxisExtent;
                final columns = math.max(2, ((width + _spacing) / (minCell + _spacing)).floor());
                final cellWidth = (width - _spacing * (columns - 1)) / columns;
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: _spacing,
                    mainAxisSpacing: 8,
                    mainAxisExtent: ExpressiveCard.heightFor(context, cellWidth),
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) =>
                        HomeItemCard(item: _section.items[index], width: cellWidth, margin: EdgeInsets.zero),
                    childCount: _section.items.length,
                  ),
                );
              },
            ),
          ),
          const ContentBottomSpacer(),
        ],
      ),
    );
  }
}
