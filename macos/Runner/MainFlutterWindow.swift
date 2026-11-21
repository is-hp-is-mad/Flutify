import AVFoundation
import Cocoa
import CoreVideo
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var cacheDirectories: CacheDirectories?
  private var motionVideo: MotionVideoChannel?
  private var trafficLightAligner: TrafficLightAligner?
  override func awakeFromNib() {
    let project = FlutterDartProject()
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst())
    let flutterViewController = FlutterViewController(project: project)
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    cacheDirectories = CacheDirectories(messenger: flutterViewController.engine.binaryMessenger)
    motionVideo = MotionVideoChannel(
      registrar: flutterViewController.registrar(forPlugin: "MotionVideoPlugin")
    )

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

/// 静音循环视频原生纹理（艺人动态头图、发现流短视频、播放页 Canvas 封面）：
/// AVPlayer + AVPlayerItemVideoOutput 硬解输出 CVPixelBuffer 到 FlutterTexture。
final class MotionVideoChannel {
  private let textures: FlutterTextureRegistry
  private let channel: FlutterMethodChannel
  private let cacheDir: URL
  private var videos: [Int64: MacMotionVideo] = [:]

  init(registrar: FlutterPluginRegistrar) {
    self.textures = registrar.textures
    self.channel = FlutterMethodChannel(
      name: "com.flutify/motion_video",
      binaryMessenger: registrar.messenger
    )
    self.cacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("flutify_motion_video", isDirectory: true)
    try? FileManager.default.removeItem(at: cacheDir)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "create":
        let bytes = (args?["bytes"] as? FlutterStandardTypedData)?.data
        let urlString = args?["url"] as? String
        let playing = (args?["playing"] as? Bool) ?? true
        if (bytes == nil || bytes!.isEmpty) && (urlString == nil || urlString!.isEmpty) {
          result(FlutterError(code: "motion_video_args", message: "create requires bytes or url", details: nil))
          return
        }
        do {
          let id = try self.create(bytes: bytes, urlString: urlString, playing: playing)
          result(id)
        } catch {
          result(FlutterError(code: "motion_video", message: error.localizedDescription, details: nil))
        }
      case "setPlaying":
        if let id = (args?["id"] as? NSNumber)?.int64Value {
          let playing = (args?["playing"] as? Bool) ?? true
          self.videos[id]?.setPlaying(playing)
        }
        result(nil)
      case "dispose":
        if let id = (args?["id"] as? NSNumber)?.int64Value {
          self.videos.removeValue(forKey: id)?.release()
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func create(bytes: Data?, urlString: String?, playing: Bool) throws -> Int64 {
    let mediaUrl: URL
    let tempFile: URL?
    if let bytes = bytes, !bytes.isEmpty {
      try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
      let file = cacheDir.appendingPathComponent("\(UUID().uuidString).mp4")
      try bytes.write(to: file, options: .atomic)
      mediaUrl = file
      tempFile = file
    } else if let urlString = urlString, let parsed = URL(string: urlString) {
      mediaUrl = parsed
      tempFile = nil
    } else {
      throw NSError(domain: "MotionVideo", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid media source"])
    }

    let video = MacMotionVideo(
      mediaUrl: mediaUrl,
      tempFile: tempFile,
      playing: playing,
      textures: textures,
      channel: channel
    )
    let id = textures.register(video)
    video.start(id: id)
    videos[id] = video
    return id
  }

  deinit {
    for video in videos.values {
      video.release()
    }
    videos.removeAll()
  }
}

private final class MacMotionVideo: NSObject, FlutterTexture {
  private let output: AVPlayerItemVideoOutput
  private let item: AVPlayerItem
  private let player: AVPlayer
  private let tempFile: URL?
  private weak var textures: FlutterTextureRegistry?
  private weak var channel: FlutterMethodChannel?
  private let bufferLock = NSLock()
  private var latestBuffer: CVPixelBuffer?
  private var textureId: Int64 = 0
  private var wantPlaying: Bool
  private var sentReady = false
  private var reportedSize: CGSize = .zero
  private var timer: Timer?
  private var statusObserver: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var released = false

  init(
    mediaUrl: URL,
    tempFile: URL?,
    playing: Bool,
    textures: FlutterTextureRegistry,
    channel: FlutterMethodChannel
  ) {
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    self.output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
    let asset = AVURLAsset(url: mediaUrl)
    self.item = AVPlayerItem(asset: asset)
    self.item.add(self.output)
    self.player = AVPlayer(playerItem: self.item)
    self.player.isMuted = true
    self.player.volume = 0
    self.player.actionAtItemEnd = .none
    self.tempFile = tempFile
    self.wantPlaying = playing
    self.textures = textures
    self.channel = channel
    super.init()
  }

  func start(id: Int64) {
    self.textureId = id

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, !self.released else { return }
      let start = self.item.seekableTimeRanges.first?.timeRangeValue.start ?? .zero
      self.player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
        guard let self = self, !self.released else { return }
        if self.wantPlaying {
          self.player.play()
        }
      }
    }

    statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self, !self.released else { return }
        switch item.status {
        case .readyToPlay:
          if self.wantPlaying {
            self.player.play()
          }
        case .failed:
          self.channel?.invokeMethod(
            "error",
            arguments: ["id": self.textureId, "message": item.error?.localizedDescription ?? "AVPlayer failed"]
          )
        default:
          break
        }
      }
    }

    let pollTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      self?.pollFrame()
    }
    RunLoop.main.add(pollTimer, forMode: .common)
    timer = pollTimer

    if wantPlaying {
      player.play()
    }
  }

  private func pollFrame() {
    guard !released else { return }
    let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
    guard itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime),
          let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    else {
      return
    }

    bufferLock.lock()
    latestBuffer = pixelBuffer
    bufferLock.unlock()

    let w = CVPixelBufferGetWidth(pixelBuffer)
    let h = CVPixelBufferGetHeight(pixelBuffer)
    if w > 0 && h > 0 {
      let size = CGSize(width: w, height: h)
      if size != reportedSize {
        reportedSize = size
        channel?.invokeMethod(
          "size",
          arguments: ["id": textureId, "width": Double(w), "height": Double(h)]
        )
      }
    }

    textures?.textureFrameAvailable(textureId)

    if !sentReady {
      sentReady = true
      channel?.invokeMethod("ready", arguments: ["id": textureId])
    }
  }

  func setPlaying(_ playing: Bool) {
    guard !released else { return }
    wantPlaying = playing
    if playing {
      player.play()
    } else {
      player.pause()
    }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    guard let buf = latestBuffer else { return nil }
    return Unmanaged.passRetained(buf)
  }

  func release() {
    guard !released else { return }
    released = true
    timer?.invalidate()
    timer = nil
    statusObserver?.invalidate()
    statusObserver = nil
    if let obs = endObserver {
      NotificationCenter.default.removeObserver(obs)
      endObserver = nil
    }
    player.pause()
    item.remove(output)
    player.replaceCurrentItem(with: nil)
    if textureId != 0 {
      textures?.unregisterTexture(textureId)
    }
    bufferLock.lock()
    latestBuffer = nil
    bufferLock.unlock()
    if let file = tempFile {
      try? FileManager.default.removeItem(at: file)
    }
  }
}
