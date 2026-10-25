# hyper_glass（Flutify 内置）

来源：`D:\miuiweather\flutter\hyper_glass`（小米天气 / HyperOS 柔光玻璃移植）。

相对来源的改动：

- shader 放在本 package 内，`HyperGlassRenderer.load()` 的资源路径加上 `packages/hyper_glass/` 前缀（`shader_layout.g.dart` 不改）。
- `HyperGlassScene` 加载 shader 失败时只打日志，不抛未处理异常（测试环境、旧显卡）。

- `lib/src/morph_menu.dart` 来自来源的 `lib/demo/morph_menu.dart`（菜单从按钮变形展开、HyperOS 弹簧），只改了 import。

同步来源时只拷 `lib/` 与 `shaders/`，再重做上面两处。
- `HyperGlassRenderer.shared()` / `ready`：全进程共用一个已预热的渲染器（含 SDF 缓存），`HyperGlassScene` 不再各自 load / dispose，进出场景不再卡顿。
- `HyperGlassScene.isIn(context)`：判断是否处在场景内（Flutify 的 `LiquidGlass` 据此选择柔光玻璃或混色模糊）。
- `MorphMenu` 菜单项外包一层透明 `Material`，修正悬停 / 水波纹画在远处祖先上导致的错位。
