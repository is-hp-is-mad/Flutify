import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../models/share_target.dart';
import 'share_sheet.dart';

/// 详情页操作行里的分享按钮；内容没有公开链接（本地歌单、已点赞的歌曲）时不占位。
class ShareButton extends StatelessWidget {
  final ShareTarget target;

  const ShareButton({super.key, required this.target});

  @override
  Widget build(BuildContext context) {
    if (!target.isShareable) return const SizedBox.shrink();
    return IconButton(
      tooltip: context.l10n.commonShare,
      icon: const Icon(Icons.ios_share_rounded, size: 26),
      onPressed: () => ShareSheet.show(context, target),
    );
  }
}
