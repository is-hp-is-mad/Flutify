# Flutify 本地补丁

基于 flutter_inappwebview_windows 0.6.0（Apache-2.0，见 LICENSE）。只增加一个方法：

- WebView 方法通道 `flutifyAllowAudioOutputSelection({origin})`：通过
  `ICoreWebView2Profile4::SetPermissionState` 把 **本机回环来源**（`http://127.0.0.1:*` / `http://localhost:*`）
  的麦克风权限状态设为允许。Chromium 只有在来源持有该权限时才列出音频输出设备、允许
  `HTMLMediaElement.setSinkId`；设置权限状态本身不会打开任何采集设备。
  用于 EME（WebView2）播放时切换本机输出设备。非回环来源直接返回 false。

上游提供等价能力后可删除本目录并移除 pubspec 中的 dependency_overrides。
