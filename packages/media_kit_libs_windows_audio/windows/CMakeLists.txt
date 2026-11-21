# Derived from media_kit_libs_windows_audio 1.0.9 (MIT).
# Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
# Flutify modification: select and verify native libmpv for x64 / ARM64.
cmake_minimum_required(VERSION 3.14)

option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)
set(PROJECT_NAME "media_kit_libs_windows_audio")
project(${PROJECT_NAME} LANGUAGES CXX)

if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  set(LIBMPV "mpv-dev-aarch64-20241021-git-0f78584.7z")
  set(LIBMPV_URL "https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/20241021/${LIBMPV}")
  set(LIBMPV_SHA256 "d445d02ab2ee60b1b5988f08ce4d2394cdcc594e98321b746a313313e96133ae")
elseif(FLUTTER_TARGET_PLATFORM STREQUAL "windows-x64")
  # Flutify: switched from audio-only to video build to enable native texture
  # video playback for artist motion videos on desktop (instead of WebView).
  set(LIBMPV "mpv-dev-x86_64-20230924-git-652a1dd.7z")
  set(LIBMPV_URL "https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/${LIBMPV}")
  set(LIBMPV_SHA256 "d5f0694b08c124e785d858d00082f3e3b158dd9138bfc48c0382bf1eb443a5fc")
else()
  message(FATAL_ERROR "Unsupported libmpv target: ${FLUTTER_TARGET_PLATFORM}")
endif()

set(LIBMPV_ARCHIVE "${CMAKE_BINARY_DIR}/${LIBMPV}")
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv-${LIBMPV_SHA256}")
# CMake reuses an existing download only when its hash matches.
file(DOWNLOAD "${LIBMPV_URL}" "${LIBMPV_ARCHIVE}"
  EXPECTED_HASH "SHA256=${LIBMPV_SHA256}" TLS_VERIFY ON
  STATUS LIBMPV_DOWNLOAD_STATUS)
list(GET LIBMPV_DOWNLOAD_STATUS 0 LIBMPV_DOWNLOAD_CODE)
if(NOT LIBMPV_DOWNLOAD_CODE EQUAL 0)
  message(FATAL_ERROR "libmpv download failed: ${LIBMPV_DOWNLOAD_STATUS}")
endif()

if(NOT EXISTS "${LIBMPV_SRC}/libmpv-2.dll")
  file(MAKE_DIRECTORY "${LIBMPV_SRC}")
  execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${LIBMPV_ARCHIVE}"
    WORKING_DIRECTORY "${LIBMPV_SRC}" RESULT_VARIABLE LIBMPV_EXTRACT_RESULT)
  if(NOT LIBMPV_EXTRACT_RESULT EQUAL 0 OR NOT EXISTS "${LIBMPV_SRC}/libmpv-2.dll")
    message(FATAL_ERROR "Could not extract ${LIBMPV}")
  endif()
endif()

set(PLUGIN_NAME "media_kit_libs_windows_audio_plugin")
add_library(${PLUGIN_NAME} SHARED
  "include/media_kit_libs_windows_audio/media_kit_libs_windows_audio_plugin_c_api.h"
  "media_kit_libs_windows_audio_plugin_c_api.cpp")
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
set(media_kit_libs_windows_audio_bundled_libraries
  "${LIBMPV_SRC}/libmpv-2.dll" PARENT_SCOPE)
