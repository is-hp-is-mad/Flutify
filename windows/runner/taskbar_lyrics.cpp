#include "taskbar_lyrics.h"

#include <flutter/standard_method_codec.h>

#include <string>
#include <vector>

#include "gdiplus_include.h"
#include "taskbar_lyrics_window.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using taskbar_lyrics::ColorMode;
using taskbar_lyrics::Event;

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring out(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), out.data(), length);
  return out;
}

std::wstring GetText(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  if (!value) return {};
  if (auto text = std::get_if<std::string>(value)) return Wide(*text);
  return {};
}

int64_t GetInt(const EncodableMap& map, const char* key, int64_t fallback) {
  const EncodableValue* value = Find(map, key);
  if (!value) return fallback;
  if (auto v = std::get_if<int32_t>(value)) return *v;
  if (auto v = std::get_if<int64_t>(value)) return *v;
  return fallback;
}

bool GetBool(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  if (!value) return false;
  if (auto v = std::get_if<bool>(value)) return *v;
  return false;
}

ColorMode ParseMode(const std::wstring& name) {
  if (name == L"white") return ColorMode::kWhite;
  if (name == L"black") return ColorMode::kBlack;
  if (name == L"accent") return ColorMode::kAccent;
  if (name == L"custom") return ColorMode::kCustom;
  return ColorMode::kAuto;
}

const char* EventName(Event event) {
  switch (event) {
    case Event::kPrevious:
      return "previous";
    case Event::kToggle:
      return "toggle";
    case Event::kNext:
      return "next";
    case Event::kOpen:
      return "open";
    case Event::kRefetch:
      return "refetch";
    case Event::kDisable:
      return "disable";
  }
  return nullptr;
}

}  // namespace

TaskbarLyrics::TaskbarLyrics(HWND window, flutter::BinaryMessenger* messenger) : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "flutify/taskbar_lyrics", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { OnMethodCall(call, std::move(result)); });
}

TaskbarLyrics::~TaskbarLyrics() {
  channel_->SetMethodCallHandler(nullptr);
  SetEnabled(false);
}

void TaskbarLyrics::SetEnabled(bool enabled) {
  if (enabled == (lyrics_window_ != nullptr)) return;
  if (enabled) {
    if (!gdiplus_token_) {
      Gdiplus::GdiplusStartupInput input;
      if (Gdiplus::GdiplusStartup(&gdiplus_token_, &input, nullptr) != Gdiplus::Ok) {
        gdiplus_token_ = 0;
        return;
      }
    }
    lyrics_window_ = std::make_unique<TaskbarLyricsWindow>(window_, &shared_);
  } else {
    // 先停窗口线程（它持有 GDI+ 对象），再关闭 GDI+
    lyrics_window_ = nullptr;
    if (gdiplus_token_) {
      Gdiplus::GdiplusShutdown(gdiplus_token_);
      gdiplus_token_ = 0;
    }
  }
}

void TaskbarLyrics::OnMethodCall(const flutter::MethodCall<EncodableValue>& call,
                                 std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const EncodableValue* arguments = call.arguments();
  const auto* args = arguments ? std::get_if<EncodableMap>(arguments) : nullptr;

  if (method == "setEnabled") {
    const auto* enabled = arguments ? std::get_if<bool>(arguments) : nullptr;
    SetEnabled(enabled && *enabled);
    result->Success();
    return;
  }

  {
    std::lock_guard<std::mutex> lock(shared_.mutex);
    if (method == "setStyle") {
      if (args) {
        auto& style = shared_.style;
        style.mode = ParseMode(GetText(*args, "mode"));
        style.custom = static_cast<uint32_t>(GetInt(*args, "custom", style.custom));
        style.accent_on_dark = static_cast<uint32_t>(GetInt(*args, "accentOnDark", style.accent_on_dark));
        style.accent_on_light = static_cast<uint32_t>(GetInt(*args, "accentOnLight", style.accent_on_light));
        style.opacity = static_cast<int>(GetInt(*args, "opacity", 100));
        style.opacity = style.opacity < 15 ? 15 : (style.opacity > 100 ? 100 : style.opacity);
        style.font_scale = static_cast<int>(GetInt(*args, "fontScale", 100));
        style.font_scale = style.font_scale < 80 ? 80 : (style.font_scale > 130 ? 130 : style.font_scale);
        if (const EncodableValue* labels = Find(*args, "labels")) {
          if (const auto* map = std::get_if<EncodableMap>(labels)) {
            shared_.labels.open = GetText(*map, "open");
            shared_.labels.refetch = GetText(*map, "refetch");
            shared_.labels.disable = GetText(*map, "disable");
          }
        }
      }
      shared_.style_version++;
    } else if (method == "setTrack") {
      shared_.has_track = args != nullptr;
      shared_.title = args ? GetText(*args, "title") : L"";
      shared_.artist = args ? GetText(*args, "artist") : L"";
      shared_.track_version++;
    } else if (method == "setArt") {
      const auto* bytes = arguments ? std::get_if<std::vector<uint8_t>>(arguments) : nullptr;
      shared_.art = bytes ? *bytes : std::vector<uint8_t>();
      shared_.art_version++;
    } else if (method == "setLyrics") {
      shared_.lines.clear();
      if (args) {
        const EncodableValue* times = Find(*args, "times");
        const EncodableValue* texts = Find(*args, "texts");
        const EncodableValue* translations = Find(*args, "texts2");
        const auto* t = times ? std::get_if<std::vector<int32_t>>(times) : nullptr;
        const auto* s = texts ? std::get_if<EncodableList>(texts) : nullptr;
        const auto* s2 = translations ? std::get_if<EncodableList>(translations) : nullptr;
        if (t && s) {
          const size_t n = (std::min)(t->size(), s->size());
          shared_.lines.reserve(n);
          for (size_t i = 0; i < n; i++) {
            const auto* text = std::get_if<std::string>(&(*s)[i]);
            std::wstring translation;
            if (s2 && i < s2->size()) {
              if (const auto* tr = std::get_if<std::string>(&(*s2)[i])) translation = Wide(*tr);
            }
            shared_.lines.push_back({(*t)[i], text ? Wide(*text) : L"", std::move(translation)});
          }
        }
      }
      shared_.lyrics_version++;
    } else if (method == "setPlayback") {
      if (args) {
        shared_.playing = GetBool(*args, "playing");
        shared_.mute_button = GetBool(*args, "muteButton");
        shared_.muted = GetBool(*args, "muted");
        shared_.anchor_ms = GetInt(*args, "positionMs", 0);
        shared_.anchor_tick = GetTickCount64();
      }
    } else {
      result->NotImplemented();
      return;
    }
  }
  if (lyrics_window_) lyrics_window_->Wake();
  result->Success();
}

bool TaskbarLyrics::HandleMessage(UINT message, WPARAM wparam, LPARAM) {
  if (message != taskbar_lyrics::kEventMessage) return false;
  if (const char* name = EventName(static_cast<Event>(wparam))) {
    channel_->InvokeMethod("event", std::make_unique<EncodableValue>(std::string(name)));
  }
  return true;
}
