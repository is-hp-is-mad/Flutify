import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/category.dart';
import '../../../models/home_feed.dart';
import '../../../services/spotify_api_service.dart';
import '../../navigation/app_routes.dart';
import '../../shell/shell_breakpoints.dart';
import '../../widgets/content_bottom_spacer.dart';
import '../detail/widgets/collection_widgets.dart';
import '../home/widgets/home_shelf.dart';
import '../../../core/theme/flutify_tokens.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/hyper_surface.dart';

/// 分类页（browsePage）：分类下的分区卡架，与主页同一套卡片与点击行为。
///
/// 分区数据来自 Pathfinder `browsePage`（桌面会话）或公开 Web API 的分类歌单兜底；
/// 「显示全部」打开 [HomeSectionScreen]（分区整体网格）。
class CategoryScreen extends StatefulWidget {
  final SpotifyCategory category;

  const CategoryScreen({super.key, required this.category});

  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  List<HomeSection>? _sections;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _sections = null;
      _error = null;
    });
    try {
      final sections = await context.read<SpotifyApiService>().getBrowsePage(widget.category.id);
      if (mounted) setState(() => _sections = sections);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktop = ShellBreakpoints.isDesktop(MediaQuery.sizeOf(context).width);
    final sections = _sections;
    final error = _error;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            // 分类色只做轻微染色，标题可读性优先
            backgroundColor: context.tokens.hyperMaterial
                ? Colors.transparent
                : widget.category.color.withAlpha(36),
            flexibleSpace: context.tokens.hyperMaterial
                ? const HyperAppBarBackground()
                : null,
            title: Text(
              context.l10n.categoryName(widget.category.name, widget.category.id),
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (error != null)
            CollectionErrorPlaceholder(
              signedOut: identical(error, SpotifyDataException.notSignedIn),
              onRetry: _load,
            )
          else if (sections == null)
            const CollectionPlaceholder(loading: true)
          else if (sections.isEmpty)
            CollectionPlaceholder(message: context.l10n.categoryName(widget.category.name, widget.category.id), icon: Icons.category_rounded)
          else
            for (final section in sections)
              SliverToBoxAdapter(
                child: HomeShelf(
                  section: section,
                  desktop: desktop,
                  onShowAll: () => AppRoutes.openHomeSection(context, section),
                ),
              ),
          const ContentBottomSpacer(),
        ],
      ),
    );
  }
}
