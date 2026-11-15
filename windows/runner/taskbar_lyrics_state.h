#ifndef RUNNER_TASKBAR_LYRICS_STATE_H_
#define RUNNER_TASKBAR_LYRICS_STATE_H_

#include <windows.h>

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

// 任务栏歌词：Flutter 平台线程（写）与任务栏窗口线程（读）之间共享的状态。
//
// 平台线程收到 Dart 的推送后加锁改写并递增对应的版本号，再通知窗口线程；
// 窗口线程每帧加锁比对版本号，只在变化时拷走大块数据（歌词行、封面字节）。
namespace taskbar_lyrics {

struct LyricLine {
  int64_t start_ms = 0;
  std::wstring text;
  // 译文（双语歌词）；为空则当前句只画原文一行
  std::wstring translation;
};

// 文字颜色：自动（按任务栏背景明暗取黑 / 白）、白、黑、跟随强调色、自定义。
enum class ColorMode { kAuto, kWhite, kBlack, kAccent, kCustom };

struct Style {
  ColorMode mode = ColorMode::kAuto;
  uint32_t custom = 0xFF1ED760;
  // 强调色分两档：深色任务栏上用亮的一档，浅色任务栏上用暗的一档，保证对比度
  uint32_t accent_on_dark = 0xFF1ED760;
  uint32_t accent_on_light = 0xFF1DB954;
  int font_scale = 100;  // 歌词字号百分比（80 ~ 130）
  int opacity = 100;  // 文字整体不透明度（15 ~ 100）
};

// 右键菜单与占位文案（随 App 界面语言）。
struct Labels {
  std::wstring open = L"Open Flutify";
  std::wstring refetch = L"Reload lyrics";
  std::wstring disable = L"Turn off taskbar lyrics";
};

struct Shared {
  std::mutex mutex;

  // 曲目（标题 / 歌手）；has_track 为 false 时窗口隐藏
  uint64_t track_version = 0;
  bool has_track = false;
  std::wstring title;
  std::wstring artist;

  // 封面原始字节（JPEG / PNG），窗口线程自行解码
  uint64_t art_version = 0;
  std::vector<uint8_t> art;

  // 逐行同步歌词；为空时显示控制条（封面 + 歌名 + 切歌按钮）
  uint64_t lyrics_version = 0;
  std::vector<LyricLine> lines;

  // 播放进度锚点：position = anchor_ms + (now - anchor_tick)（播放中）
  bool playing = false;
  bool mute_button = false;  // true 时控制条中间按钮改为静音/取消静音（发现流试听）
  bool muted = false;
  int64_t anchor_ms = 0;
  ULONGLONG anchor_tick = 0;

  uint64_t style_version = 0;
  Style style;
  Labels labels;
};

// 窗口线程投递给 Flutter 主窗口的事件（wparam），由 TaskbarLyrics::HandleMessage 转给 Dart。
enum class Event : WPARAM { kPrevious = 1, kToggle, kNext, kOpen, kRefetch, kDisable };

// 窗口线程 → Flutter 主窗口的私有消息（WM_APP 段，避开 media_controls 的 0x51 / 0x52）。
constexpr UINT kEventMessage = WM_APP + 0x61;

}  // namespace taskbar_lyrics

#endif  // RUNNER_TASKBAR_LYRICS_STATE_H_
