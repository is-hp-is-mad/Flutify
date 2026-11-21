#include "motion_video_plugin.h"

#include <dlfcn.h>

#include <algorithm>
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
#include <type_traits>
#include <vector>

namespace {

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
  void* handle = nullptr;
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
    if (handle) return true;
    const char* candidates[] = {"libmpv.so.2", "libmpv.so.1", "libmpv.so"};
    for (const char* name : candidates) {
      handle = dlopen(name, RTLD_LAZY | RTLD_LOCAL);
      if (handle) break;
    }
    if (!handle) return false;

    auto resolve = [this](auto& fn, const char* sym) {
      fn = reinterpret_cast<std::decay_t<decltype(fn)>>(dlsym(handle, sym));
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
      handle = nullptr;
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

struct VideoInstance;

}  // namespace

#define FLUTIFY_MOTION_TEXTURE_TYPE (flutify_motion_texture_get_type())
G_DECLARE_FINAL_TYPE(FlutifyMotionTexture,
                     flutify_motion_texture,
                     FLUTIFY,
                     MOTION_TEXTURE,
                     FlPixelBufferTexture)

struct _FlutifyMotionTexture {
  FlPixelBufferTexture parent_instance;
  std::shared_ptr<VideoInstance>* instance_ref;
};

G_DEFINE_TYPE(FlutifyMotionTexture,
              flutify_motion_texture,
              fl_pixel_buffer_texture_get_type())

namespace {

enum class EventType { kFrame, kSize, kReady, kError };

struct ManagerState;

struct VideoInstance : public std::enable_shared_from_this<VideoInstance> {
  int64_t texture_id = 0;
  FlutifyMotionTexture* texture = nullptr;  // ref-counted while active
  std::weak_ptr<ManagerState> manager;
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
  uint32_t shared_width = 0;
  uint32_t shared_height = 0;
  uint32_t front_width = 1;
  uint32_t front_height = 1;
  bool shared_dirty = false;

  VideoInstance() : front_pixels(4, 0) {}

  gboolean CopyPixels(const uint8_t** out_buffer,
                      uint32_t* width,
                      uint32_t* height) {
    std::lock_guard<std::mutex> lock(pixel_mutex);
    if (shared_dirty && !shared_pixels.empty() && shared_width > 0 &&
        shared_height > 0) {
      front_pixels = shared_pixels;
      front_width = shared_width;
      front_height = shared_height;
      shared_dirty = false;
    }
    *out_buffer = front_pixels.data();
    *width = front_width;
    *height = front_height;
    return TRUE;
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

  void PostEvent(EventType type,
                 double w = 0,
                 double h = 0,
                 std::string msg = {});

  void StartWorker() {
    auto self = shared_from_this();
    std::thread([self]() { self->WorkerLoop(); }).detach();
  }

  void WorkerLoop() {
    MpvApi& api = GetMpvApi();
    if (!api.Load()) {
      PostEvent(EventType::kError, 0, 0, "libmpv.so unavailable");
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
              auto* px = reinterpret_cast<uint32_t*>(render_buf.data());
              const size_t count =
                  static_cast<size_t>(out_w) * static_cast<size_t>(out_h);
              for (size_t i = 0; i < count; ++i) {
                px[i] |= 0xFF000000u;
              }

              {
                std::lock_guard<std::mutex> lock(pixel_mutex);
                shared_pixels = render_buf;
                shared_width = static_cast<uint32_t>(out_w);
                shared_height = static_cast<uint32_t>(out_h);
                shared_dirty = true;
              }

              if (reported_w != out_w || reported_h != out_h) {
                reported_w = out_w;
                reported_h = out_h;
                PostEvent(EventType::kSize, static_cast<double>(out_w),
                          static_cast<double>(out_h));
              }

              PostEvent(EventType::kFrame);

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

struct ManagerState {
  FlTextureRegistrar* texture_registrar = nullptr;
  FlMethodChannel* channel = nullptr;
  std::map<int64_t, std::shared_ptr<VideoInstance>> videos;
  std::filesystem::path cache_dir;

  ~ManagerState() {
    for (auto& kv : videos) {
      kv.second->Stop();
      if (kv.second->texture) {
        fl_texture_registrar_unregister_texture(
            texture_registrar, FL_TEXTURE(kv.second->texture));
        g_object_unref(kv.second->texture);
        kv.second->texture = nullptr;
      }
    }
    videos.clear();
    if (channel) {
      g_object_unref(channel);
      channel = nullptr;
    }
  }
};

struct IdleEvent {
  std::weak_ptr<ManagerState> manager;
  int64_t id = 0;
  EventType type = EventType::kFrame;
  double width = 0;
  double height = 0;
  std::string message;
};

void VideoInstance::PostEvent(EventType type,
                              double w,
                              double h,
                              std::string msg) {
  auto* ev = new IdleEvent{manager, texture_id, type, w, h, std::move(msg)};
  g_idle_add(
      [](gpointer user_data) -> gboolean {
        std::unique_ptr<IdleEvent> ev(static_cast<IdleEvent*>(user_data));
        auto mgr = ev->manager.lock();
        if (!mgr || !mgr->channel) return G_SOURCE_REMOVE;
        auto it = mgr->videos.find(ev->id);
        if (it == mgr->videos.end()) return G_SOURCE_REMOVE;

        if (ev->type == EventType::kFrame) {
          if (it->second->texture) {
            fl_texture_registrar_mark_texture_frame_available(
                mgr->texture_registrar, FL_TEXTURE(it->second->texture));
          }
          return G_SOURCE_REMOVE;
        }

        g_autoptr(FlValue) map = fl_value_new_map();
        fl_value_set_string_take(map, "id", fl_value_new_int(ev->id));
        if (ev->type == EventType::kSize) {
          fl_value_set_string_take(map, "width",
                                   fl_value_new_float(ev->width));
          fl_value_set_string_take(map, "height",
                                   fl_value_new_float(ev->height));
          fl_method_channel_invoke_method(mgr->channel, "size", map, nullptr,
                                          nullptr, nullptr);
          if (it->second->texture) {
            fl_texture_registrar_mark_texture_frame_available(
                mgr->texture_registrar, FL_TEXTURE(it->second->texture));
          }
        } else if (ev->type == EventType::kReady) {
          fl_method_channel_invoke_method(mgr->channel, "ready", map, nullptr,
                                          nullptr, nullptr);
          if (it->second->texture) {
            fl_texture_registrar_mark_texture_frame_available(
                mgr->texture_registrar, FL_TEXTURE(it->second->texture));
          }
        } else if (ev->type == EventType::kError) {
          fl_value_set_string_take(
              map, "message", fl_value_new_string(ev->message.c_str()));
          fl_method_channel_invoke_method(mgr->channel, "error", map, nullptr,
                                          nullptr, nullptr);
        }
        return G_SOURCE_REMOVE;
      },
      ev);
}

}  // namespace

static gboolean flutify_motion_texture_copy_pixels(
    FlPixelBufferTexture* texture,
    const uint8_t** out_buffer,
    uint32_t* width,
    uint32_t* height,
    GError** /*error*/) {
  auto* self = FLUTIFY_MOTION_TEXTURE(texture);
  if (!self->instance_ref || !(*self->instance_ref)) return FALSE;
  return (*self->instance_ref)->CopyPixels(out_buffer, width, height);
}

static void flutify_motion_texture_dispose(GObject* object) {
  auto* self = FLUTIFY_MOTION_TEXTURE(object);
  if (self->instance_ref) {
    delete self->instance_ref;
    self->instance_ref = nullptr;
  }
  G_OBJECT_CLASS(flutify_motion_texture_parent_class)->dispose(object);
}

static void flutify_motion_texture_class_init(
    FlutifyMotionTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      flutify_motion_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->dispose = flutify_motion_texture_dispose;
}

static void flutify_motion_texture_init(FlutifyMotionTexture* self) {
  self->instance_ref = nullptr;
}

static void method_call_cb(FlMethodChannel* /*channel*/,
                           FlMethodCall* call,
                           gpointer user_data) {
  auto* mgr_ptr = static_cast<std::shared_ptr<ManagerState>*>(user_data);
  if (!mgr_ptr || !(*mgr_ptr)) return;
  auto mgr = *mgr_ptr;

  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);

  if (strcmp(method, "create") == 0) {
    if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      fl_method_call_respond_error(call, "motion_video_args",
                                   "Missing arguments", nullptr, nullptr);
      return;
    }

    FlValue* bytes_val = fl_value_lookup_string(args, "bytes");
    FlValue* url_val = fl_value_lookup_string(args, "url");
    FlValue* play_val = fl_value_lookup_string(args, "playing");

    const uint8_t* bytes_ptr = nullptr;
    size_t bytes_len = 0;
    if (bytes_val && fl_value_get_type(bytes_val) == FL_VALUE_TYPE_UINT8_LIST) {
      bytes_ptr = fl_value_get_uint8_list(bytes_val);
      bytes_len = fl_value_get_length(bytes_val);
    }

    const gchar* url_str = nullptr;
    if (url_val && fl_value_get_type(url_val) == FL_VALUE_TYPE_STRING) {
      url_str = fl_value_get_string(url_val);
    }

    bool playing = true;
    if (play_val && fl_value_get_type(play_val) == FL_VALUE_TYPE_BOOL) {
      playing = fl_value_get_bool(play_val);
    }

    if ((bytes_ptr == nullptr || bytes_len == 0) &&
        (url_str == nullptr || url_str[0] == '\0')) {
      fl_method_call_respond_error(call, "motion_video_args",
                                   "create requires bytes or url", nullptr,
                                   nullptr);
      return;
    }

    auto instance = std::make_shared<VideoInstance>();
    instance->manager = mgr;
    instance->want_playing = playing;

    auto* tex = FLUTIFY_MOTION_TEXTURE(
        g_object_new(FLUTIFY_MOTION_TEXTURE_TYPE, nullptr));
    tex->instance_ref = new std::shared_ptr<VideoInstance>(instance);

    if (!fl_texture_registrar_register_texture(mgr->texture_registrar,
                                               FL_TEXTURE(tex))) {
      g_object_unref(tex);
      fl_method_call_respond_error(
          call, "motion_video", "Failed to register texture", nullptr, nullptr);
      return;
    }

    const int64_t id = reinterpret_cast<int64_t>(FL_TEXTURE(tex));
    instance->texture_id = id;
    instance->texture = tex;

    if (bytes_ptr != nullptr && bytes_len > 0) {
      std::error_code ec;
      std::filesystem::create_directories(mgr->cache_dir, ec);
      std::filesystem::path file =
          mgr->cache_dir / (std::to_string(id) + ".mp4");
      std::ofstream out(file, std::ios::binary | std::ios::trunc);
      out.write(reinterpret_cast<const char*>(bytes_ptr),
                static_cast<std::streamsize>(bytes_len));
      out.close();
      if (!out) {
        fl_texture_registrar_unregister_texture(mgr->texture_registrar,
                                                FL_TEXTURE(tex));
        g_object_unref(tex);
        fl_method_call_respond_error(
            call, "motion_video", "Failed to write temp file", nullptr, nullptr);
        return;
      }
      instance->temp_file = file;
      instance->media_uri = file.string();
    } else {
      instance->media_uri = url_str;
    }

    mgr->videos[id] = instance;
    instance->StartWorker();

    g_autoptr(FlValue) res = fl_value_new_int(id);
    fl_method_call_respond_success(call, res, nullptr);
    return;
  }

  if (strcmp(method, "setPlaying") == 0) {
    if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* id_val = fl_value_lookup_string(args, "id");
      FlValue* play_val = fl_value_lookup_string(args, "playing");
      if (id_val && fl_value_get_type(id_val) == FL_VALUE_TYPE_INT) {
        const int64_t id = fl_value_get_int(id_val);
        const bool playing =
            (play_val && fl_value_get_type(play_val) == FL_VALUE_TYPE_BOOL)
                ? fl_value_get_bool(play_val)
                : true;
        auto it = mgr->videos.find(id);
        if (it != mgr->videos.end()) {
          it->second->SetPlaying(playing);
        }
      }
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }

  if (strcmp(method, "dispose") == 0) {
    if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* id_val = fl_value_lookup_string(args, "id");
      if (id_val && fl_value_get_type(id_val) == FL_VALUE_TYPE_INT) {
        const int64_t id = fl_value_get_int(id_val);
        auto it = mgr->videos.find(id);
        if (it != mgr->videos.end()) {
          auto instance = it->second;
          mgr->videos.erase(it);
          instance->Stop();
          if (instance->texture) {
            fl_texture_registrar_unregister_texture(
                mgr->texture_registrar, FL_TEXTURE(instance->texture));
            g_object_unref(instance->texture);
            instance->texture = nullptr;
          }
        }
      }
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }

  fl_method_call_respond_not_implemented(call, nullptr);
}

void motion_video_plugin_register(FlPluginRegistrar* registrar) {
  auto mgr = std::make_shared<ManagerState>();
  mgr->texture_registrar = fl_plugin_registrar_get_texture_registrar(registrar);
  std::error_code ec;
  mgr->cache_dir =
      std::filesystem::temp_directory_path(ec) / "flutify_motion_video";
  std::filesystem::remove_all(mgr->cache_dir, ec);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  mgr->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "com.flutify/motion_video",
      FL_METHOD_CODEC(codec));

  fl_method_channel_set_method_call_handler(
      mgr->channel, method_call_cb, new std::shared_ptr<ManagerState>(mgr),
      [](gpointer data) {
        delete static_cast<std::shared_ptr<ManagerState>*>(data);
      });
}
