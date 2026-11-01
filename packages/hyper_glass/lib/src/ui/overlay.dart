import 'dart:async';

import 'package:flutter/material.dart';

import '../../hyper_glass.dart';
import 'arc_menu.dart';
import 'kit.dart';
import 'theme.dart';

/// The layer above a page: the scene that lets popups blur it, and the popups themselves.
///
/// Put it around the app's pages, then reach it with [HyperOverlay.of]. [floating] holds what stays above the page,
/// such as a [HyperBottomBar].
class HyperOverlay extends StatefulWidget {
  const HyperOverlay({super.key, required this.child, this.floating});
  final Widget child;
  final Widget? floating;

  static HyperOverlayState of(BuildContext context) {
    final state = context.findAncestorStateOfType<HyperOverlayState>();
    if (state != null) return state;
    throw FlutterError('HyperOverlay.of was called from a context with no HyperOverlay above it.');
  }

  @override
  State<HyperOverlay> createState() => HyperOverlayState();
}

class HyperOverlayState extends State<HyperOverlay> with TickerProviderStateMixin {
  late final _arc = ArcMotion(this);
  Rect _anchor = Rect.zero;
  List<HyperMenuItem> _items = const [];
  double _menuWidth = 200;

  late final _dialog = SpringValue(this, damping: 0.86, response: 0.36);
  ({String title, String message, String cancel, String confirm, VoidCallback? onConfirm})? _dialogData;
  late final _dim = AnimationController(vsync: this);

  late final _sheet = AnimationController(vsync: this);
  late final _sheetDim = AnimationController(vsync: this);
  Widget? _sheetChild;
  double _sheetHeight = 300;

  late final _toast = SpringValue(this, damping: 0.8, response: 0.34);
  String _toastText = '';
  Timer? _toastTimer;

  bool _live = false;
  Timer? _liveTimer;

  @override
  void dispose() {
    _arc.dispose();
    _dialog.dispose();
    _dim.dispose();
    _sheet.dispose();
    _sheetDim.dispose();
    _toast.dispose();
    _toastTimer?.cancel();
    _liveTimer?.cancel();
    super.dispose();
  }

  /// Keeps floating surfaces sampling the page for a moment. Scrolling does this on its own; call it when the page
  /// changes some other way, as a tab switch or a page transition does.
  void refresh() {
    _liveTimer?.cancel();
    _liveTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _live = false);
    });
    if (!_live) setState(() => _live = true);
  }

  Rect _rectOf(BuildContext anchor) {
    final b = anchor.findRenderObject()! as RenderBox;
    final root = context.findRenderObject()! as RenderBox;
    return b.localToGlobal(Offset.zero, ancestor: root) & b.size;
  }

  void _open(Rect anchor, List<HyperMenuItem> items, double width) {
    setState(() {
      _anchor = anchor;
      _items = items;
      _menuWidth = width;
    });
    _arc.set(true);
  }

  /// A popup menu over [anchor], right-aligned with it.
  void menu(BuildContext anchor, List<HyperMenuItem> items, {double width = 200}) => _open(_rectOf(anchor), items, width);

  /// The popup of a Spinner: [anchor] is the row, and the value at its end opens the menu (gravity top|right).
  void select(BuildContext anchor, List<String> options, int selected, ValueChanged<int> onPick, {double width = 200}) {
    final row = _rectOf(anchor);
    _open(Rect.fromLTRB(row.right - 120, row.top, row.right, row.bottom), [
      for (final (i, o) in options.indexed)
        HyperMenuItem(o, () {
          onPick(i);
          closeMenu();
        }, selected: i == selected),
    ], width);
  }

  void closeMenu() {
    _arc.set(false);
    setState(() {});
  }

  // PopupWindowStrategy.getYInWindowAlignTop: Spinner uses gravity top, so the menu opens down from the anchor's
  // top. Only when it does not fit does it press against the bottom, or end at the anchor when the room is above.
  Rect _menuRect(Size screen) {
    const inset = 12.0;
    final height = ArcMenu.heightFor(_items.length);
    final x = _anchor.right - _menuWidth;
    final top = _anchor.top < inset ? inset : _anchor.top;
    if (top + height < screen.height - inset) return Rect.fromLTWH(x, top, _menuWidth, height);
    if (screen.height - _anchor.top >= _anchor.top) return Rect.fromLTWH(x, screen.height - inset - height, _menuWidth, height);
    return Rect.fromLTWH(x, _anchor.top - height, _menuWidth, height);
  }

  void dialog(String title, String message, {String cancel = '取消', String confirm = '确定', VoidCallback? onConfirm}) {
    setState(() => _dialogData = (title: title, message: message, cancel: cancel, confirm: confirm, onConfirm: onConfirm));
    _dialog.to(1, damping: 0.82, response: 0.3); // PhoneDialogAnim
    _dim.animateTo(1, duration: const Duration(milliseconds: 350), curve: const Decelerate(1.5));
  }

  void closeDialog() {
    _dialog.c.animateTo(0, duration: const Duration(milliseconds: 200), curve: const Decelerate(1.5));
    _dim.animateTo(0, duration: const Duration(milliseconds: 300), curve: const Decelerate(1.5)).whenComplete(() {
      if (mounted && _dim.value == 0) setState(() => _dialogData = null);
    });
  }

  // miuix_bottom_sheet_slide_in/out: 150ms, 20% of the screen and alpha
  void sheet(Widget child, {double height = 300}) {
    setState(() {
      _sheetChild = child;
      _sheetHeight = height;
    });
    _sheet.animateTo(1, duration: const Duration(milliseconds: 150), curve: const Cubic(0.4, 0, 1, 1));
    _sheetDim.animateTo(1, duration: const Duration(milliseconds: 350), curve: const Decelerate(1.5));
  }

  void closeSheet() {
    _sheet.animateTo(0, duration: const Duration(milliseconds: 150), curve: Curves.fastOutSlowIn);
    _sheetDim.animateTo(0, duration: const Duration(milliseconds: 300), curve: const Decelerate(1.5)).whenComplete(() {
      if (mounted && _sheetDim.value == 0) setState(() => _sheetChild = null);
    });
  }

  void toast(String text) {
    setState(() => _toastText = text);
    _toast.to(1);
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 1800), () => _toast.to(0));
  }

  Widget _toastLayer(bool dark) => AnimatedBuilder(
    animation: _toast.c,
    builder: (_, _) {
      final t = _toast.value.clamp(0.0, 1.0);
      if (t < 0.01) return const SizedBox.shrink();
      return Positioned(
        left: 0,
        right: 0,
        bottom: 80 + t * 22,
        height: 44,
        child: Center(
          child: Opacity(
            opacity: t,
            child: SizedBox(
              width: 40.0 + _toastText.length * 15,
              child: FloatSurface(
                radius: 22,
                child: Center(
                  child: Text(
                    _toastText,
                    style: TextStyle(color: Hy.text(dark), fontSize: Hy.body2),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _dialogLayer(bool dark) {
    final d = _dialogData;
    if (d == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: Listenable.merge([_dialog.c, _dim]),
      builder: (_, _) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: closeDialog,
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.3 * _dim.value)),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 24 - (1 - _dialog.value) * 260,
              height: 216,
              child: SizedBox.expand(
                // dialog-default has no ShadowToken
                child: HyperBlendBlur(
                  // dialog-default: Pured_Thin / Pured_Regular with mask blur 100, Glass_Stroke_Big
                  material: BlendMaterial(
                    sigma: 100,
                    layers: (dark ? BlendMaterial.popupMenuDark : BlendMaterial.popupMenuLight).layers,
                    fallback: Hy.card(dark),
                  ),
                  borderRadius: Hy.rBig,
                  bloom: dark ? BloomTokens.strokeSmallLight : BloomTokens.strokeBigLight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
                    child: Column(
                      children: [
                        Text(
                          d.title,
                          style: TextStyle(color: Hy.text(dark), fontSize: Hy.title4, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          child: Text(
                            d.message,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Hy.sub(dark), fontSize: Hy.body1, height: 1.45),
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(child: HyperDialogButton(d.cancel, onTap: closeDialog)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: HyperDialogButton(
                                d.confirm,
                                primary: true,
                                onTap: () {
                                  d.onConfirm?.call();
                                  closeDialog();
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sheetLayer(BoxConstraints c, bool dark) {
    final child = _sheetChild;
    if (child == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: Listenable.merge([_sheet, _sheetDim]),
      builder: (_, _) {
        final t = _sheet.value;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: closeSheet,
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.3 * _sheetDim.value)),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: -(1 - t) * c.maxHeight * 0.2,
              height: _sheetHeight,
              child: Opacity(
                opacity: t,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Hy.card(dark),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(Hy.rBig)),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(color: Hy.hint(dark), borderRadius: BorderRadius.circular(2)),
                      ),
                      Expanded(child: child),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    return NotificationListener<ScrollNotification>(
      onNotification: (_) {
        refresh();
        return false;
      },
      child: LayoutBuilder(
        builder: (context, c) => AnimatedBuilder(
          animation: _arc.listenable,
          builder: (context, _) => HyperGlassScene(
            animate: _live,
            background: widget.child,
            child: Material(
              type: MaterialType.transparency,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ?widget.floating,
                  _toastLayer(dark),
                  ArcMenu(motion: _arc, anchor: _anchor, menu: _menuRect(c.biggest), items: _items, onDismiss: closeMenu),
                  _sheetLayer(c, dark),
                  _dialogLayer(dark),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The 50dp pill buttons of dialogs and sheets.
class HyperDialogButton extends StatelessWidget {
  const HyperDialogButton(this.label, {super.key, this.primary = false, this.onTap});
  final String label;
  final bool primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = HyperTheme.isDark(context);
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 50,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(25),
          color: primary ? HyperTheme.primaryOf(context) : (dark ? const Color(0x1fffffff) : const Color(0x14000000)),
        ),
        child: Text(
          label,
          style: TextStyle(color: primary ? Colors.white : Hy.text(dark), fontSize: 17, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}
