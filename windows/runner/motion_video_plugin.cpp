#include "motion_video_plugin.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

// Minimal libmpv C ABI declarations (dynamically loaded from libmpv-2.dll).
struct mpv_handle;
struct mpv_render_context;

struct mpv_event {
  int event_id;
  int error;
  uint64_t reply_userdata;
  void* data;
};

struct mpv_render_param {
  int type;
  void* data;
};

constexpr int kMpvEventNone = 0;
constexpr int kMpvEventEndFile = 7;
constexpr int kMpvEventFileLoaded = 8;
constexpr int kMpvEventVideoReconfig = 17;

constexpr int kMpvFormatInt64 = 4;

constexpr int kMpvRenderParamApiType = 1;
constexpr int kMpvRenderParamBlockForTargetTime = 12;
constexpr int kMpvRenderParamSwSize = 17;
constexpr int kMpvRenderParamSwFormat = 18;
constexpr int kMpvRenderParamSwStride = 19;
constexpr int kMpvRenderParamSwPointer = 20;

constexpr uint64_t kMpvRenderUpdateFrame = 1ULL << 0;

struct MpvApi {
  HMODULE module = nullptr;
  mpv_handle* (*create)() = nullptr;
  int (*initialize)(mpv_handle*) = nullptr;
  void (*terminate_destroy)(mpv_handle*) = nullptr;
  int (*set_option_string)(mpv_handle*, const char*, const char*) = nullptr;
  int (*set_property_string)(mpv_handle*, const char*, const char*) = nullptr;
  int (*get_property)(mpv_handle*, const char*, int, void*) = nullptr;
  int (*command)(mpv_handle*, const char**) = nullptr;
  void (*set_wakeup_callback)(mpv_handle*, void (*)(void*), void*) = nullptr;
  mpv_event* (*wait_event)(mpv_handle*, double) = nullptr;
  int (*render_context_create)(mpv_render_context**,
                               mpv_handle*,
                               mpv_render_param*) = nullptr;
  void (*render_context_set_update_callback)(mpv_render_context*,
                                             void (*)(void*),
                                             void*) = nullptr;
  uint64_t (*render_context_update)(mpv_render_context*) = nullptr;
  int (*render_context_render)(mpv_render_context*,
                               mpv_render_param*) = nullptr;
  void (*render_context_free)(mpv_render_context*) = nullptr;

  bool Load() {
    if (module) return true;
    module = GetModuleHandleW(L"libmpv-2.dll");
    if (!module) {
      wchar_t exe_path[MAX_PATH]{};
      if (GetModuleFileNameW(nullptr, exe_path, MAX_PATH) > 0) {
        std::filesystem::path dir =
            std::filesystem::path(exe_path).parent_path();
        module = LoadLibraryW((dir / L"libmpv-2.dll").c_str());
      }
      if (!module) {
        module = LoadLibraryW(L"libmpv-2.dll");
      }
    }
    if (!module) return false;

    auto resolve = [this](auto& fn, const char* name) {
      fn = reinterpret_cast<std::decay_t<decltype(fn)>>(
          GetProcAddress(module, name));
      return fn != nullptr;
    };

    if (!resolve(create, "mpv_create") ||
        !resolve(initialize, "mpv_initialize") ||
        !resolve(terminate_destroy, "mpv_terminate_destroy") ||
        !resolve(set_option_string, "mpv_set_option_string") ||
        !resolve(set_property_string, "mpv_set_property_string") ||
        !resolve(get_property, "mpv_get_property") ||
        !resolve(command, "mpv_command") ||
        !resolve(set_wakeup_callback, "mpv_set_wakeup_callback") ||
        !resolve(wait_event, "mpv_wait_event") ||
        !resolve(render_context_create, "mpv_render_context_create") ||
        !resolve(render_context_set_update_callback,
                 "mpv_render_context_set_update_callback") ||
        !resolve(render_context_update, "mpv_render_context_update") ||
        !resolve(render_context_render, "mpv_render_context_render") ||
        !resolve(render_context_free, "mpv_render_context_free")) {
      module = nullptr;
      return false;
    }
    return true;
  }
};

MpvApi& GetMpvApi() {
  static MpvApi api;
  static std::once_flag once;
  std::call_once(once, []() { api.Load(); });
  return api;
}

constexpr wchar_t kMotionReplyWindowClass[] = L"FlutifyMotionVideoReply";
constexpr UINT kMsgVideoEvent = WM_APP + 42;

enum class EventType { kSize, kReady, kError };

struct VideoEventMsg {
  int64_t id = 0;
  EventType type = EventType::kReady;
  double width = 0;
  double height = 0;
  std::string message;
};

struct VideoInstance : public std::enable_shared_from_this<VideoInstance> {
  int64_t texture_id = 0;
  FlutterDesktopTextureRegistrarRef texture_registrar = nullptr;
  HWND reply_hwnd = nullptr;
  std::filesystem::path temp_file;
  std::string media_uri;

  std::mutex state_mutex;
  std::condition_variable cv;
  bool stopped = false;
  bool events_pending = false;
  bool frame_pending = false;
  bool playing_changed = false;
  bool want_playing = true;

  std::mutex pixel_mutex;
  std::vector<uint8_t> shared_pixels;
  std::vector<uint8_t> front_pixels;
  size_t shared_width = 0;
  size_t shared_height = 0;
  bool shared_dirty = false;
  FlutterDesktopPixelBuffer pixel_buffer{};

  const FlutterDesktopPixelBuffer* CopyPixelBuffer() {
    std::lock_guard<std::mutex> lock(pixel_mutex);
    if (shared_pixels.empty() || shared_width == 0 || shared_height == 0) {
      return nullptr;
    }
    if (shared_dirty) {
      front_pixels = shared_pixels;
      pixel_buffer.buffer = front_pixels.data();
      pixel_buffer.width = shared_width;
      pixel_buffer.height = shared_height;
      shared_dirty = false;
    }
    return &pixel_buffer;
  }

  void PostEvent(EventType type,
                 double w = 0,
                 double h = 0,
                 std::string msg = {}) {
    if (!reply_hwnd) return;
    auto* ev = new VideoEventMsg{texture_id, type, w, h, std::move(msg)};
    if (!PostMessageW(reply_hwnd, kMsgVideoEvent, 0,
                      reinterpret_cast<LPARAM>(ev))) {
      delete ev;
    }
  }

  void SetPlaying(bool playing) {
    std::lock_guard<std::mutex> lock(state_mutex);
    if (want_playing == playing) return;
    want_playing = playing;
    playing_changed = true;
    cv.notify_one();
  }

  void Stop() {
    std::lock_guard<std::mutex> lock(state_mutex);
    stopped = true;
    cv.notify_all();
  }

  void StartWorker() {
    auto self = shared_from_this();
    std::thread([self]() { self->WorkerLoop(); }).detach();
  }

  void WorkerLoop() {
    MpvApi& api = GetMpvApi();
    if (!api.Load()) {
      PostEvent(EventType::kError, 0, 0, "libmpv-2.dll unavailable");
      CleanupTempFile();
      return;
    }

    mpv_handle* mpv = api.create();
    if (!mpv) {
      PostEvent(EventType::kError, 0, 0, "mpv_create failed");
      CleanupTempFile();
      return;
    }

    bool initial_playing = true;
    {
      std::lock_guard<std::mutex> lock(state_mutex);
      initial_playing = want_playing;
    }

    api.set_option_string(mpv, "vo", "libmpv");
    api.set_option_string(mpv, "hwdec", "auto-safe");
    api.set_option_string(mpv, "ao", "null");
    api.set_option_string(mpv, "aid", "no");
    api.set_option_string(mpv, "sid", "no");
    api.set_option_string(mpv, "vid", "auto");
    api.set_option_string(mpv, "volume", "0");
    api.set_option_string(mpv, "mute", "yes");
    api.set_option_string(mpv, "loop-file", "inf");
    api.set_option_string(mpv, "keep-open", "yes");
    api.set_option_string(mpv, "video-timing-offset", "0");
    api.set_option_string(mpv, "pause", initial_playing ? "no" : "yes");

    if (api.initialize(mpv) < 0) {
      api.terminate_destroy(mpv);
      PostEvent(EventType::kError, 0, 0, "mpv_initialize failed");
      CleanupTempFile();
      return;
    }

    char sw_api[] = "sw";
    mpv_render_param create_params[] = {
        {kMpvRenderParamApiType, sw_api},
        {0, nullptr},
    };
    mpv_render_context* render_ctx = nullptr;
    if (api.render_context_create(&render_ctx, mpv, create_params) < 0 ||
        !render_ctx) {
      api.terminate_destroy(mpv);
      PostEvent(EventType::kError, 0, 0, "mpv_render_context_create failed");
      CleanupTempFile();
      return;
    }

    api.set_wakeup_callback(
        mpv,
        [](void* ctx) {
          auto* self = static_cast<VideoInstance*>(ctx);
          std::lock_guard<std::mutex> lock(self->state_mutex);
          self->events_pending = true;
          self->cv.notify_one();
        },
        this);

    api.render_context_set_update_callback(
        render_ctx,
        [](void* ctx) {
          auto* self = static_cast<VideoInstance*>(ctx);
          std::lock_guard<std::mutex> lock(self->state_mutex);
          self->frame_pending = true;
          self->cv.notify_one();
        },
        this);

    const char* cmd[] = {"loadfile", media_uri.c_str(), nullptr};
    if (api.command(mpv, cmd) < 0) {
      api.render_context_set_update_callback(render_ctx, nullptr, nullptr);
      api.set_wakeup_callback(mpv, nullptr, nullptr);
      api.render_context_free(render_ctx);
      api.terminate_destroy(mpv);
      PostEvent(EventType::kError, 0, 0, "mpv loadfile failed");
      CleanupTempFile();
      return;
    }

    int64_t video_w = 0;
    int64_t video_h = 0;
    int64_t reported_w = 0;
    int64_t reported_h = 0;
    bool sent_ready = false;
    std::vector<uint8_t> render_buf;

    while (true) {
      bool do_events = false;
      bool do_frame = false;
      bool do_playing = false;
      bool target_playing = true;

      {
        std::unique_lock<std::mutex> lock(state_mutex);
        cv.wait(lock, [this]() {
          return stopped || events_pending || frame_pending || playing_changed;
        });
        if (stopped) break;
        do_events = events_pending;
        events_pending = false;
        do_frame = frame_pending;
        frame_pending = false;
        do_playing = playing_changed;
        playing_changed = false;
        target_playing = want_playing;
      }

      if (do_playing) {
        api.set_property_string(mpv, "pause", target_playing ? "no" : "yes");
      }

      if (do_events) {
        while (true) {
          mpv_event* ev = api.wait_event(mpv, 0);
          if (!ev || ev->event_id == kMpvEventNone) break;
          if (ev->event_id == kMpvEventEndFile && ev->error < 0) {
            PostEvent(EventType::kError, 0, 0, "mpv playback error");
          } else if (ev->event_id == kMpvEventVideoReconfig ||
                     ev->event_id == kMpvEventFileLoaded) {
            int64_t w = 0, h = 0;
            if (api.get_property(mpv, "dwidth", kMpvFormatInt64, &w) >= 0 &&
                api.get_property(mpv, "dheight", kMpvFormatInt64, &h) >= 0 &&
                w > 0 && h > 0) {
              video_w = w;
              video_h = h;
            } else if (api.get_property(mpv, "width", kMpvFormatInt64, &w) >=
                           0 &&
                       api.get_property(mpv, "height", kMpvFormatInt64, &h) >=
                           0 &&
                       w > 0 && h > 0) {
              video_w = w;
              video_h = h;
            }
          }
        }
      }

      if (do_frame) {
        uint64_t flags = api.render_context_update(render_ctx);
        if (flags & kMpvRenderUpdateFrame) {
          if (video_w <= 0 || video_h <= 0) {
            int64_t w = 0, h = 0;
            if (api.get_property(mpv, "dwidth", kMpvFormatInt64, &w) >= 0 &&
                api.get_property(mpv, "dheight", kMpvFormatInt64, &h) >= 0 &&
                w > 0 && h > 0) {
              video_w = w;
              video_h = h;
            } else if (api.get_property(mpv, "width", kMpvFormatInt64, &w) >=
                           0 &&
                       api.get_property(mpv, "height", kMpvFormatInt64, &h) >=
                           0 &&
                       w > 0 && h > 0) {
              video_w = w;
              video_h = h;
            }
          }

          if (video_w > 0 && video_h > 0) {
            // Cap software surface to max 1080p while preserving aspect ratio.
            int out_w = static_cast<int>(video_w);
            int out_h = static_cast<int>(video_h);
            constexpr int kMaxDim = 1080;
            if (out_w > kMaxDim || out_h > kMaxDim) {
              if (out_w >= out_h) {
                out_h = std::max(1, out_h * kMaxDim / out_w);
                out_w = kMaxDim;
              } else {
                out_w = std::max(1, out_w * kMaxDim / out_h);
                out_h = kMaxDim;
              }
            }

            const size_t stride = static_cast<size_t>(out_w) * 4;
            const size_t total = stride * static_cast<size_t>(out_h);
            if (render_buf.size() != total) {
              render_buf.resize(total);
            }

            int sw_size[2] = {out_w, out_h};
            char sw_format[] = "rgb0";
            size_t sw_stride = stride;
            int block_for_time = 0;
            mpv_render_param render_params[] = {
                {kMpvRenderParamSwSize, sw_size},
                {kMpvRenderParamSwFormat, sw_format},
                {kMpvRenderParamSwStride, &sw_stride},
                {kMpvRenderParamSwPointer, render_buf.data()},
                {kMpvRenderParamBlockForTargetTime, &block_for_time},
                {0, nullptr},
            };

            if (api.render_context_render(render_ctx, render_params) >= 0) {
              // Ensure alpha byte is 0xFF (mpv "rgb0" leaves 4th byte undefined).
              auto* px = reinterpret_cast<uint32_t*>(render_buf.data());
              const size_t count =
                  static_cast<size_t>(out_w) * static_cast<size_t>(out_h);
              for (size_t i = 0; i < count; ++i) {
                px[i] |= 0xFF000000u;
              }

              {
                std::lock_guard<std::mutex> lock(pixel_mutex);
                shared_pixels = render_buf;
                shared_width = static_cast<size_t>(out_w);
                shared_height = static_cast<size_t>(out_h);
                shared_dirty = true;
              }

              if (reported_w != out_w || reported_h != out_h) {
                reported_w = out_w;
                reported_h = out_h;
                PostEvent(EventType::kSize, static_cast<double>(out_w),
                          static_cast<double>(out_h));
              }

              FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
                  texture_registrar, texture_id);

              if (!sent_ready) {
                sent_ready = true;
                PostEvent(EventType::kReady);
              }
            }
          }
        }
      }
    }

    api.render_context_set_update_callback(render_ctx, nullptr, nullptr);
    api.set_wakeup_callback(mpv, nullptr, nullptr);
    api.render_context_free(render_ctx);
    api.terminate_destroy(mpv);
    CleanupTempFile();
  }

  void CleanupTempFile() {
    if (!temp_file.empty()) {
      std::error_code ec;
      std::filesystem::remove(temp_file, ec);
      temp_file.clear();
    }
  }
};

}  // namespace

struct MotionVideoPlugin::Impl {
  FlutterDesktopTextureRegistrarRef texture_registrar = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;
  HWND reply_hwnd = nullptr;
  std::map<int64_t, std::shared_ptr<VideoInstance>> videos;
  std::filesystem::path cache_dir;

  static LRESULT CALLBACK WndProc(HWND hwnd,
                                  UINT message,
                                  WPARAM wparam,
                                  LPARAM lparam) {
    if (message == WM_NCCREATE) {
      auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
      return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    if (message == kMsgVideoEvent) {
      std::unique_ptr<VideoEventMsg> ev(
          reinterpret_cast<VideoEventMsg*>(lparam));
      auto* self = reinterpret_cast<Impl*>(
          GetWindowLongPtrW(hwnd, GWLP_USERDATA));
      if (self && self->channel &&
          self->videos.find(ev->id) != self->videos.end()) {
        flutter::EncodableMap args;
        args[flutter::EncodableValue("id")] = flutter::EncodableValue(ev->id);
        switch (ev->type) {
          case EventType::kSize:
            args[flutter::EncodableValue("width")] =
                flutter::EncodableValue(ev->width);
            args[flutter::EncodableValue("height")] =
                flutter::EncodableValue(ev->height);
            self->channel->InvokeMethod(
                "size", std::make_unique<flutter::EncodableValue>(args));
            FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
                self->texture_registrar, ev->id);
            break;
          case EventType::kReady:
            self->channel->InvokeMethod(
                "ready", std::make_unique<flutter::EncodableValue>(args));
            FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
                self->texture_registrar, ev->id);
            break;
          case EventType::kError:
            args[flutter::EncodableValue("message")] =
                flutter::EncodableValue(ev->message);
            self->channel->InvokeMethod(
                "error", std::make_unique<flutter::EncodableValue>(args));
            break;
        }
      }
      return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  void InitWindow() {
    WNDCLASSW wc{};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kMotionReplyWindowClass;
    RegisterClassW(&wc);
    reply_hwnd = CreateWindowExW(0, kMotionReplyWindowClass, L"", 0, 0, 0, 0, 0,
                                 HWND_MESSAGE, nullptr, wc.hInstance, this);
  }

  void DisposeVideo(int64_t id) {
    auto it = videos.find(id);
    if (it == videos.end()) return;
    auto instance = it->second;
    videos.erase(it);
    instance->Stop();
    FlutterDesktopTextureRegistrarUnregisterExternalTexture(
        texture_registrar, id,
        [](void* user_data) {
          delete static_cast<std::shared_ptr<VideoInstance>*>(user_data);
        },
        new std::shared_ptr<VideoInstance>(instance));
  }
};

MotionVideoPlugin::MotionVideoPlugin(
    FlutterDesktopPluginRegistrarRef registrar,
    flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>()) {
  impl_->texture_registrar =
      FlutterDesktopRegistrarGetTextureRegistrar(registrar);
  impl_->InitWindow();

  wchar_t temp_path[MAX_PATH]{};
  if (GetTempPathW(MAX_PATH, temp_path) > 0) {
    impl_->cache_dir = std::filesystem::path(temp_path) / L"flutify_motion_video";
    std::error_code ec;
    std::filesystem::remove_all(impl_->cache_dir, ec);
  }

  impl_->channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.flutify/motion_video",
          &flutter::StandardMethodCodec::GetInstance());

  impl_->channel->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() == "create") {
          if (!args) {
            result->Error("motion_video_args", "Missing arguments");
            return;
          }
          const std::vector<uint8_t>* bytes = nullptr;
          const std::string* url = nullptr;
          bool playing = true;

          auto bytes_it = args->find(flutter::EncodableValue("bytes"));
          if (bytes_it != args->end()) {
            bytes = std::get_if<std::vector<uint8_t>>(&bytes_it->second);
          }
          auto url_it = args->find(flutter::EncodableValue("url"));
          if (url_it != args->end()) {
            url = std::get_if<std::string>(&url_it->second);
          }
          auto play_it = args->find(flutter::EncodableValue("playing"));
          if (play_it != args->end()) {
            if (const auto* b = std::get_if<bool>(&play_it->second)) {
              playing = *b;
            }
          }

          if ((!bytes || bytes->empty()) && (!url || url->empty())) {
            result->Error("motion_video_args", "create requires bytes or url");
            return;
          }

          auto instance = std::make_shared<VideoInstance>();
          instance->texture_registrar = impl_->texture_registrar;
          instance->reply_hwnd = impl_->reply_hwnd;
          instance->want_playing = playing;

          FlutterDesktopTextureInfo info{};
          info.type = kFlutterDesktopPixelBufferTexture;
          info.pixel_buffer_config.user_data = instance.get();
          info.pixel_buffer_config.callback =
              [](size_t /*width*/, size_t /*height*/,
                 void* user_data) -> const FlutterDesktopPixelBuffer* {
            return static_cast<VideoInstance*>(user_data)->CopyPixelBuffer();
          };

          const int64_t id =
              FlutterDesktopTextureRegistrarRegisterExternalTexture(
                  impl_->texture_registrar, &info);
          if (id <= 0) {
            result->Error("motion_video", "Failed to register texture");
            return;
          }
          instance->texture_id = id;

          if (bytes && !bytes->empty()) {
            std::error_code ec;
            std::filesystem::create_directories(impl_->cache_dir, ec);
            std::filesystem::path file =
                impl_->cache_dir / (std::to_string(id) + ".mp4");
            std::ofstream out(file, std::ios::binary | std::ios::trunc);
            out.write(reinterpret_cast<const char*>(bytes->data()),
                      static_cast<std::streamsize>(bytes->size()));
            out.close();
            if (!out) {
              FlutterDesktopTextureRegistrarUnregisterExternalTexture(
                  impl_->texture_registrar, id, nullptr, nullptr);
              result->Error("motion_video", "Failed to write temp file");
              return;
            }
            instance->temp_file = file;
            instance->media_uri = file.u8string();
          } else {
            instance->media_uri = *url;
          }

          impl_->videos[id] = instance;
          instance->StartWorker();
          result->Success(flutter::EncodableValue(id));
          return;
        }

        if (call.method_name() == "setPlaying") {
          if (args) {
            int64_t id = 0;
            bool playing = true;
            auto id_it = args->find(flutter::EncodableValue("id"));
            if (id_it != args->end()) {
              if (const auto* i64 = std::get_if<int64_t>(&id_it->second)) {
                id = *i64;
              } else if (const auto* i32 =
                             std::get_if<int32_t>(&id_it->second)) {
                id = *i32;
              }
            }
            auto play_it = args->find(flutter::EncodableValue("playing"));
            if (play_it != args->end()) {
              if (const auto* b = std::get_if<bool>(&play_it->second)) {
                playing = *b;
              }
            }
            auto it = impl_->videos.find(id);
            if (it != impl_->videos.end()) {
              it->second->SetPlaying(playing);
            }
          }
          result->Success();
          return;
        }

        if (call.method_name() == "dispose") {
          if (args) {
            int64_t id = 0;
            auto id_it = args->find(flutter::EncodableValue("id"));
            if (id_it != args->end()) {
              if (const auto* i64 = std::get_if<int64_t>(&id_it->second)) {
                id = *i64;
              } else if (const auto* i32 =
                             std::get_if<int32_t>(&id_it->second)) {
                id = *i32;
              }
            }
            impl_->DisposeVideo(id);
          }
          result->Success();
          return;
        }

        result->NotImplemented();
      });
}

MotionVideoPlugin::~MotionVideoPlugin() {
  if (!impl_) return;
  if (impl_->reply_hwnd) {
    SetWindowLongPtrW(impl_->reply_hwnd, GWLP_USERDATA, 0);
    DestroyWindow(impl_->reply_hwnd);
    impl_->reply_hwnd = nullptr;
  }
  std::vector<int64_t> ids;
  for (const auto& kv : impl_->videos) {
    ids.push_back(kv.first);
  }
  for (int64_t id : ids) {
    impl_->DisposeVideo(id);
  }
}
