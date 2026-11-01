# tray_manager（Flutify 本地副本）

来源：pub.dev tray_manager 0.5.3。托盘只在 Windows 上用，删掉了 `linux/`、`macos/` 目录和 pubspec 里对应的平台：
上游在 Linux 上缺 appindicator 时直接 FATAL_ERROR，打进发行包后没装这个库的系统还启动不了。
