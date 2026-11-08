import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// 界面文案入口：组件内统一写 `context.l10n.xxx`。
///
/// 规则：
/// * 所有用户可见文案都来自 ARB（lib/l10n/app_zh.arb 为模板），不在组件里硬编码；
/// * 服务层 / Provider 不依赖 BuildContext，其报错文案在 UI 层转换后再展示。
extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
