package com.flutify.music.flutify_app

import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 歌词界面常亮：给 Activity 窗口加 / 去 FLAG_KEEP_SCREEN_ON。
 * 只在窗口可见时生效，切到后台或锁屏后系统照常熄屏，不需要 WAKE_LOCK 权限。
 */
object ScreenAwakePlugin {
    fun register(engine: FlutterEngine, activity: MainActivity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "flutify/screen_awake")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKeepScreenOn" -> {
                        val on = call.arguments as? Boolean ?: false
                        activity.runOnUiThread {
                            if (on) {
                                activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
