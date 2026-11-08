import 'package:flutter/material.dart';

import '../../hyper_glass.dart';
import 'kit.dart';
import 'theme.dart';

/// A page: large title in the list, FloatingBar once scrolled, own scene so the bar blurs the list under it.
class HyperPage extends StatefulWidget {
  const HyperPage({super.key, required this.title, required this.children, this.onBack, this.bottomPadding = 120, this.top, this.overlay});
  final String title;
  final List<Widget> children;
  final VoidCallback? onBack;
  final double bottomPadding;

  /// The status bar's height by default.
  final double? top;

  /// Drawn over the bar.
  final Widget? overlay;
  @override
  State<HyperPage> createState() => _HyperPageState();
}

class _HyperPageState extends State<HyperPage> {
  final _scroll = ScrollController();
  double _offset = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() => setState(() => _offset = _scroll.offset));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    final top = widget.top ?? MediaQuery.paddingOf(context).top;
    return Material(
      color: Hy.window(dark),
      child: HyperGlassScene(
        animate: false,
        background: ColoredBox(
          color: Hy.window(dark),
          child: ListView(
            controller: _scroll,
            padding: EdgeInsets.only(top: top + Hy.barHeight - 8, bottom: widget.bottomPadding),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
                child: Opacity(
                  opacity: 1 - ((_offset - 24) / 32).clamp(0.0, 1.0),
                  child: Text(
                    widget.title,
                    style: TextStyle(color: Hy.text(dark), fontSize: Hy.title1, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              ...widget.children,
            ],
          ),
        ),
        child: Stack(
          children: [
            FloatingBar(
              top: top,
              title: widget.title,
              offset: _offset,
              dark: dark,
              onBack: widget.onBack,
              maskColor: dark ? const Color(0xff000000) : const Color(0xfff3f3f3),
              maskBlur: Hy.actionBarBlur(dark),
            ),
            ?widget.overlay,
          ],
        ),
      ),
    );
  }
}

/// miuix_preference_category: a 13sp caption over its card.
class PrefCategory extends StatelessWidget {
  const PrefCategory(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
    child: Text(
      title,
      style: TextStyle(color: Hy.sub(HyperTheme.isDark(context)), fontSize: Hy.subtitle, fontWeight: FontWeight.w700),
    ),
  );
}

/// A preference card group (card_group_margin_bottom 12).
class PrefCard extends StatelessWidget {
  const PrefCard({super.key, required this.children, this.padding});
  final List<Widget> children;
  final EdgeInsets? padding;
  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Hy.rDemiBig),
        child: ColoredBox(
          color: Hy.card(dark),
          child: Padding(
            padding: padding ?? EdgeInsets.zero,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ),
    );
  }
}

class PrefIcon extends StatelessWidget {
  const PrefIcon(this.icon, this.color, {super.key});
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: 28,
    height: 28,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
    child: Icon(icon, color: Colors.white, size: 17),
  );
}

class PrefRow extends StatelessWidget {
  const PrefRow(this.title, {super.key, this.icon, this.color, this.summary, this.value, this.trailing, this.onTap, this.chevron = true});
  final String title;
  final IconData? icon;
  final Color? color;
  final String? summary, value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    return InkWell(
      onTap: onTap,
      highlightColor: Hy.pressed(dark),
      splashColor: Colors.transparent,
      hoverColor: Colors.transparent,
      child: ConstrainedBox(
        // miuix_preference_item: min height 56, 14dp above and below, 28dp from the screen edge
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              if (icon != null) ...[PrefIcon(icon!, color!), const SizedBox(width: 10)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(color: Hy.text(dark), fontSize: Hy.headline1, fontWeight: FontWeight.w500),
                    ),
                    if (summary != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          summary!,
                          style: TextStyle(color: Hy.sub(dark), fontSize: Hy.body2),
                        ),
                      ),
                  ],
                ),
              ),
              if (value != null)
                Text(
                  value!,
                  style: TextStyle(color: Hy.sub(dark), fontSize: Hy.body2),
                ),
              if (trailing != null)
                trailing!
              else if (chevron) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded, size: 21, color: Hy.hint(dark)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class HyCheck extends StatelessWidget {
  const HyCheck({super.key, required this.value, required this.onChanged, this.radio = false});
  final bool value, radio;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: value ? HyperTheme.primaryOf(context) : (dark ? const Color(0x33ffffff) : const Color(0x14000000)),
          borderRadius: BorderRadius.circular(radio ? 12 : 7),
        ),
        child: value ? const Icon(Icons.check_rounded, color: Colors.white, size: 17) : null,
      ),
    );
  }
}

/// HyperProgressSeekBar: a 28dp bar with a 14dp radius, filled from the start.
class HySeek extends StatelessWidget {
  const HySeek({super.key, required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    return LayoutBuilder(
      builder: (context, c) {
        void at(Offset p) => onChanged((p.dx / c.maxWidth).clamp(0.0, 1.0));
        return GestureDetector(
          onHorizontalDragUpdate: (d) => at(d.localPosition),
          onTapDown: (d) => at(d.localPosition),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              height: 28,
              color: dark ? const Color(0x33ffffff) : const Color(0x14000000),
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: value,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: HyperTheme.primaryOf(context), borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

enum HyButtonSize { normal, inline, tiny }

/// miuix Button: 50dp, inline 36dp, tiny 28dp; only the first keeps the 17sp button text.
class HyButton extends StatelessWidget {
  const HyButton(this.label, {super.key, this.primary = false, this.size = HyButtonSize.normal, this.onTap});
  final String label;
  final bool primary;
  final HyButtonSize size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    final (height, pad, font) = switch (size) {
      HyButtonSize.normal => (50.0, 24.0, 17.0),
      HyButtonSize.inline => (36.0, 20.0, 14.0),
      HyButtonSize.tiny => (28.0, 12.0, 13.0),
    };
    return Pressable(
      onTap: onTap,
      child: Container(
        height: height,
        padding: EdgeInsets.symmetric(horizontal: pad),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(height / 2),
          color: primary ? HyperTheme.primaryOf(context) : (dark ? const Color(0x1fffffff) : const Color(0x0f000000)),
        ),
        child: Text(
          label,
          style: TextStyle(color: primary ? Colors.white : Hy.text(dark), fontSize: font, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

/// FilterSortView: a 34dp thumb sliding in a 3dp padded track on dual leading/trailing springs (PILL_FAST / PILL_SLOW).
class HySegmented extends StatefulWidget {
  const HySegmented({super.key, required this.items, required this.index, required this.onChanged});
  final List<String> items;
  final int index;
  final ValueChanged<int> onChanged;
  @override
  State<HySegmented> createState() => _HySegmentedState();
}

class _HySegmentedState extends State<HySegmented> with TickerProviderStateMixin {
  late final _left = SpringValue(this, value: widget.index.toDouble());
  late final _right = SpringValue(this, value: widget.index + 1.0);
  late final _press = SpringValue(this, value: 0, damping: 0.85, response: 0.2);
  bool _dragging = false;

  @override
  void didUpdateWidget(HySegmented old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    _moveTo(widget.index, old.index);
  }

  void _moveTo(int i, int from) {
    final forward = i >= from;
    _left.to(i.toDouble(), damping: forward ? 0.75 : 0.7, response: forward ? 0.5 : 0.4);
    _right.to(i + 1.0, damping: forward ? 0.7 : 0.75, response: forward ? 0.4 : 0.5);
  }

  @override
  void dispose() {
    _left.dispose();
    _right.dispose();
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    return LayoutBuilder(
      builder: (context, c) {
        final n = widget.items.length;
        final w = (c.maxWidth - 6) / n;
        int hit(double dx) => ((dx - 3) / w).floor().clamp(0, n - 1);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            _press.to(1);
            final h = hit(d.localPosition.dx);
            if (h != widget.index) _moveTo(h, widget.index);
          },
          onTapUp: (d) {
            _press.to(0);
            final h = hit(d.localPosition.dx);
            if (h != widget.index) {
              widget.onChanged(h);
            } else {
              _moveTo(widget.index, widget.index);
            }
          },
          onTapCancel: () {
            if (_dragging) return;
            _press.to(0);
            _moveTo(widget.index, widget.index);
          },
          onHorizontalDragStart: (d) {
            _dragging = true;
            _press.to(1);
            final h = hit(d.localPosition.dx);
            if (h != widget.index) {
              _moveTo(h, widget.index);
              widget.onChanged(h);
            }
          },
          onHorizontalDragUpdate: (d) {
            final h = hit(d.localPosition.dx);
            if (h != widget.index) {
              _moveTo(h, widget.index);
              widget.onChanged(h);
            }
          },
          onHorizontalDragEnd: (_) {
            _dragging = false;
            _press.to(0);
            _moveTo(widget.index, widget.index);
          },
          onHorizontalDragCancel: () {
            if (!_dragging) return;
            _dragging = false;
            _press.to(0);
            _moveTo(widget.index, widget.index);
          },
          child: Container(
            height: 40,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: dark ? const Color(0x1fffffff) : const Color(0x0f000000),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Stack(
              children: [
                AnimatedBuilder(
                  animation: Listenable.merge([_left.c, _right.c, _press.c]),
                  builder: (_, _) {
                    final l = _left.value * w, r = _right.value * w;
                    final pw = (r - l).clamp(w, c.maxWidth - 6);
                    final p = _press.value.clamp(0.0, 1.0);
                    final sx = 1.0 - (6.0 / pw) * p;
                    final sy = 1.0 - (6.0 / 34.0) * p;
                    return Positioned(
                      left: l,
                      top: 0,
                      bottom: 0,
                      width: pw,
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.diagonal3Values(sx, sy, 1),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: dark ? const Color(0x33ffffff) : Colors.white,
                            borderRadius: BorderRadius.circular(17),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                Row(
                  children: [
                    for (final (i, l) in widget.items.indexed)
                      Expanded(
                        child: Center(
                          child: Text(
                            l,
                            style: TextStyle(
                              color: i == widget.index ? Hy.text(dark) : Hy.sub(dark),
                              fontSize: Hy.body2,
                              fontWeight: i == widget.index ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// FilterSortView2: 40dp chips with a 12dp gap.
class HyChips extends StatelessWidget {
  const HyChips({super.key, required this.items, required this.index, required this.onChanged});
  final List<String> items;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) => Pressable(
          onTap: () => onChanged(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: i == index ? HyperTheme.primaryOf(context).withValues(alpha: 0.14) : Hy.card(dark),
            ),
            child: Text(
              items[i],
              style: TextStyle(
                color: i == index ? HyperTheme.primaryOf(context) : Hy.text(dark),
                fontSize: Hy.body2,
                fontWeight: i == index ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Action bar text tabs: 20sp, the current one darker.
class HyTextTabs extends StatelessWidget {
  const HyTextTabs({super.key, required this.items, required this.index, required this.onChanged});
  final List<String> items;
  final int index;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    return Row(
      children: [
        for (final (i, l) in items.indexed)
          Padding(
            padding: const EdgeInsets.only(right: 24),
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                style: TextStyle(
                  fontFamily: DefaultTextStyle.of(context).style.fontFamily, // this widget replaces the inherited style
                  color: i == index ? Hy.text(dark) : Hy.hint(dark),
                  fontSize: Hy.title3,
                  fontWeight: FontWeight.w600,
                ),
                child: Text(l),
              ),
            ),
          ),
      ],
    );
  }
}

class HyField extends StatelessWidget {
  const HyField({super.key, required this.hint, this.search = false});
  final String hint;
  final bool search;
  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    return Container(
      height: search ? 44 : 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: dark ? const Color(0x1fffffff) : const Color(0x0f000000),
        borderRadius: BorderRadius.circular(search ? 22 : Hy.rCommon),
      ),
      child: Row(
        children: [
          if (search) ...[Icon(Icons.search_rounded, size: 20, color: Hy.hint(dark)), const SizedBox(width: 8)],
          Expanded(
            child: TextField(
              style: TextStyle(color: Hy.text(dark), fontSize: Hy.headline1),
              cursorColor: HyperTheme.primaryOf(context),
              decoration: InputDecoration.collapsed(
                hintText: hint,
                hintStyle: TextStyle(color: Hy.hint(dark)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
