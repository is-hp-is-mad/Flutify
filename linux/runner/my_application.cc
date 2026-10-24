#include "my_application.h"

#include <string.h>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // 主窗口：再次 activate（第二个实例 / 再次启动）时只把它提到前台，不新建窗口
  GtkWindow* window;
  // spotify: 链接（通道 flutify/protocol，与其他平台同一套 Dart 逻辑）
  FlMethodChannel* protocol_channel;
  gchar* pending_link;
  gboolean dart_ready;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static gboolean is_spotify_link(const gchar* arg) {
  return arg != nullptr && (g_str_has_prefix(arg, "spotify:") ||
                            strstr(arg, "open.spotify.com/") != nullptr);
}

// Dart 侧取过 initialLink 才算就绪，之前到达的链接先存着（只保留最新一条）。
static void deliver_link(MyApplication* self, const gchar* link) {
  if (!self->dart_ready || self->protocol_channel == nullptr) {
    g_free(self->pending_link);
    self->pending_link = g_strdup(link);
    return;
  }
  g_autoptr(FlValue) value = fl_value_new_string(link);
  fl_method_channel_invoke_method(self->protocol_channel, "openLink", value,
                                  nullptr, nullptr, nullptr);
}

static void protocol_method_cb(FlMethodChannel* channel, FlMethodCall* call,
                               gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (strcmp(fl_method_call_get_name(call), "initialLink") == 0) {
    g_autoptr(FlValue) result =
        fl_value_new_string(self->pending_link ? self->pending_link : "");
    g_clear_pointer(&self->pending_link, g_free);
    self->dart_ready = TRUE;
    fl_method_call_respond_success(call, result, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(call, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    gtk_window_present(self->window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Flutify draws its own title bar (window_manager TitleBarStyle.hidden),
  // so never add a GTK header bar or a native title that would double up.
  gtk_window_set_title(window, "Flutify");
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_resizable(window, TRUE);

  gtk_window_set_default_size(window, 1360, 860);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->protocol_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "flutify/protocol", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->protocol_channel, protocol_method_cb, self, nullptr);

  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window),
                            reinterpret_cast<gpointer*>(&self->window));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::open：第二个实例转发来的链接（主实例里执行）。
static void my_application_open(GApplication* application, GFile** files,
                                gint n_files, const gchar* hint) {
  MyApplication* self = MY_APPLICATION(application);
  my_application_activate(application);
  for (gint i = 0; i < n_files; i++) {
    g_autofree gchar* uri = g_file_get_uri(files[i]);
    if (is_spotify_link(uri)) deliver_link(self, uri);
  }
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  const gchar* link = nullptr;
  for (gchar** arg = *arguments + 1; *arg != nullptr; ++arg) {
    if (is_spotify_link(*arg)) {
      link = *arg;
      break;
    }
  }

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  // 已有实例在运行（经 D-Bus 注册为远端）：把链接 / 激活请求交给它，本进程退出
  if (g_application_get_is_remote(application)) {
    if (link != nullptr) {
      g_autoptr(GFile) file = g_file_new_for_uri(link);
      GFile* files[] = {file};
      g_application_open(application, files, 1, "");
    } else {
      g_application_activate(application);
    }
    *exit_status = 0;
    return TRUE;
  }

  if (link != nullptr) deliver_link(self, link);
  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_pointer(&self->pending_link, g_free);
  g_clear_object(&self->protocol_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_OPEN, nullptr));
}
