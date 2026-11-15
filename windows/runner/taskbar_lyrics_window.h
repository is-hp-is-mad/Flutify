#ifndef RUNNER_TASKBAR_LYRICS_WINDOW_H_
#define RUNNER_TASKBAR_LYRICS_WINDOW_H_

#include <windows.h>

#include <atomic>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "gdiplus_include.h"
#include "taskbar_lyrics_painter.h"
#include "taskbar_lyrics_state.h"
#include "taskbar_widget_locator.h"

// 嵌入 Windows 任务栏（Shell_TrayWnd）的歌词窗口。
//
// 摆放位置随任务栏形态自适应（每秒复查一次注册表 / APPBAR 状态，用户改设置后自动跟随）：
// - Windows 11 且任务栏图标居中：显示在左侧 —— 紧贴天气小组件右侧、居中图标区左侧；
// - Windows 10 或 Windows 11 图标居左：显示在右侧 —— 紧贴系统托盘区的左边；
// - 任务栏位于屏幕左侧 / 右侧（竖向）：功能自动禁用（隐藏窗口），移回底部 / 顶部后自动恢复。
//
// 线程：窗口运行在自己的线程和消息循环上。跨进程挂到任务栏下的子窗口会与资源管理器共享输入队列，
// 放在 Flutter 主线程上的话 App 一忙任务栏就跟着卡。线程里有两个窗口：
// - 宿主窗口：隐藏的顶层窗口，承载定时器与右键菜单（菜单需要能前台化的顶层窗口）；
// - 歌词窗口：分层子窗口（UpdateLayeredWindow 推整帧 ARGB），资源管理器重启后自动重建。
// 帧率自适应：切句动画期间约 60fps，静止 10fps，内容不变时跳过推帧；没有曲目时隐藏并降到 4fps。
class TaskbarLyricsWindow {
 public:
  // [app_window]：Flutter 主窗口，用户操作以 kEventMessage 投递给它；[shared] 生命周期须长于本对象。
  TaskbarLyricsWindow(HWND app_window, taskbar_lyrics::Shared* shared);
  ~TaskbarLyricsWindow();

  TaskbarLyricsWindow(const TaskbarLyricsWindow&) = delete;
  TaskbarLyricsWindow& operator=(const TaskbarLyricsWindow&) = delete;

  // 共享状态已更新：立即刷新一帧（不必等下一个定时器周期）。
  void Wake();

 private:
  void ThreadMain(HANDLE ready);
  static LRESULT CALLBACK HostProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  static LRESULT CALLBACK LyricProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  LRESULT OnLyricMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  void Tick();
  void SyncState();
  void DecodeArt(const std::vector<uint8_t>& bytes);
  bool EnsureEmbedded();
  void Housekeep();
  void Reflow(bool force);
  // 任务栏在屏幕左 / 右边缘（竖向）：此时禁用任务栏歌词。
  bool DetectVerticalTaskbar();
  // 任务栏图标是否居中（Win11 的 TaskbarAl=1；Win10 无此键，视为居左）。
  bool IconsCentered() const;
  bool IsXamlTaskbar() const;
  int MeasureWidgetRight(const RECT& tray, int rebar_left);
  int ScanWidgetRight(const RECT& tray, int rebar_left);
  void SampleBackground();
  void UpdateHover();
  void Render();
  bool EnsureSurface(int width, int height);
  void Push();
  void SetInterval(UINT ms);
  void ShowMenu();
  void Post(taskbar_lyrics::Event event);
  Gdiplus::Color TextColor() const;
  int64_t PositionMs() const;

  HWND app_window_;
  taskbar_lyrics::Shared* shared_;
  std::thread thread_;
  std::atomic<HWND> host_{nullptr};
  HWND lyric_ = nullptr;
  HWND tray_ = nullptr;

  std::unique_ptr<TaskbarLyricsPainter> painter_;
  TaskbarWidgetLocator locator_;

  // ---- 从共享状态拷来的本地副本（只在窗口线程读写）----
  uint64_t track_version_ = ~0ull, art_version_ = ~0ull, lyrics_version_ = ~0ull, style_version_ = ~0ull;
  bool has_track_ = false;
  std::wstring title_, artist_;
  std::unique_ptr<Gdiplus::Bitmap> art_;
  std::vector<taskbar_lyrics::LyricLine> lines_;
  bool playing_ = false;
  bool mute_button_ = false;
  bool muted_ = false;
  int64_t anchor_ms_ = 0;
  ULONGLONG anchor_tick_ = 0;
  taskbar_lyrics::Style style_;
  taskbar_lyrics::Labels labels_;

  // ---- 布局（物理像素，相对任务栏左上角）----
  double scale_ = 1.0;
  int x_ = 0, y_ = 0, width_ = 300, height_ = 40;
  ULONGLONG last_housekeep_ = 0;
  bool dark_text_ = false;        // 自动配色：浅色任务栏用深色字
  bool vertical_taskbar_ = false;  // 竖向任务栏：功能禁用（窗口隐藏，每秒复查）

  // ---- 交互 ----
  bool hover_ = false;
  TaskbarLyricsPainter::Button hovered_button_ = TaskbarLyricsPainter::Button::kNone;
  bool control_active_ = false;
  TaskbarLyricsPainter::ControlLayout layout_{};

  // ---- 切句动画 ----
  int display_index_ = -2;
  ULONGLONG anim_start_ = 0;

  // ---- 绘制表面（32bpp 预乘 DIB，尺寸变化时重建）----
  HDC surface_dc_ = nullptr;
  HBITMAP surface_bitmap_ = nullptr;
  HGDIOBJ surface_old_ = nullptr;
  void* surface_bits_ = nullptr;
  int surface_width_ = 0, surface_height_ = 0;
  std::wstring frame_signature_;
  UINT interval_ = 0;
};

#endif  // RUNNER_TASKBAR_LYRICS_WINDOW_H_
