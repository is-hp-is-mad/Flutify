cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "media_controls.cpp"
  "media_identity.cpp"
  "snap_layout.cpp"
  "system_proxy_windows.cpp"
  "taskbar_lyrics.cpp"
  "taskbar_lyrics_painter.cpp"
  "taskbar_lyrics_window.cpp"
  "taskbar_widget_locator.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "windows_trust_store.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# 源文件含中文注释（UTF-8 无 BOM）；不加时中文系统按 GBK 读取，C4819 在 /WX 下变成错误
target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "crypt32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "winhttp.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "advapi32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib" "propsys.lib")
# 系统媒体控制（SMTC）使用 C++/WinRT
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
# 任务栏歌词：GDI+ 绘制、SHCreateMemStream 解码封面、UI Automation 定位小组件
target_link_libraries(${BINARY_NAME} PRIVATE "gdiplus.lib" "shlwapi.lib" "ole32.lib" "oleaut32.lib" "uiautomationcore.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Isolate experimental CDM crashes from the UI process. The installed browser
# owns the CDM DLL; it is discovered at runtime and never bundled here.
if(NOT CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64")
  add_executable(flutify_cdm_bridge "../../tool/cdm/native_cdm_bridge.cpp")
  target_compile_features(flutify_cdm_bridge PRIVATE cxx_std_17)
  target_compile_options(flutify_cdm_bridge PRIVATE /utf-8 /W4 /WX /EHsc)
  add_dependencies(${BINARY_NAME} flutify_cdm_bridge)
endif()
