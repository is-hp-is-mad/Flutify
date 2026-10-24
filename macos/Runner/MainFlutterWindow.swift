import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var cacheDirectories: CacheDirectories?
  private var trafficLightAligner: TrafficLightAligner?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    cacheDirectories = CacheDirectories(messenger: flutterViewController.engine.binaryMessenger)

    let messenger = flutterViewController.engine.binaryMessenger
    SystemProxyChannel.register(messenger: messenger)
    MediaControlsChannel.register(messenger: messenger)
    EditMenuChannel.register(messenger: messenger)
    MouseNavigationChannel.register(messenger: messenger)
    SpotifyLinks.shared.attach(messenger: messenger)

    // 交通灯垂直居中到自绘顶栏（高 56），窗口缩放 / 退出全屏后重新对齐
    trafficLightAligner = TrafficLightAligner(window: self)

    super.awakeFromNib()
  }
}

// NSOpenPanel grants access for this launch; bookmarks restore it next launch.
private class CacheDirectories {
  private let key = "FlutifyCacheDirectoryBookmarks"
  private var accessed: [String: URL] = [:]
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.flutify/cache_directories", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      do {
        switch call.method {
        case "restore":
          self.restore()
          result(nil)
        case "remember":
          guard let path = call.arguments as? String else {
            result(FlutterError(code: "invalid_path", message: "Missing directory path", details: nil))
            return
          }
          try self.remember(URL(fileURLWithPath: path, isDirectory: true))
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "directory_access", message: "Unable to retain directory access", details: nil))
      }
    }
  }

  private func remember(_ url: URL) throws {
    let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    var bookmarks = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
    bookmarks[url.path] = data
    UserDefaults.standard.set(bookmarks, forKey: key)
    if accessed[url.path] == nil && url.startAccessingSecurityScopedResource() {
      accessed[url.path] = url
    }
  }

  private func restore() {
    let bookmarks = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
    for (_, data) in bookmarks {
      do {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        if accessed[url.path] == nil && url.startAccessingSecurityScopedResource() {
          accessed[url.path] = url
        }
        if stale { try remember(url) }
      } catch {
        // CacheLocation falls back to AppData if the folder was removed/revoked.
      }
    }
  }

  deinit {
    for url in accessed.values { url.stopAccessingSecurityScopedResource() }
  }
}

/// 「编辑」菜单（Dart 侧 MacMenuBar._EditMenu）的原生半边：焦点在原生视图（登录页
/// WKWebView 等）时把 `copy:` 这类标准 selector 发给响应链。第一响应者属于 Flutter
///（FlutterView / 文本输入插件）或没有响应者时回 false，由 Dart 对 Flutter 焦点调用 Intent。
enum EditMenuChannel {
  private static let allowed: Set<String> = ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"]

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "flutify/edit_menu", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "perform", let name = call.arguments as? String, allowed.contains(name) else {
        result(FlutterMethodNotImplemented)
        return
      }
      let action = Selector(name)
      guard let target = NSApp.target(forAction: action, to: nil, from: nil) as AnyObject?,
            !isFlutterResponder(target)
      else {
        result(false)
        return
      }
      result(NSApp.sendAction(action, to: target, from: nil))
    }
  }

  /// 响应者是否属于 Flutter 自身（类名以 Flutter 开头，或者是 Flutter 视图里的非平台视图）。
  private static func isFlutterResponder(_ target: AnyObject) -> Bool {
    if NSStringFromClass(type(of: target)).hasPrefix("Flutter") { return true }
    // undo: / redo: 无视图响应时会落到窗口 / 应用本身：交给 Flutter 处理
    return target is NSWindow || target is NSApplication || target is NSWindowController
  }
}
/// 鼠标侧键前进 / 后退的原生兜底。
///
/// Logi Options+ 等鼠标驱动在 macOS 上把 MX 系列侧键作为「页面滑动」(NSEventTypeSwipe) 发送，
/// 只有实现了 `swipeWithEvent:` 的应用（Safari、Finder 等）能收到；Flutter 引擎不处理 swipe 事件，
/// 因此这里统一监听并转成 Dart 侧的内容历史导航（与顶栏 ‹ › 一致）。
enum MouseNavigationChannel {
  private static var monitor: Any?

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "flutify/mouse_navigation", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      // 只有原生 -> Dart 推送，没有 Dart -> 原生方法
      result(FlutterMethodNotImplemented)
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.swipe]) { event in
      // Logi Options+ 的「后退」发送左滑（deltaX +1），「前进」发送右滑（deltaX -1）；
      // 与 NSEvent.deltaX 的原始定义（-1 右滑 / +1 左滑）方向相反。
      if event.deltaX < 0 {
        channel.invokeMethod("forward", arguments: nil)
      } else if event.deltaX > 0 {
        channel.invokeMethod("back", arguments: nil)
      }
      // 消费事件：避免系统再对「页面滑动」做一次处理
      return nil
    }
  }
}
