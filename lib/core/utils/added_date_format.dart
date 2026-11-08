import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';

/// 「添加日期」列的文字（与 Spotify 桌面端一致）：
/// - 今天 → 「今天」；
/// - 1–6 天 → 「3 天前」；
/// - 1–4 周 → 「2 周前」；
/// - 更早 → 完整日期（「2026年9月1日」/「Sep 1, 2026」）。
///
/// 按自然日计算（昨晚 23 点加入的，今天看是「1 天前」）。
class AddedDateFormat {
  AddedDateFormat._();

  static String format(AppLocalizations l10n, DateTime addedAt, {DateTime? now}) {
    final today = _day(now ?? DateTime.now());
    final local = addedAt.toLocal();
    final days = today.difference(_day(local)).inDays;
    if (days <= 0) return l10n.addedToday;
    if (days < 7) return l10n.addedDaysAgo(days);
    if (days < 35) return l10n.addedWeeksAgo(days ~/ 7);
    return DateFormat.yMMMd(l10n.localeName).format(local);
  }

  // UTC 午夜：跨夏令时切换时日差仍是整数
  static DateTime _day(DateTime t) => DateTime.utc(t.year, t.month, t.day);
}
