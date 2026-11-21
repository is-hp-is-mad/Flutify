#ifndef RUNNER_MOTION_VIDEO_PLUGIN_H_
#define RUNNER_MOTION_VIDEO_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter_plugin_registrar.h>
#include <flutter_texture_registrar.h>
#include <windows.h>

#include <cstdint>
#include <memory>

class MotionVideoPlugin {
 public:
  MotionVideoPlugin(FlutterDesktopPluginRegistrarRef registrar,
                    flutter::BinaryMessenger* messenger);
  ~MotionVideoPlugin();

  MotionVideoPlugin(const MotionVideoPlugin&) = delete;
  MotionVideoPlugin& operator=(const MotionVideoPlugin&) = delete;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_MOTION_VIDEO_PLUGIN_H_
