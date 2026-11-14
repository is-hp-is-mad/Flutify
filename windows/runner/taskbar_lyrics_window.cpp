#include "taskbar_lyrics_window.h"

#include <shellapi.h>
#include <shlwapi.h>

#include <cmath>

using taskbar_lyrics::Event;
using Button = TaskbarLyricsPainter::Button;

namespace {

constexpr wchar_t kHostClass[] = L"FlutifyTaskbarLyricsHost";
constexpr wchar_t kLyricClass[] = L"FlutifyTaskbarLyrics";
constexpr UINT_PTR kTimerId = 1;
constexpr UINT kWakeMessage = WM_APP + 1;

// 切句上滚动画时长；歌词提前切行量（与 App 内歌词视图一致，抵消进度推送与动画的延迟）。
constexpr ULONGLONG kAnimMs = 300;
constexpr int64_t kLeadMs = 300;

// 菜单命令。
enum MenuCommand : UINT { kMenuOpen = 1, kMenuRefetch, kMenuDisable };

bool PointIn(const Gdiplus::Rect& r, POINT p) {
  return p.x >= r.X && p.x < r.X + r.Width && p.y >= r.Y && p.y < r.Y + r.Height;
}

bool SystemUsesLightTheme() {
  DWORD value = 0;
  DWORD size = sizeof(value);
  return RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                      L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size) == ERROR_SUCCESS &&
         value != 0;
}

// 截取屏幕矩形为 32bpp 像素（自上而下，0xAARRGGBB）。失败返回空。
std::vector<uint32_t> CaptureScreen(int left, int top, int width, int height) {
  std::vector<uint32_t> pixels;
  if (width <= 0 || height <= 0) return pixels;
  HDC screen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(info.bmiHeader);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  void* bits = nullptr;
  HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bitmap) {
    HGDIOBJ old = SelectObject(mem, bitmap);
    if (BitBlt(mem, 0, 0, width, height, screen, left, top, SRCCOPY)) {
      const auto* p = static_cast<const uint32_t*>(bits);
      pixels.assign(p, p + static_cast<size_t>(width) * height);
    }
    SelectObject(mem, old);
    DeleteObject(bitmap);
  }
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);
  return pixels;
}

int Luma(uint32_t c) { return (((c >> 16) & 255) * 299 + ((c >> 8) & 255) * 587 + (c & 255) * 114) / 1000; }

}  // namespace

TaskbarLyricsWindow::TaskbarLyricsWindow(HWND app_window, taskbar_lyrics::Shared* shared)
    : app_window_(app_window), shared_(shared) {
  dark_text_ = SystemUsesLightTheme();
  // 等宿主窗口建好（或创建失败）再返回，之后 Wake / 析构才能投递消息
  HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  thread_ = std::thread([this, ready] { ThreadMain(ready); });
  WaitForSingleObject(ready, INFINITE);
  CloseHandle(ready);
}

TaskbarLyricsWindow::~TaskbarLyricsWindow() {
  if (HWND host = host_.load()) PostMessageW(host, WM_CLOSE, 0, 0);
  if (thread_.joinable()) thread_.join();
}

void TaskbarLyricsWindow::Wake() {
  if (HWND host = host_.load()) PostMessageW(host, kWakeMessage, 0, 0);
}

void TaskbarLyricsWindow::ThreadMain(HANDLE ready) {
  HINSTANCE instance = GetModuleHandleW(nullptr);
  static bool registered = false;
  if (!registered) {
    WNDCLASSW host_class{};
    host_class.lpfnWndProc = HostProc;
    host_class.hInstance = instance;
    host_class.lpszClassName = kHostClass;
    RegisterClassW(&host_class);
    WNDCLASSW lyric_class{};
    lyric_class.lpfnWndProc = LyricProc;
    lyric_class.hInstance = instance;
    lyric_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    lyric_class.lpszClassName = kLyricClass;
    RegisterClassW(&lyric_class);
    registered = true;
  }

  painter_ = std::make_unique<TaskbarLyricsPainter>();
  HWND host = CreateWindowExW(WS_EX_TOOLWINDOW, kHostClass, L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, instance,
                              this);
  host_ = host;
  SetEvent(ready);  // 此后不得再使用 ready（构造函数随即关闭它）
  if (!host) {
    painter_.reset();
    return;
  }
  locator_.Start();
  SetInterval(100);
  Tick();

  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }

  locator_.Stop();
  art_.reset();
  painter_.reset();
  if (surface_dc_) {
    SelectObject(surface_dc_, surface_old_);
    DeleteObject(surface_bitmap_);
    DeleteDC(surface_dc_);
  }
}

LRESULT CALLBACK TaskbarLyricsWindow::HostProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self = reinterpret_cast<TaskbarLyricsWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) {
    switch (message) {
      case WM_TIMER:
      case kWakeMessage:
        self->Tick();
        return 0;
      case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
      case WM_DESTROY:
        KillTimer(hwnd, kTimerId);
        if (self->lyric_) DestroyWindow(self->lyric_);
        self->lyric_ = nullptr;
        self->host_ = nullptr;
        PostQuitMessage(0);
        return 0;
    }
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK TaskbarLyricsWindow::LyricProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self = reinterpret_cast<TaskbarLyricsWindow*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) return self->OnLyricMessage(hwnd, message, wparam, lparam);
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT TaskbarLyricsWindow::OnLyricMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;  // 点击不抢焦点
    case WM_SETCURSOR:
      if (control_active_ && hovered_button_ != Button::kNone) {
        SetCursor(LoadCursorW(nullptr, IDC_HAND));
        return TRUE;
      }
      break;
    case WM_LBUTTONUP: {
      const POINT p{static_cast<short>(LOWORD(lparam)), static_cast<short>(HIWORD(lparam))};
      if (!control_active_) {
        Post(Event::kOpen);
      } else if (PointIn(layout_.previous, p)) {
        Post(Event::kPrevious);
      } else if (PointIn(layout_.play, p)) {
        Post(Event::kToggle);
      } else if (PointIn(layout_.next, p)) {
        Post(Event::kNext);
      } else if (PointIn(layout_.info, p)) {
        Post(Event::kOpen);
      }
      return 0;
    }
    case WM_RBUTTONUP:
      ShowMenu();
      return 0;
    case WM_NCDESTROY:
      // 资源管理器重启时任务栏连同子窗口一起销毁：下一帧重建
      if (lyric_ == hwnd) lyric_ = nullptr;
      frame_signature_.clear();
      break;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

void TaskbarLyricsWindow::Post(Event event) { PostMessageW(app_window_, taskbar_lyrics::kEventMessage, static_cast<WPARAM>(event), 0); }

void TaskbarLyricsWindow::ShowMenu() {
  HWND host = host_.load();
  if (!host) return;
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kMenuOpen, labels_.open.c_str());
  AppendMenuW(menu, MF_STRING, kMenuRefetch, labels_.refetch.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kMenuDisable, labels_.disable.c_str());
  POINT pt;
  GetCursorPos(&pt);
  // 菜单所有者须为前台窗口，否则点别处菜单不消失（托盘菜单的标准做法）
  SetForegroundWindow(host);
  const UINT command = static_cast<UINT>(
      TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY | TPM_BOTTOMALIGN, pt.x, pt.y, host,
                       nullptr));
  PostMessageW(host, WM_NULL, 0, 0);
  DestroyMenu(menu);
  switch (command) {
    case kMenuOpen:
      Post(Event::kOpen);
      break;
    case kMenuRefetch:
      Post(Event::kRefetch);
      break;
    case kMenuDisable:
      Post(Event::kDisable);
      break;
  }
}

void TaskbarLyricsWindow::SetInterval(UINT ms) {
  if (ms == interval_) return;
  interval_ = ms;
  if (HWND host = host_.load()) SetTimer(host, kTimerId, ms, nullptr);
}

// ================= 每帧 =================

void TaskbarLyricsWindow::Tick() {
  SyncState();
  if (!has_track_) {
    if (lyric_ && IsWindowVisible(lyric_)) ShowWindow(lyric_, SW_HIDE);
    SetInterval(250);
    return;
  }
  if (!EnsureEmbedded()) {
    SetInterval(1000);  // 任务栏不在（资源管理器重启中）：稍后再试
    return;
  }
  const ULONGLONG now = GetTickCount64();
  if (vertical_taskbar_) {
    // 竖向任务栏：功能禁用。保持隐藏并每秒复查（Reflow 会更新标志），移回横向后自动恢复。
    if (lyric_ && IsWindowVisible(lyric_)) ShowWindow(lyric_, SW_HIDE);
    if (now - last_housekeep_ >= 1000) {
      last_housekeep_ = now;
      Reflow(false);
    }
    SetInterval(250);
    return;
  }
  if (now - last_housekeep_ >= 1000) {
    last_housekeep_ = now;
    Housekeep();
  }
  if (vertical_taskbar_ || width_ <= 0) {
    if (IsWindowVisible(lyric_)) ShowWindow(lyric_, SW_HIDE);
    SetInterval(250);
    return;
  }
  if (!IsWindowVisible(lyric_)) ShowWindow(lyric_, SW_SHOWNA);
  UpdateHover();
  Render();
  const bool animating = !control_active_ && now - anim_start_ < kAnimMs + 60;
  SetInterval(animating ? 16 : 100);
}

void TaskbarLyricsWindow::SyncState() {
  std::vector<uint8_t> art;
  bool art_changed = false;
  {
    std::lock_guard<std::mutex> lock(shared_->mutex);
    if (shared_->track_version != track_version_) {
      track_version_ = shared_->track_version;
      has_track_ = shared_->has_track;
      title_ = shared_->title;
      artist_ = shared_->artist;
      frame_signature_.clear();
    }
    if (shared_->art_version != art_version_) {
      art_version_ = shared_->art_version;
      art = shared_->art;
      art_changed = true;
    }
    if (shared_->lyrics_version != lyrics_version_) {
      lyrics_version_ = shared_->lyrics_version;
      lines_ = shared_->lines;
      display_index_ = -2;
      frame_signature_.clear();
    }
    if (shared_->style_version != style_version_) {
      style_version_ = shared_->style_version;
      style_ = shared_->style;
      labels_ = shared_->labels;
      frame_signature_.clear();
    }
    playing_ = shared_->playing;
    anchor_ms_ = shared_->anchor_ms;
    anchor_tick_ = shared_->anchor_tick;
  }
  // 解码放在锁外：大封面解码要几毫秒
  if (art_changed) {
    DecodeArt(art);
    frame_signature_.clear();
  }
}

// 封面居中裁成正方形并缩到 72px，避免每帧缩放大图。
void TaskbarLyricsWindow::DecodeArt(const std::vector<uint8_t>& bytes) {
  art_.reset();
  if (bytes.empty()) return;
  IStream* stream = SHCreateMemStream(bytes.data(), static_cast<UINT>(bytes.size()));
  if (!stream) return;
  {
    std::unique_ptr<Gdiplus::Bitmap> source(Gdiplus::Bitmap::FromStream(stream));
    if (source && source->GetLastStatus() == Gdiplus::Ok) {
      const int w = static_cast<int>(source->GetWidth()), h = static_cast<int>(source->GetHeight());
      const int side = (std::min)(w, h);
      constexpr int kTarget = 72;
      auto square = std::make_unique<Gdiplus::Bitmap>(kTarget, kTarget, PixelFormat32bppPARGB);
      Gdiplus::Graphics g(square.get());
      g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
      g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
      g.DrawImage(source.get(), Gdiplus::Rect(0, 0, kTarget, kTarget), (w - side) / 2, (h - side) / 2, side, side,
                  Gdiplus::UnitPixel);
      art_ = std::move(square);
    }
  }
  stream->Release();
}

int64_t TaskbarLyricsWindow::PositionMs() const {
  if (!playing_) return anchor_ms_;
  return anchor_ms_ + static_cast<int64_t>(GetTickCount64() - anchor_tick_);
}

Gdiplus::Color TaskbarLyricsWindow::TextColor() const {
  using taskbar_lyrics::ColorMode;
  constexpr Gdiplus::ARGB kDark = 0xFF141414;
  constexpr Gdiplus::ARGB kWhite = 0xFFFFFFFF;
  switch (style_.mode) {
    case ColorMode::kWhite:
      return Gdiplus::Color(kWhite);
    case ColorMode::kBlack:
      return Gdiplus::Color(kDark);
    case ColorMode::kCustom:
      return Gdiplus::Color(style_.custom);
    case ColorMode::kAccent:
      return Gdiplus::Color(dark_text_ ? style_.accent_on_light : style_.accent_on_dark);
    case ColorMode::kAuto:
    default:
      return Gdiplus::Color(dark_text_ ? kDark : kWhite);
  }
}

// ================= 嵌入与布局 =================

bool TaskbarLyricsWindow::EnsureEmbedded() {
  HWND tray = FindWindowW(L"Shell_TrayWnd", nullptr);
  if (!tray) return false;
  if (lyric_ && IsWindow(lyric_) && GetParent(lyric_) == tray) return true;
  if (lyric_ && IsWindow(lyric_)) DestroyWindow(lyric_);
  tray_ = tray;
  Reflow(true);
  lyric_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_NOACTIVATE, kLyricClass, L"Flutify Lyrics",
                           WS_CHILD | WS_CLIPSIBLINGS, x_, y_, width_, height_, tray, nullptr,
                           GetModuleHandleW(nullptr), this);
  frame_signature_.clear();
  last_housekeep_ = GetTickCount64();
  return lyric_ != nullptr;
}

// 每秒一次：保持在任务栏子窗口最上层、按小组件 / 图标区的变化重排、采样背景明暗。
void TaskbarLyricsWindow::Housekeep() {
  SetWindowPos(lyric_, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  Reflow(false);
  using taskbar_lyrics::ColorMode;
  if (style_.mode == ColorMode::kAuto || style_.mode == ColorMode::kAccent) SampleBackground();
}

// 任务栏在屏幕左 / 右边缘时返回 true（此时禁用歌词）。优先用 ABM_GETTASKBARPOS，
// 失败时按任务栏矩形宽高比兜底判断。
bool TaskbarLyricsWindow::DetectVerticalTaskbar() {
  APPBARDATA abd{};
  abd.cbSize = sizeof(abd);
  abd.hWnd = tray_;
  if (SHAppBarMessage(ABM_GETTASKBARPOS, &abd)) {
    vertical_taskbar_ = abd.uEdge == ABE_LEFT || abd.uEdge == ABE_RIGHT;
    return vertical_taskbar_;
  }
  RECT tray{};
  if (GetWindowRect(tray_, &tray)) {
    vertical_taskbar_ = (tray.right - tray.left) < (tray.bottom - tray.top);
  }
  return vertical_taskbar_;
}

// Win11：HKCU\...\Explorer\Advanced 的 TaskbarAl=1 表示图标居中；0 表示居左。
// Win10 没有该值，任务栏图标恒居左。
bool TaskbarLyricsWindow::IconsCentered() const {
  DWORD value = 0;
  DWORD size = sizeof(value);
  return RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                      L"TaskbarAl", RRF_RT_REG_DWORD, nullptr, &value, &size) == ERROR_SUCCESS &&
         value != 0;
}

// Win11 的新任务栏由 XAML 绘制，Shell_TrayWnd 下有 DesktopWindowContentBridge 子窗口；Win10 没有。
bool TaskbarLyricsWindow::IsXamlTaskbar() const {
  return FindWindowExW(tray_, nullptr, L"Windows.UI.Composition.DesktopWindowContentBridge", nullptr) != nullptr ||
         FindWindowExW(tray_, nullptr, L"Windows.UI.Input.InputSite.WindowClass", nullptr) != nullptr;
}

void TaskbarLyricsWindow::Reflow(bool force) {
  RECT tray{};
  if (!GetWindowRect(tray_, &tray)) return;
  // 每次重排都复查任务栏位置：竖向任务栏直接禁用（由 Tick 负责隐藏窗口）。
  if (DetectVerticalTaskbar()) return;
  const int tray_width = tray.right - tray.left;
  const int tray_height = tray.bottom - tray.top;
  const UINT dpi = GetDpiForWindow(tray_);
  scale_ = dpi > 0 ? dpi / 96.0 : 1.0;
  const int height = tray_height - static_cast<int>(6 * scale_);
  const int y = (tray_height - height) / 2;
  const auto bounds = locator_.bounds();
  const bool measured = bounds.taskbar == tray_ && bounds.width == tray_width && bounds.height == tray_height;
  const int gap = static_cast<int>(12 * scale_);

  // 经典任务栏（Win10，或 Win11 上被 StartAllBack / ExplorerPatcher 换回的）不认 TaskbarAl：
  // 注册表里多半还留着 Win11 默认的「居中」，照它摆会把宽度算成 0，歌词永远不显示（issue #57）。
  const bool xaml = IsXamlTaskbar();
  int x, width;
  if (xaml && IconsCentered()) {
    // Win11 图标居中：摆在左侧 —— 天气小组件右缘起，到居中图标区（ReBarWindow32）左缘止。
    // 右界找不到时取任务栏宽度的 1/3。
    int right = tray_width / 3;
    int rebar_left = right;
    HWND rebar = FindWindowExW(tray_, nullptr, L"ReBarWindow32", nullptr);
    RECT rr{};
    if (rebar && GetWindowRect(rebar, &rr) && rr.left > tray.left) {
      rebar_left = rr.left - tray.left;
      right = rebar_left - static_cast<int>(14 * scale_);
    }
    if (measured && bounds.icons_left >= 0) {
      rebar_left = bounds.icons_left;
      right = rebar_left - gap;
    }
    x = MeasureWidgetRight(tray, rebar_left);
    width = (std::max)(0, right - x);
  } else {
    // 图标居左：使用实际按钮与系统托盘之间的空白，并在空白中居中。
    int right = tray_width - static_cast<int>(10 * scale_);
    HWND notify = FindWindowExW(tray_, nullptr, L"TrayNotifyWnd", nullptr);
    RECT nr{};
    if (notify && GetWindowRect(notify, &nr) && nr.left > tray.left) {
      right = nr.left - tray.left - static_cast<int>(10 * scale_);
    }
    int left = static_cast<int>(8 * scale_);
    if (measured && bounds.icons_right >= 0) {
      left = bounds.icons_right + gap;
      if (bounds.tray_left >= 0) right = (std::min)(right, bounds.tray_left - gap);
      if (bounds.widget_left >= 0) {
        if (bounds.widget_left > (left + right) / 2) {
          right = (std::min)(right, bounds.widget_left - gap);
        } else {
          left = (std::max)(left, bounds.widget_right + gap);
        }
      }
    } else if (xaml) {
      // UIA 尚未就绪或 Explorer 正在重启：不能用过小的 ReBar 边界覆盖应用按钮。
      left = right;
    }
    if (xaml || measured) {
      width = (std::max)(static_cast<int>(200 * scale_), tray_width / 3);
      width = (std::min)(width, (std::max)(right - left, 0));
      x = left + (right - left - width) / 2;
    } else {
      // 经典任务栏量不到应用按钮的位置：贴着系统托盘摆，窄一些，尽量不压到按钮。
      width = (std::max)(static_cast<int>(200 * scale_), tray_width / 4);
      width = (std::min)(width, (std::max)(right - left, 0));
      x = right - width;
    }
  }
  // 空间不足时隐藏，避免文字和悬停控制挤到系统按钮上。
  if (width < static_cast<int>(140 * scale_)) width = 0;

  const int tolerance = static_cast<int>(4 * scale_);
  if (force || (width == 0) != (width_ == 0) || std::abs(x - x_) > tolerance || std::abs(width - width_) > tolerance || height != height_ ||
      y != y_) {
    x_ = x;
    y_ = y;
    width_ = width;
    height_ = height;
    frame_signature_.clear();
    if (lyric_ && !force) SetWindowPos(lyric_, HWND_TOP, x_, y_, width_, height_, SWP_NOACTIVATE);
  }
}

int TaskbarLyricsWindow::MeasureWidgetRight(const RECT& tray, int rebar_left) {
  const auto bounds = locator_.bounds();
  const int uia = bounds.taskbar == tray_ && bounds.width == tray.right - tray.left && bounds.height == tray.bottom - tray.top
                      ? bounds.widget_right : TaskbarWidgetLocator::kUnknown;
  if (uia == TaskbarWidgetLocator::kNone) return static_cast<int>(10 * scale_);  // 没有小组件：贴任务栏最左
  if (uia > 0) return uia + static_cast<int>(12 * scale_);                     // 按钮真实右缘 + 间距
  return ScanWidgetRight(tray, rebar_left);
}

// UIA 不可用时的兜底：以「居中图标区左侧的空白」为背景基准，从左扫出小组件内容的右缘。
// 只能看到已绘制的内容，会略微低估按钮宽度。
int TaskbarLyricsWindow::ScanWidgetRight(const RECT& tray, int rebar_left) {
  const int fallback = static_cast<int>(150 * scale_);
  const int h = tray.bottom - tray.top;
  int scan = rebar_left > static_cast<int>(60 * scale_) ? rebar_left - static_cast<int>(20 * scale_)
                                                        : static_cast<int>(360 * scale_);
  scan = (std::max)(scan, static_cast<int>(80 * scale_));
  const auto px = CaptureScreen(tray.left, tray.top, scan, h);
  if (px.empty()) return fallback;
  // 背景基准：扫描区最右列（紧邻居中图标，必为空白）取几点求平均
  int br = 0, bg = 0, bb = 0, n = 0;
  for (int y = 8; y < h - 8; y += 3) {
    const uint32_t c = px[static_cast<size_t>(y) * scan + scan - 2];
    br += (c >> 16) & 255;
    bg += (c >> 8) & 255;
    bb += c & 255;
    n++;
  }
  if (n == 0) return fallback;
  br /= n;
  bg /= n;
  bb /= n;
  int last_content = 0, gap_run = 0, widget_right = 0;
  for (int x = 0; x < scan; x++) {
    bool ink = false;
    for (int y = 6; y < h - 6; y += 2) {
      const uint32_t c = px[static_cast<size_t>(y) * scan + x];
      const int diff = std::abs(static_cast<int>((c >> 16) & 255) - br) +
                       std::abs(static_cast<int>((c >> 8) & 255) - bg) + std::abs(static_cast<int>(c & 255) - bb);
      if (diff > 44) {
        ink = true;
        break;
      }
    }
    if (ink) {
      last_content = x;
      gap_run = 0;
    } else if (++gap_run > static_cast<int>(22 * scale_) && widget_right == 0 &&
               last_content > static_cast<int>(30 * scale_)) {
      widget_right = last_content;
    }
  }
  if (widget_right == 0 && last_content > static_cast<int>(30 * scale_)) widget_right = last_content;
  return widget_right > static_cast<int>(30 * scale_) ? widget_right + static_cast<int>(20 * scale_) : fallback;
}

// 自动配色：采样窗口所在区域的平均亮度，带滞回（>150 用深色字，<112 用浅色字）。
void TaskbarLyricsWindow::SampleBackground() {
  RECT wr{};
  if (!GetWindowRect(lyric_, &wr)) return;
  const int w = wr.right - wr.left, h = wr.bottom - wr.top;
  if (w <= 4 || h <= 4 || wr.top < 0) return;
  const auto px = CaptureScreen(wr.left, wr.top, w, h);
  if (px.empty()) return;
  long long sum = 0;
  int n = 0;
  for (int y = 0; y < h; y += 4) {
    for (int x = 0; x < w; x += 6) {
      sum += Luma(px[static_cast<size_t>(y) * w + x]);
      n++;
    }
  }
  const int avg = static_cast<int>(sum / (std::max)(1, n));
  const bool dark = avg > 150 ? true : (avg < 112 ? false : dark_text_);
  if (dark != dark_text_) {
    dark_text_ = dark;
    frame_signature_.clear();
  }
}

// 悬停判定直接轮询光标并加滞回（已悬停时外扩一圈才算离开），杜绝进出抖动。
void TaskbarLyricsWindow::UpdateHover() {
  POINT pt;
  RECT wr;
  if (!GetCursorPos(&pt) || !GetWindowRect(lyric_, &wr)) return;
  const int m = hover_ ? static_cast<int>(6 * scale_) : 0;
  const bool inside = pt.x >= wr.left - m && pt.x < wr.right + m && pt.y >= wr.top - m && pt.y < wr.bottom + m;
  Button button = Button::kNone;
  if (inside && control_active_) {
    const POINT local{pt.x - wr.left, pt.y - wr.top};
    if (PointIn(layout_.previous, local)) {
      button = Button::kPrevious;
    } else if (PointIn(layout_.play, local)) {
      button = Button::kPlay;
    } else if (PointIn(layout_.next, local)) {
      button = Button::kNext;
    }
  }
  if (inside != hover_ || button != hovered_button_) {
    hover_ = inside;
    hovered_button_ = button;
    frame_signature_.clear();
  }
}

// ================= 绘制 =================

void TaskbarLyricsWindow::Render() {
  const int w = width_, h = height_;
  if (w <= 0 || h <= 0) return;
  const bool control = hover_ || lines_.empty();
  if (control != control_active_) {
    control_active_ = control;
    frame_signature_.clear();
  }
  const Gdiplus::Color color = TextColor();
  const std::wstring style_sig = std::to_wstring(color.GetValue()) + L"|" + std::to_wstring(style_.opacity) + L"|" +
                                 std::to_wstring(style_.font_scale) + L"|" +
                                 std::to_wstring(w) + L"x" + std::to_wstring(h);

  std::wstring previous, current, next, current_trans;
  float eased = 1;
  std::wstring signature;
  if (control) {
    signature = L"C|" + title_ + L"|" + artist_ + L"|" + (playing_ ? L"1" : L"0") + L"|" + (art_ ? L"1" : L"0") +
                L"|" + std::to_wstring(static_cast<int>(hovered_button_)) + L"|" + style_sig;
  } else {
    // 最后一个开始时间 <= 当前进度（含提前量）的行；第一句之前为 -1
    const int64_t pos = PositionMs() + kLeadMs;
    int lo = 0, hi = static_cast<int>(lines_.size()) - 1, index = -1;
    while (lo <= hi) {
      const int mid = (lo + hi) / 2;
      if (lines_[mid].start_ms <= pos) {
        index = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    const ULONGLONG now = GetTickCount64();
    if (index != display_index_) {
      // 首次进入（刚换歌 / 刚从控制条切回）不播放动画，直接停在当前句
      anim_start_ = display_index_ == -2 ? 0 : now;
      display_index_ = index;
    }
    const float p = (std::min)(1.0f, static_cast<float>(now - anim_start_) / static_cast<float>(kAnimMs));
    eased = 1 - std::pow(1 - p, 3.0f);  // easeOutCubic
    if (index < 0) {
      current = L"\u266A " + title_ + (artist_.empty() ? L"" : L" \u2014 " + artist_);
    } else {
      current = lines_[index].text.empty() ? L"\u266A \u266A \u266A" : lines_[index].text;
      current_trans = lines_[index].translation;
      if (index > 0) previous = lines_[index - 1].text;
    }
    if (index + 1 < static_cast<int>(lines_.size())) next = lines_[index + 1].text;
    // 动画期间逐帧推，静止时内容不变就跳过
    if (p >= 1) signature = L"L|" + current + L"|" + current_trans + L"|" + next + L"|" + style_sig;
  }
  if (!signature.empty() && signature == frame_signature_) return;
  frame_signature_ = signature;

  if (!EnsureSurface(w, h)) return;
  Gdiplus::Bitmap bitmap(w, h, w * 4, PixelFormat32bppPARGB, static_cast<BYTE*>(surface_bits_));
  Gdiplus::Graphics g(&bitmap);
  // alpha 至少为 1：分层窗口按像素命中，全透明处收不到鼠标
  g.Clear(Gdiplus::Color(1, 0, 0, 0));
  g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);
  g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
  const TaskbarLyricsPainter::Canvas canvas{&g, w, h, scale_, color, style_.opacity,
                                                style_.font_scale / 100.0};
  if (control) {
    layout_ = painter_->PaintControl(canvas, title_.empty() ? L"Flutify" : title_, artist_, art_.get(), playing_,
                                     hovered_button_);
  } else {
    painter_->PaintLyrics(canvas, previous, current, next, current_trans, eased);
  }
  g.Flush(Gdiplus::FlushIntentionSync);
  Push();
}

bool TaskbarLyricsWindow::EnsureSurface(int width, int height) {
  if (surface_dc_ && width == surface_width_ && height == surface_height_) return true;
  if (surface_dc_) {
    SelectObject(surface_dc_, surface_old_);
    DeleteObject(surface_bitmap_);
    DeleteDC(surface_dc_);
    surface_dc_ = nullptr;
  }
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(info.bmiHeader);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;  // 自上而下，与 GDI+ 的行序一致
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  HDC screen = GetDC(nullptr);
  surface_bitmap_ = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &surface_bits_, nullptr, 0);
  surface_dc_ = surface_bitmap_ ? CreateCompatibleDC(screen) : nullptr;
  ReleaseDC(nullptr, screen);
  if (!surface_dc_) {
    if (surface_bitmap_) DeleteObject(surface_bitmap_);
    surface_bitmap_ = nullptr;
    return false;
  }
  surface_old_ = SelectObject(surface_dc_, surface_bitmap_);
  surface_width_ = width;
  surface_height_ = height;
  return true;
}

void TaskbarLyricsWindow::Push() {
  if (!lyric_) return;
  HDC screen = GetDC(nullptr);
  SIZE size{surface_width_, surface_height_};
  POINT source{0, 0};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(lyric_, screen, nullptr, &size, surface_dc_, &source, 0, &blend, ULW_ALPHA);
  ReleaseDC(nullptr, screen);
}
