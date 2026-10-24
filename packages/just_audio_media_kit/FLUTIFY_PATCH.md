# Flutify 本地补丁

基于 just_audio_media_kit 2.1.0（public domain）。只增加了输出设备选择，其余保持上游原样：

- `JustAudioMediaKit.audioDevices()`：列出 libmpv 可用的输出设备；
- `JustAudioMediaKit.setAudioDevice(device)`：切换所有现有与之后新建播放器的输出设备（null = 系统默认）；
- `MediaKitPlayer.setOutputDevice` / `outputDevices`：上面两者的实现。

上游若提供等价 API，可删除本目录并改回 pub 依赖。
