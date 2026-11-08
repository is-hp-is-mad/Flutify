# hyper_glass（Flutify 内置）

来源：`D:\miuiweather\flutter\hyper_showcase\packages\hyper_glass`（2026-11-01 初次同步，2026-11-08 对齐 2026-11-07 Debug 编译版）。旧来源 `flutter/hyper_glass` 已停止更新。上游规则看它旁边的 `PORTING.md`（第 4 节使用规则、第 7 节内存规则）。

同步方法：拷 `lib/` 与 `shaders/`（不拷 `shader_layout.g.dart` 以外的生成脚本），再按下面逐条重做。上游的 `test/errors_test.dart` 里「shadow before init」与这里的改动 6 冲突，不拷。

## 2026-11-08 对齐与完善点（Debug 编译版）

1. **`mi_blend_blur.frag` 渐变混色模糊升级**：
   - 接入原生 `uGradientBlur`（基于 ROM `019_3917.sksl`）与 `uOverlayMask`（17 段 `OverlayMaskConfig` 平滑 alpha 衰减曲线 `overlayMaskFactor`）。
   - 支持三路采样插值（sharp 0dp -> mid ~10dp -> full blur 40/60dp）。
   - `HyperBlendBlur` 与 `HyperPage` 现可直接通过 `gradientBlur: true` 与 `overlayMask: ...` 原生呈现顶栏渐变模糊，无需层层叠加裁剪遮罩。
2. **GPU 跨帧延期安全释放（`deferDispose`）**：
   - 在 `HyperGlassRenderer` 中实现 `deferDispose({image, shader})` 双代缓存，防止 `Picture.toImageSync` 等中间资源在光栅线程绘制完成前被过早释放导致黑屏、撕裂或崩溃。
   - 在 `view_shadow.dart`、`hyper_glass.dart`、`hyper_glass_renderer.dart` 全面接入。
3. **`HyperGlassScene` 调度防漏机制**：
   - 新增 `_dirty` 标记：在后台快照运行中若发生新调度，帧回调自动排队补发，解决动画中状态丢帧。
4. **原生 ROM 桥接引入与多档原生渲染模式对齐**：
   - 引入 `native_rom.dart`（`HyperNativeRom` 与 `HyperRenderController`），支持三种渲染模式：小米原生（`xiaomi_native`）、小米移植（`xiaomi_port`）、纯移植（`flutter_port`）。
   - `HyperRenderController` 支持设备能力查询（`getCapabilities`）与切换底层管线（`setPortBackend`）。
   - `HyperGlass` 与 `HyperBlendBlur` 在 Android 端接入 `HyperNativeRomSurface`，支持 `updateSurface` 动态刷新材质与参数。

## 相对来源的改动

### `lib/src/hyper_glass.dart`

1. `HyperGlassScene.captureScale`：玻璃场景的截取分辨率，给没有细节的背景用（播放页 0.25）。只有 Skia 融合路径的滤镜生效，其他情况退回 1。`fusedGlassShader` 的 `backdropScale` 与之配套。
2. `HyperGlassScene.isIn(context)`：`LiquidGlass` 据此选择柔光玻璃或混色模糊。
3. 场景不拥有渲染器：用 `HyperGlassRenderer.shared()`，`dispose` 时不释放（SDF 缓存全进程共用，进出场景不重建）。shader 加载失败只打日志。
4. `HyperGlass` / `HyperBlendBlur` 的 Stack 用 `StackFit.passthrough`（上游是 `expand`）：`LiquidGlass` 包的是自适应内容，`expand` 会把它们撑满。
5. `_captureInPaint`：上游在 `scale < 1` 时跳过同步截取；有了 `captureScale` 后改成「只有全是混色表面才跳过」，玻璃表面在第一帧就画完整。首帧保活的 3 秒定时器可取消（否则 widget 测试报定时器未触发）。

### `lib/src/view_shadow.dart`

6. 去掉 `program != null` 的 assert：shader 未载入时不画阴影（测试环境、切换材质后的头几帧）。
7. `hollow`：阴影不画在子组件下方。`BackdropFilter` 子组件会把阴影模糊进自己，表面整体发灰。

### `lib/src/hyper_glass_renderer.dart`

8. `shared()` / `ready`：全进程一个渲染器（上游的 `ready` 每次新建）。
9. `_loadPrograms` 逐个加载并写耗时日志（`debugPrint`，Flutify 转存到日志文件）。
10. `_warmUp`（Skia）：滤镜可融合时不预热 LM 下采样 / 模糊 / 上采样，这条路径用不到。
11. `warmOnscreen` 不预热按压光：Flutify 没用它。
12. `canFuse(filter)`、`paintBloom(...)`：后者给场景外的 `HyperBlendSurface` 画 Bloom（Impeller 走离屏，与 `_paintOverlays` 同样的原因）。

### `lib/src/ui/arc_menu.dart`

13. 几何抽成 `ArcMotion.frame(anchor, menu, endRadius:)`：`HyperMenuRoute` 用 `BackdropFilter` 表面，不能直接用 `ArcMenu`，但要同一套几何。`ArcMenu` 也改用它，行为不变。
14. 菜单项外包透明 `Material`：修正悬停 / 水波纹画在远处祖先上导致的错位。

### `lib/src/ui/bottom_bar.dart`

- `HyperBottomBar.surface`：由宿主画胶囊表面（`HyperBlendSurface`），此时不再自己定位到父组件底部。Flutify 的底栏不在场景里。
- 胶囊可拖动：跟手移动，松手落到最近一项。上游的 PORTING 记着这项未做。

### shader

15. `mi_glass_v13_f16.frag` / `mi_lm_upsample_tint.frag`：本移植里恒定的开关改成编译期常量（HDR、遮罩贴图、图标光、旋转、色彩空间为 0，着色开关为 1），Skia 在交给 ANGLE 前就能删掉分支；uniform 仍声明，布局不变。`uHit` 上游用浮点、没有分支，不动。因此 `GlassFx.rotation` 和 `iconRect` 在这里不生效，要用时先恢复对应的 `#define`。

## 不移植的部分

- `HyperOverlay`（整页外层场景）：菜单和弹窗走 `HyperBlendSurface` + `BackdropFilter`，不做整窗截取。
- `ArcMenu` 收起时内容模糊到 30dp：动画里 sigma 连续变化，Skia 每种强度都要现编译程序。`HyperMenuRoute` 不做；设置页预览用的是 `ArcMenu` 本身，保留。
- `lib/src/morph_menu.dart` 已删。上游查明按钮变形只对应 `TransformAnimation`，下拉菜单是 `ArcAnimation`。

`hyper_ui.dart` 的控件（`HyperBottomBar`、`HyperDialogButton`、`FloatSurface` 等）随包同步，Flutify 目前只用到 `Hy`、`ArcMotion`、`ArcMenu`、`menuRectFor`、`HyperTheme`。
