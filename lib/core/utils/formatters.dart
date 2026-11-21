import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';

/// 时间、数字与问候语的格式化。带单位的文案通过 [AppLocalizations] 取当前语言。
class Formatters {
  Formatters._();

  /// Format milliseconds into mm:ss or hh:mm:ss
  static String formatDurationMs(int? milliseconds) {
    if (milliseconds == null || milliseconds <= 0) return '0:00';
    return formatDuration(Duration(milliseconds: milliseconds));
  }

  /// Format Duration into mm:ss or hh:mm:ss
  static String formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// 歌单 / 专辑总时长：满 1 小时显示「1 小时 23 分钟」，否则「23 分 12 秒」（Spotify 格式）。
  static String formatLongDuration(AppLocalizations l10n, int milliseconds) {
    final d = Duration(milliseconds: milliseconds);
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    if (hours > 0) return l10n.durationHoursMinutes(hours, minutes);
    return l10n.durationMinutesSeconds(minutes, d.inSeconds.remainder(60));
  }

  /// 紧凑数字（粉丝数等）。
  ///
  /// 中文按万 / 亿进位，数字与单位间留半角空格（1.2 万、3.4 亿），不足一万显示千分位（8,532）；
  /// 其它语言使用 intl 的紧凑格式（1.2M）。
  static String formatCompactNumber(AppLocalizations l10n, int? number) {
    final n = number ?? 0;
    if (!l10n.localeName.startsWith('zh')) {
      return NumberFormat.compact(locale: l10n.localeName).format(n);
    }
    if (n < 10000) return NumberFormat.decimalPattern('zh').format(n);
    // 繁体用「萬 / 億」
    final hant = l10n.localeName.contains('Hant');
    final (value, unit) = n < 100000000
        ? (n / 10000, hant ? '萬' : '万')
        : (n / 100000000, hant ? '億' : '亿');
    // 保留一位小数，整数时省略「.0」
    final text = value >= 100 ? value.round().toString() : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
    return '$text $unit';
  }

  /// Spotify 发行日期（精度可能为 年 / 年-月 / 年-月-日）→ 当前语言的日期，如「2020年3月20日」。
  /// 无法解析时原样返回。日期符号由 GlobalMaterialLocalizations 加载。
  static String formatReleaseDate(AppLocalizations l10n, String raw) {
    final parts = raw.split('-').map(int.tryParse).toList();
    if (parts.isEmpty || parts.contains(null)) return raw;
    final date = DateTime(parts[0]!, parts.length > 1 ? parts[1]! : 1, parts.length > 2 ? parts[2]! : 1);
    try {
      return switch (parts.length) {
        1 => DateFormat.y(l10n.localeName).format(date),
        2 => DateFormat.yMMMM(l10n.localeName).format(date),
        _ => DateFormat.yMMMMd(l10n.localeName).format(date),
      };
    } catch (_) {
      return raw;
    }
  }

  /// 主页问候语：12 点前早上好，18 点前下午好，其余晚上好。
  static String getGreeting(AppLocalizations l10n) {
    final hour = DateTime.now().hour;
    if (hour < 12) return l10n.greetingMorning;
    if (hour < 18) return l10n.greetingAfternoon;
    return l10n.greetingEvening;
  }
}
