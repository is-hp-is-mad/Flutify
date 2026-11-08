/// 主框架的响应式分档（按窗口逻辑宽度）。
///
/// | 宽度          | 布局                                           |
/// | ------------- | ---------------------------------------------- |
/// | < 800         | 移动端：底部导航 + 悬浮迷你播放器              |
/// | 800 – 1100    | 桌面：音乐库收起为 72px 图标栏 + 内容           |
/// | 1100 – 1280   | 桌面：音乐库 + 内容；右栏按需打开（浮于内容上） |
/// | ≥ 1280        | 桌面：完整三栏                                 |
class ShellBreakpoints {
  ShellBreakpoints._();

  static const double desktop = 800;
  static const double sidebarExpandable = 1100;
  static const double threeColumn = 1280;

  /// 音乐库栏宽度范围与收起宽度。
  static const double sidebarCollapsed = 72;
  static const double sidebarMin = 280;
  static const double sidebarMax = 420;
  static const double sidebarDefault = 320;

  /// 右侧「正在播放」栏宽度。
  static const double nowPlayingWidth = 340;

  /// 面板之间、面板与窗口边缘的间距。
  static const double gutter = 8;

  static bool isDesktop(double width) => width >= desktop;
}
