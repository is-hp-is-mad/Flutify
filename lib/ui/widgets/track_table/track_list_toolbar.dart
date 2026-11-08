import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';
import '../../shell/shell_breakpoints.dart';
import '../menu/desktop_menu.dart';
import 'track_sort.dart';

/// 歌单页操作行右侧的工具（Spotify 桌面端风格）：🔍 歌单内搜索 · 「自定义顺序 ≡」排序 / 查看方式菜单。
///
/// - 搜索：点放大镜展开输入框并聚焦；失焦且没有内容时收起；Esc 清空并收起；
/// - 排序菜单：选中另一个字段按其自然方向排序，再选同一字段反向（与点列表头一致）；
/// - 查看方式（[onCompactChanged] 非空时显示，仅桌面表格）：列表 / 紧凑。
class TrackListToolbar extends StatefulWidget {
  final String query;
  final ValueChanged<String> onQueryChanged;
  final TrackSort sort;
  final ValueChanged<TrackSort> onSortChanged;

  /// 是否提供「添加日期」排序（自动生成的歌单没有加入时间）。
  final bool hasAddedAt;

  final bool compact;
  final ValueChanged<bool>? onCompactChanged;

  const TrackListToolbar({
    super.key,
    required this.query,
    required this.onQueryChanged,
    required this.sort,
    required this.onSortChanged,
    required this.hasAddedAt,
    this.compact = false,
    this.onCompactChanged,
  });

  /// 排序字段的显示名（菜单项与按钮文字共用）。
  static String sortLabel(AppLocalizations l10n, TrackSortKey key) => switch (key) {
    TrackSortKey.custom => l10n.trackSortCustom,
    TrackSortKey.title => l10n.trackColumnTitle,
    TrackSortKey.artist => l10n.trackColumnArtist,
    TrackSortKey.album => l10n.trackColumnAlbum,
    TrackSortKey.addedAt => l10n.trackColumnAddedAt,
    TrackSortKey.duration => l10n.trackColumnDuration,
  };

  @override
  State<TrackListToolbar> createState() => _TrackListToolbarState();
}

class _TrackListToolbarState extends State<TrackListToolbar> {
  static const double _fieldWidth = 220;

  late final TextEditingController _controller = TextEditingController(text: widget.query);
  final FocusNode _focus = FocusNode();
  late bool _open = widget.query.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(TrackListToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部清空（例如换了歌单）时同步输入框
    if (widget.query != _controller.text) _controller.text = widget.query;
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus && _controller.text.isEmpty && _open) setState(() => _open = false);
  }

  void _openSearch() {
    setState(() => _open = true);
    _focus.requestFocus();
  }

  void _closeSearch() {
    _controller.clear();
    widget.onQueryChanged('');
    _focus.unfocus();
    setState(() => _open = false);
  }

  Future<void> _showMenu(BuildContext anchorContext) async {
    final l10n = context.l10n;
    final sort = widget.sort;
    final keys = [
      for (final key in TrackSortKey.values)
        if (key != TrackSortKey.addedAt || widget.hasAddedAt) key,
    ];
    final picked = await DesktopMenu.show<String>(anchorContext, DesktopMenu.anchorOf(anchorContext), [
      DesktopMenu.heading(l10n.trackSortBy),
      for (final key in keys)
        DesktopMenu.check('sort:${key.name}', TrackListToolbar.sortLabel(l10n, key), checked: sort.key == key),
      if (widget.onCompactChanged != null) ...[
        DesktopMenu.divider,
        DesktopMenu.heading(l10n.trackViewAs),
        DesktopMenu.check('view:compact', l10n.trackViewCompact, checked: widget.compact),
        DesktopMenu.check('view:list', l10n.trackViewList, checked: !widget.compact),
      ],
    ]);
    if (picked == null || !mounted) return;
    if (picked.startsWith('view:')) {
      widget.onCompactChanged?.call(picked == 'view:compact');
      return;
    }
    final key = TrackSortKey.values.byName(picked.substring(5));
    // 再选当前字段：反向；自定义顺序没有方向
    final next = key == sort.key && key != TrackSortKey.custom
        ? TrackSort(key, descending: !sort.descending)
        : TrackSort.initial(key);
    widget.onSortChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;

    // 输入框本体：桌面 34 高（密集），触屏 44 高（手指点得到）。
    Widget field({required double height}) => SizedBox(
          height: height,
          child: CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closeSearch},
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              onChanged: widget.onQueryChanged,
              style: theme.textTheme.bodyMedium,
              textAlignVertical: TextAlignVertical.center,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: scheme.onSurface.withAlpha(20),
                hintText: l10n.trackSearchHint,
                contentPadding: EdgeInsets.zero,
                prefixIcon: Icon(Icons.search_rounded, size: 20, color: muted),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: muted,
                  tooltip: l10n.trackSearchClose,
                  onPressed: _closeSearch,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        );

    final search = AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: Alignment.centerRight,
      child: _open
          ? ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _fieldWidth),
              child: field(height: _fieldHeight(context)),
            )
          : IconButton(
              icon: const Icon(Icons.search_rounded),
              color: muted,
              tooltip: l10n.trackSearchHint,
              onPressed: _openSearch,
            ),
    );

    final sortButton = Builder(
      builder: (anchorContext) => TextButton(
        onPressed: () => _showMenu(anchorContext),
        style: TextButton.styleFrom(foregroundColor: muted, padding: const EdgeInsets.symmetric(horizontal: 10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                TrackListToolbar.sortLabel(l10n, widget.sort.key),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 6),
            Icon(widget.compact ? Icons.menu_rounded : Icons.format_list_bulleted_rounded, size: 20),
          ],
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // 空间紧张（被挤进窄槽位）：挤在排序键旁边只剩几十像素，手指点不进输入框。
        // 点开搜索后改为独占整行，收起后回到「搜索键 + 排序键」并排。
        final tight = constraints.maxWidth < 320;
        if (_open && tight) {
          return SizedBox(width: double.infinity, child: field(height: _fieldHeight(context)));
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 输入框优先：要多少占多少（封顶 _fieldWidth）；空间不够时排序键截断文字
            search,
            const SizedBox(width: 4),
            Flexible(child: sortButton),
          ],
        );
      },
    );
  }

  /// 输入框高度：桌面 34（密集），手机 44（触控目标不能小于它）。
  static double _fieldHeight(BuildContext context) =>
      MediaQuery.sizeOf(context).width < ShellBreakpoints.desktop ? 44 : 34;
}
