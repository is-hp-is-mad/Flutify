#include "taskbar_lyrics_painter.h"

#include <cmath>

using Gdiplus::Color;
using Gdiplus::Font;
using Gdiplus::FontFamily;
using Gdiplus::Graphics;
using Gdiplus::GraphicsPath;
using Gdiplus::PointF;
using Gdiplus::Rect;
using Gdiplus::RectF;
using Gdiplus::SolidBrush;

namespace {

// 点 → 像素（画布按 96 DPI 计，缩放已含在 scale 里）。
constexpr double kPointToPixel = 96.0 / 72.0;

// 长句最多缩到 72%，再放不下就折行。
constexpr float kMinScale = 0.72f;

// 歌词字号（点，乘以任务栏缩放）：当前句 / 下一句。
constexpr double kBigPt = 10.5;
constexpr double kSmallPt = 7.7;

std::wstring FontPath(const wchar_t* file) {
  wchar_t exe[MAX_PATH];
  const DWORD length = GetModuleFileNameW(nullptr, exe, MAX_PATH);
  std::wstring dir(exe, length);
  dir = dir.substr(0, dir.find_last_of(L"\\/") + 1);
  return dir + L"data\\flutter_assets\\assets\\fonts\\MiSans\\" + file;
}

// 从字体文件加载唯一的字体族；失败返回空。
std::unique_ptr<FontFamily> LoadFamily(Gdiplus::PrivateFontCollection* collection, const wchar_t* file) {
  if (collection->AddFontFile(FontPath(file).c_str()) != Gdiplus::Ok || collection->GetFamilyCount() < 1) {
    return nullptr;
  }
  auto family = std::make_unique<FontFamily>();
  int found = 0;
  if (collection->GetFamilies(1, family.get(), &found) != Gdiplus::Ok || found < 1) return nullptr;
  return family;
}

bool Contains(const std::wstring& text, wchar_t lo, wchar_t hi) {
  for (wchar_t c : text) {
    if (c >= lo && c <= hi) return true;
  }
  return false;
}

GraphicsPath* RoundRect(GraphicsPath* path, const RectF& r, float radius) {
  const float d = radius * 2;
  if (d <= 0) {
    path->AddRectangle(r);
    return path;
  }
  path->AddArc(r.X, r.Y, d, d, 180, 90);
  path->AddArc(r.X + r.Width - d, r.Y, d, d, 270, 90);
  path->AddArc(r.X + r.Width - d, r.Y + r.Height - d, d, d, 0, 90);
  path->AddArc(r.X, r.Y + r.Height - d, d, d, 90, 90);
  path->CloseFigure();
  return path;
}

// 长句折两行：优先在正中附近的空格处断开，没有空格（中日文）就从正中断。
void SplitTwo(const std::wstring& source, std::wstring* a, std::wstring* b) {
  const size_t first = source.find_first_not_of(L' ');
  const size_t last = source.find_last_not_of(L' ');
  const std::wstring s = first == std::wstring::npos ? L"" : source.substr(first, last - first + 1);
  const size_t mid = s.size() / 2;
  size_t best = std::wstring::npos;
  for (size_t off = 0; off < s.size() / 2; off++) {
    if (mid >= off && mid - off > 0 && s[mid - off] == L' ') {
      best = mid - off;
      break;
    }
    if (mid + off < s.size() && s[mid + off] == L' ') {
      best = mid + off;
      break;
    }
  }
  if (best == std::wstring::npos) best = mid;
  *a = s.substr(0, best);
  *b = s.substr(best);
  while (!b->empty() && b->front() == L' ') b->erase(b->begin());
}

}  // namespace

TaskbarLyricsPainter::TaskbarLyricsPainter() {
  bold_collection_ = std::make_unique<Gdiplus::PrivateFontCollection>();
  regular_collection_ = std::make_unique<Gdiplus::PrivateFontCollection>();
  bold_family_ = LoadFamily(bold_collection_.get(), L"MiSans-Demibold.ttf");
  regular_family_ = LoadFamily(regular_collection_.get(), L"MiSans-Regular.ttf");

  text_format_ = std::make_unique<Gdiplus::StringFormat>();
  text_format_->SetAlignment(Gdiplus::StringAlignmentNear);
  text_format_->SetLineAlignment(Gdiplus::StringAlignmentCenter);
  text_format_->SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  text_format_->SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
}

// 字体对象须先于字体族、字体族须先于字体集合释放
TaskbarLyricsPainter::~TaskbarLyricsPainter() {
  // 测宽缓存以 Font* 地址为键，与字体缓存同进同退
  widths_.clear();
  fonts_.clear();
  system_families_.clear();
  bold_family_.reset();
  regular_family_.reset();
}

const FontFamily* TaskbarLyricsPainter::SystemFamily(const wchar_t* name) {
  auto it = system_families_.find(name);
  if (it != system_families_.end()) return it->second.get();
  auto family = std::make_unique<FontFamily>(name);
  const FontFamily* result = family->GetLastStatus() == Gdiplus::Ok ? family.get() : nullptr;
  system_families_[name] = result ? std::move(family) : nullptr;
  return result;
}

const FontFamily* TaskbarLyricsPainter::FamilyFor(const std::wstring& text, bool bold) {
  // GDI+ 对私有字体不做缺字回退：MiSans 没有的文字直接换成覆盖它的系统字体
  const wchar_t* fallback = nullptr;
  if (Contains(text, 0xAC00, 0xD7AF) || Contains(text, 0x1100, 0x11FF) || Contains(text, 0x3130, 0x318F)) {
    fallback = L"Malgun Gothic";
  } else if (Contains(text, 0x0E00, 0x0E7F)) {
    fallback = L"Leelawadee UI";
  } else if (Contains(text, 0x0590, 0x06FF) || Contains(text, 0x0750, 0x077F)) {
    fallback = L"Segoe UI";
  }
  if (fallback) {
    if (const FontFamily* family = SystemFamily(fallback)) return family;
  }
  const FontFamily* own = bold ? bold_family_.get() : regular_family_.get();
  if (own) return own;
  if (const FontFamily* family = SystemFamily(L"Microsoft YaHei UI")) return family;
  return FontFamily::GenericSansSerif();
}

Font* TaskbarLyricsPainter::FontFor(const std::wstring& text, double points, bool bold) {
  const FontFamily* family = FamilyFor(text, bold);
  // 字号按 0.25pt 取整作为缓存键，动画期间字号连续变化也不会无限增长
  const int quarter = static_cast<int>(std::lround(points * 4));
  const auto key = std::make_tuple(family, quarter, bold);
  auto it = fonts_.find(key);
  if (it != fonts_.end()) return it->second.get();
  // 私有 MiSans 的 Demibold 本身就是粗体字重；系统字体用 Bold 样式
  const bool own = family == bold_family_.get() || family == regular_family_.get();
  const int style = bold && !own ? Gdiplus::FontStyleBold : Gdiplus::FontStyleRegular;
  auto font = std::make_unique<Font>(family, static_cast<Gdiplus::REAL>(quarter / 4.0 * kPointToPixel), style,
                                     Gdiplus::UnitPixel);
  Font* result = font.get();
  // 这里不做淘汰：调用方可能还持有本轮先取到的 Font*（如双语分支的 ofont），清空会悬空。
  // 淘汰统一放在每轮绘制入口的 TrimCaches()
  fonts_[key] = std::move(font);
  return result;
}

float TaskbarLyricsPainter::MeasureWidth(Graphics* g, const std::wstring& text, Font* font) {
  if (text.empty()) return 0;
  const std::wstring key = std::to_wstring(reinterpret_cast<uintptr_t>(font)) + L"|" + text;
  auto it = widths_.find(key);
  if (it != widths_.end()) return it->second;
  RectF box;
  g->MeasureString(text.c_str(), static_cast<INT>(text.size()), font, PointF(0, 0), &box);
  widths_[key] = box.Width;
  return box.Width;
}

void TaskbarLyricsPainter::DrawText(const Canvas& canvas, const std::wstring& text, Font* font, const RectF& rect,
                                    int alpha) {
  alpha = alpha * canvas.opacity / 100;
  if (text.empty() || alpha <= 2) return;
  SolidBrush brush(Color(static_cast<BYTE>((std::min)(alpha, 255)), canvas.color.GetR(), canvas.color.GetG(),
                         canvas.color.GetB()));
  canvas.graphics->DrawString(text.c_str(), static_cast<INT>(text.size()), font, rect, text_format_.get(), &brush);
}

// 每轮绘制开始、尚未取得任何 Font* 时调用：字体与测宽缓存一起淘汰。
// 测宽缓存以 Font* 地址为键，字体释放后地址可能被新字体复用，必须同时清空，否则会命中过期宽度。
void TaskbarLyricsPainter::TrimCaches() {
  if (fonts_.size() > 96 || widths_.size() > 512) {
    widths_.clear();
    fonts_.clear();
  }
}

bool TaskbarLyricsPainter::NeedsWrap(const Canvas& canvas, const std::wstring& current) {
  TrimCaches();
  return WrapNeeded(canvas, current);
}

bool TaskbarLyricsPainter::WrapNeeded(const Canvas& canvas, const std::wstring& current) {
  const float pad = static_cast<float>(8 * canvas.scale);
  const float avail = canvas.width - pad * 2;
  Font* big = FontFor(current, kBigPt * canvas.scale * canvas.font_scale, true);
  return MeasureWidth(canvas.graphics, current, big) * kMinScale > avail && current.size() > 4;
}

void TaskbarLyricsPainter::PaintLyrics(const Canvas& canvas, const std::wstring& previous,
                                       const std::wstring& current, const std::wstring& next,
                                       const std::wstring& current_translation, float progress) {
  TrimCaches();
  const double big_pt = kBigPt * canvas.scale * canvas.font_scale;
  const double small_pt = kSmallPt * canvas.scale * canvas.font_scale;
  const float pad = static_cast<float>(8 * canvas.scale);
  const float avail = canvas.width - pad * 2;

  if (!current_translation.empty()) {
    // 双语：原文在上（大 / 亮）、译文在下（小 / 暗）铺满整高，无上滚；
    // 两行同时逐级缩小，仍放不下由省略号裁切（DrawText 的 TrimmingEllipsis）
    const float top_h = canvas.height * 0.62f;
    double original_pt = big_pt * 0.95;
    double translation_pt = small_pt;
    const double floor_pt = small_pt * 0.78;
    Font* ofont = nullptr;
    Font* tfont = nullptr;
    for (;;) {
      ofont = FontFor(current, original_pt, true);
      tfont = FontFor(current_translation, translation_pt, false);
      const bool fits = MeasureWidth(canvas.graphics, current, ofont) <= avail &&
                        MeasureWidth(canvas.graphics, current_translation, tfont) <= avail;
      if (fits || original_pt <= floor_pt) break;
      original_pt -= 0.5;
      translation_pt = (std::max)(floor_pt, translation_pt - 0.25);
    }
    DrawText(canvas, current, ofont, RectF(pad, 0, avail, top_h), 255);
    DrawText(canvas, current_translation, tfont, RectF(pad, top_h, avail, canvas.height - top_h), 185);
    return;
  }

  if (WrapNeeded(canvas, current)) {
    // 折两行：均分成两半铺满整高，无上滚；字号逐级缩小到两半都放得下
    std::wstring a, b;
    SplitTwo(current, &a, &b);
    double fit = big_pt;
    Font* font = FontFor(current, fit, true);
    while (fit > small_pt &&
           (MeasureWidth(canvas.graphics, a, font) > avail || MeasureWidth(canvas.graphics, b, font) > avail)) {
      fit -= 0.5;
      font = FontFor(current, fit, true);
    }
    const float half = canvas.height / 2.0f;
    DrawText(canvas, a, font, RectF(pad, 0, avail, half), 255);
    DrawText(canvas, b, font, RectF(pad, half, avail, canvas.height - half), 255);
    return;
  }

  // 当前句尽量缩放到放得下，而不是省略
  const float width = MeasureWidth(canvas.graphics, current, FontFor(current, big_pt, true));
  const double scale = width > avail && width > 1 ? (std::max)(static_cast<double>(kMinScale), static_cast<double>(avail / width)) : 1.0;
  // 三行胶片：上一句 / 当前句 / 下一句，整体向上平移一个槽位
  const float slot = canvas.height * 0.60f;
  const float offset = slot * progress;
  DrawFilmLine(canvas, previous, 0 - offset, slot, big_pt, small_pt, 1.0);
  DrawFilmLine(canvas, current, slot - offset, slot, big_pt, small_pt, scale);
  DrawFilmLine(canvas, next, 2 * slot - offset, slot, big_pt, small_pt, 1.0);
}

// 按纵向位置决定字号与透明度：靠上 = 当前句（大 / 亮），靠下 = 下一句（小 / 暗）。
void TaskbarLyricsPainter::DrawFilmLine(const Canvas& canvas, const std::wstring& text, float top, float slot,
                                        double big_pt, double small_pt, double width_scale) {
  if (text.empty()) return;
  const float t = top / slot;  // 0 = 当前槽，1 = 下一句槽
  int alpha;
  double pt;
  if (t <= 0) {
    alpha = static_cast<int>(255 * (1 + t));
    pt = big_pt;
  } else if (t <= 1) {
    alpha = static_cast<int>(255 - 115 * t);
    pt = big_pt - (big_pt - small_pt) * t;
  } else {
    alpha = static_cast<int>(140 * (2 - t));
    pt = small_pt;
  }
  if (alpha <= 3) return;
  alpha = (std::clamp)(alpha, 0, 255);
  Font* font = FontFor(text, pt * (t <= 0.001f ? width_scale : 1.0), true);
  const float pad = static_cast<float>(8 * canvas.scale);
  Graphics* g = canvas.graphics;
  g->SetClip(RectF(0, 0, static_cast<float>(canvas.width), static_cast<float>(canvas.height)));
  DrawText(canvas, text, font, RectF(pad, top, canvas.width - pad * 2, slot), alpha);
  g->ResetClip();
}

TaskbarLyricsPainter::ControlLayout TaskbarLyricsPainter::PaintControl(const Canvas& canvas,
                                                                       const std::wstring& title,
                                                                       const std::wstring& artist,
                                                                       Gdiplus::Bitmap* art, bool playing,
                                                                       Button hovered, bool mute_button, bool muted) {
  TrimCaches();
  const double sc = canvas.scale;
  const int h = canvas.height;
  const int pad = static_cast<int>(8 * sc);
  const int gap = static_cast<int>(8 * sc);
  const int art_size = h - static_cast<int>(8 * sc);
  const int btn = static_cast<int>(h * 0.62);
  const int btn_gap = static_cast<int>(3 * sc);
  const int buttons_width = btn * 3 + btn_gap * 2;
  Graphics* g = canvas.graphics;

  Font* title_font = FontFor(title, 9.8 * sc, true);
  Font* artist_font = FontFor(artist, 7.6 * sc, false);

  // 左对齐紧凑排布：文字取自然宽度（不超过 230），按钮紧跟其后，右侧留空透明
  const float natural =
      (std::max)(MeasureWidth(g, title, title_font), MeasureWidth(g, artist, artist_font));
  int text_width = static_cast<int>((std::min)(natural + 2.0, 230 * sc));
  const int content_max = canvas.width - (pad + art_size + gap) - (gap + buttons_width + pad);
  if (text_width > content_max) text_width = (std::max)(static_cast<int>(40 * sc), content_max);

  // 封面（圆角，跟随整体不透明度）
  const int ax = pad;
  const int ay = (h - art_size) / 2;
  {
    GraphicsPath clip;
    RoundRect(&clip, RectF(static_cast<float>(ax), static_cast<float>(ay), static_cast<float>(art_size),
                           static_cast<float>(art_size)),
              static_cast<float>(6 * sc));
    g->SetClip(&clip);
    if (art) {
      Gdiplus::ColorMatrix matrix = {{{1, 0, 0, 0, 0},
                                      {0, 1, 0, 0, 0},
                                      {0, 0, 1, 0, 0},
                                      {0, 0, 0, canvas.opacity / 100.0f, 0},
                                      {0, 0, 0, 0, 1}}};
      Gdiplus::ImageAttributes attributes;
      attributes.SetColorMatrix(&matrix);
      g->DrawImage(art, Rect(ax, ay, art_size, art_size), 0, 0, static_cast<INT>(art->GetWidth()),
                   static_cast<INT>(art->GetHeight()), Gdiplus::UnitPixel, &attributes);
    } else {
      SolidBrush fill(Color(static_cast<BYTE>(60 * canvas.opacity / 100), canvas.color.GetR(), canvas.color.GetG(),
                            canvas.color.GetB()));
      g->FillRectangle(&fill, ax, ay, art_size, art_size);
      DrawText(canvas, L"\u266A", FontFor(L"\u266A", 12 * sc, true),
               RectF(ax + art_size * 0.3f, static_cast<float>(ay), static_cast<float>(art_size),
                     static_cast<float>(art_size)),
               200);
    }
    g->ResetClip();
  }

  // 两行文字：歌名（亮）/ 歌手（暗）
  const int tx = ax + art_size + gap;
  const int line1 = static_cast<int>(h * 0.54);
  DrawText(canvas, title, title_font,
           RectF(static_cast<float>(tx), (h - line1 - static_cast<int>(h * 0.34)) / 2.0f + 1,
                 static_cast<float>(text_width), static_cast<float>(line1)),
           255);
  DrawText(canvas, artist, artist_font,
           RectF(static_cast<float>(tx), static_cast<float>(line1 - 1), static_cast<float>(text_width),
                 static_cast<float>(h - line1)),
           165);

  ControlLayout layout;
  layout.info = Rect(0, 0, tx + text_width, h);
  const int by = (h - btn) / 2;
  const int bx = tx + text_width + gap;
  layout.previous = Rect(bx, by, btn, btn);
  layout.play = Rect(bx + btn + btn_gap, by, btn, btn);
  layout.next = Rect(bx + (btn + btn_gap) * 2, by, btn, btn);
  DrawButton(canvas, Button::kPrevious, layout.previous, playing, hovered == Button::kPrevious);
  DrawButton(canvas, Button::kPlay, layout.play, playing, hovered == Button::kPlay, mute_button, muted);
  DrawButton(canvas, Button::kNext, layout.next, playing, hovered == Button::kNext);
  return layout;
}

// 矢量按钮图标（圆角三角 / 竖条 / 喇叭静音），悬停时垫一个淡色圆。
void TaskbarLyricsPainter::DrawButton(const Canvas& canvas, Button kind, const Rect& rect, bool playing,
                                      bool hovered, bool mute_button, bool muted) {
  Graphics* g = canvas.graphics;
  const BYTE r = canvas.color.GetR(), gg = canvas.color.GetG(), b = canvas.color.GetB();
  // 按钮保留可用下限，整体很淡时也点得到
  const int opacity = (std::max)(60, canvas.opacity);
  if (hovered) {
    SolidBrush halo(Color(static_cast<BYTE>(38 * opacity / 100), r, gg, b));
    g->FillEllipse(&halo, rect);
  }
  SolidBrush brush(Color(static_cast<BYTE>(240 * opacity / 100), r, gg, b));
  Gdiplus::Pen round(&brush, rect.Width * 0.06f);
  round.SetLineJoin(Gdiplus::LineJoinRound);

  const float s = rect.Width * 0.40f;  // 图标边长
  const float cx = rect.X + rect.Width / 2.0f;
  const float cy = rect.Y + rect.Height / 2.0f;
  const float x0 = cx - s / 2, y0 = cy - s / 2;

  // 实心三角（[right] 朝右，否则朝左），描一圈圆角笔让尖角变圆
  auto triangle = [&](float left, float width, bool right) {
    PointF pts[3];
    if (right) {
      pts[0] = PointF(left, y0);
      pts[1] = PointF(left, y0 + s);
      pts[2] = PointF(left + width, cy);
    } else {
      pts[0] = PointF(left + width, y0);
      pts[1] = PointF(left + width, y0 + s);
      pts[2] = PointF(left, cy);
    }
    g->FillPolygon(&brush, pts, 3);
    g->DrawPolygon(&round, pts, 3);
  };
  auto bar = [&](float left, float width) {
    GraphicsPath path;
    RoundRect(&path, RectF(left, y0, width, s), width / 2);
    g->FillPath(&brush, &path);
  };

  switch (kind) {
    case Button::kPlay:
      if (mute_button) {
        // 喇叭主体（左侧矩形 + 梯形锥体）
        PointF speaker[6] = {
            PointF(x0 + s * 0.04f, cy - s * 0.16f),
            PointF(x0 + s * 0.24f, cy - s * 0.16f),
            PointF(x0 + s * 0.50f, y0 + s * 0.10f),
            PointF(x0 + s * 0.50f, y0 + s * 0.90f),
            PointF(x0 + s * 0.24f, cy + s * 0.16f),
            PointF(x0 + s * 0.04f, cy + s * 0.16f),
        };
        g->FillPolygon(&brush, speaker, 6);
        g->DrawPolygon(&round, speaker, 6);
        Gdiplus::Pen stroke(&brush, (std::max)(1.3f, rect.Width * 0.075f));
        stroke.SetStartCap(Gdiplus::LineCapRound);
        stroke.SetEndCap(Gdiplus::LineCapRound);
        if (muted) {
          // 静音叉号
          g->DrawLine(&stroke, x0 + s * 0.66f, cy - s * 0.18f, x0 + s * 0.96f, cy + s * 0.18f);
          g->DrawLine(&stroke, x0 + s * 0.96f, cy - s * 0.18f, x0 + s * 0.66f, cy + s * 0.18f);
        } else {
          // 声波弧线（两道）
          g->DrawArc(&stroke, x0 + s * 0.44f, cy - s * 0.22f, s * 0.34f, s * 0.44f, -55.0f, 110.0f);
          g->DrawArc(&stroke, x0 + s * 0.48f, cy - s * 0.36f, s * 0.50f, s * 0.72f, -55.0f, 110.0f);
        }
      } else if (playing) {
        bar(cx - s * 0.36f, s * 0.26f);
        bar(cx + s * 0.10f, s * 0.26f);
      } else {
        triangle(x0 + s * 0.12f, s * 0.86f, true);  // 光学居中：三角重心偏左，整体右移一点
      }
      break;
    case Button::kNext:
      triangle(x0, s * 0.72f, true);
      bar(x0 + s * 0.80f, s * 0.18f);
      break;
    case Button::kPrevious:
      bar(x0 + s * 0.02f, s * 0.18f);
      triangle(x0 + s * 0.28f, s * 0.72f, false);
      break;
    case Button::kNone:
      break;
  }
}
