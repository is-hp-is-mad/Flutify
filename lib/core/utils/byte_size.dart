/// 字节数的人类可读格式（设置页缓存占用）。
///
/// 规则：1024 进制；< 1 MB 显示 KB（取整），< 1 GB 显示 MB（取整），否则 GB（一位小数，整数时省略小数）。
/// 单位用 KB / MB / GB，中英文界面通用。
class ByteSize {
  ByteSize._();

  static const int kb = 1024;
  static const int mb = 1024 * kb;
  static const int gb = 1024 * mb;

  static String format(int bytes) {
    if (bytes < mb) return '${(bytes / kb).round()} KB';
    if (bytes < gb) return '${(bytes / mb).round()} MB';
    final value = bytes / gb;
    final text = value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return '$text GB';
  }
}
