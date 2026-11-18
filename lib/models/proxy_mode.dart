/// 网络代理方式（设置 →「网络」）。
///
/// 独立成纯 Dart 文件（不依赖 Flutter）：命令行探针（tool/）需要经 [NetworkProxy] /
/// 接入点联网，若从 app_preferences.dart 引入本枚举会把整个 Flutter 依赖链拖进来。
enum ProxyMode { system, none, manual }
