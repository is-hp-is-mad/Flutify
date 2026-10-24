import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override init() {
    super.init()
    // spotify: 链接（Info.plist 的 CFBundleURLTypes）。用 Apple Event 接收，不依赖
    // FlutterAppDelegate 是否实现 application(_:open:)；冷启动时链接也会先于窗口到达
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleGetURL(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL))
  }

  @objc private func handleGetURL(
    _ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor
  ) {
    guard let link = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
      return
    }
    NSApp.windows.first(where: { $0 is MainFlutterWindow })?.makeKeyAndOrderFront(self)
    NSApp.activate(ignoringOtherApps: true)
    SpotifyLinks.shared.deliver(link)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    // macOS 约定点窗口红灯只隐藏窗口（音乐继续在后台播放），点 Dock 图标恢复主窗口
    if !flag {
      sender.windows.first(where: { $0 is MainFlutterWindow })?.makeKeyAndOrderFront(self)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// 系统里点开的 spotify: 链接（通道 `flutify/protocol`，与 Windows / Android 同一套 Dart 逻辑）。
/// Dart 侧取过 initialLink 才算就绪，之前到达的链接先存着。
final class SpotifyLinks {
  static let shared = SpotifyLinks()

  private var channel: FlutterMethodChannel?
  private var pending: String?
  private var dartReady = false

  func attach(messenger: FlutterBinaryMessenger) {
    dartReady = false
    let channel = FlutterMethodChannel(name: "flutify/protocol", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "initialLink" {
        result(self.pending ?? "")
        self.pending = nil
        self.dartReady = true
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  func deliver(_ link: String) {
    guard dartReady, let channel = channel else {
      pending = link
      return
    }
    channel.invokeMethod("openLink", arguments: link)
  }
}
