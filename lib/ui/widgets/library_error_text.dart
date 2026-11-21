import '../../l10n/l10n.dart';
import '../../services/library/library_source.dart';

/// 媒体库读写失败的本地化提示；非 [LibrarySourceException] 原样显示异常说明。
String libraryErrorText(AppLocalizations l10n, Object error) {
  if (error is! LibrarySourceException) return '$error';
  final detail =
      error.detail ??
      (error.statusCode == null ? error.message : 'HTTP ${error.statusCode}');
  return switch (error.kind) {
    LibraryErrorKind.notSignedIn => l10n.libraryErrorNotSignedIn,
    LibraryErrorKind.readFailed => l10n.libraryErrorRead(detail),
    LibraryErrorKind.writeFailed => l10n.libraryErrorWrite(detail),
    LibraryErrorKind.badResponse => l10n.libraryErrorBadResponse(detail),
    LibraryErrorKind.partialWrite => l10n.libraryErrorPartial(detail),
  };
}
