import 'package:flutter/material.dart';

/// 滚动页末尾的留白（Sliver）。
///
/// 移动端的毛玻璃导航栏与悬浮迷你播放器盖在内容之上（Scaffold.extendBody），
/// 它们的总高度通过 MediaQuery 底部 padding 传下来；桌面端该值为 0，只留基础间距。
class ContentBottomSpacer extends StatelessWidget {
  const ContentBottomSpacer({super.key});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 32));
  }
}
