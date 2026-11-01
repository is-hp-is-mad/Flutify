import 'package:flutter/material.dart';

import 'kit.dart';

/// What a host app can set for the controls. Light or dark comes from the app's [Theme] and the font from its
/// default text style, so a host needs this only to change the accent colour.
class HyperTheme extends InheritedWidget {
  const HyperTheme({super.key, this.primary, required super.child});

  /// miuix blue by default.
  final Color? primary;

  static bool isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

  static Color primaryOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HyperTheme>()?.primary ?? Hy.primary(isDark(context));

  @override
  bool updateShouldNotify(HyperTheme old) => old.primary != primary;
}
