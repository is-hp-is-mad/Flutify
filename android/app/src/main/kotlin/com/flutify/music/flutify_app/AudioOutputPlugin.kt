package com.flutify.music.flutify_app

import androidx.mediarouter.app.SystemOutputSwitcherDialogController
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 畅联「本机音频设备」（Android）：打开系统的媒体输出切换面板。
 * 系统面板对所有播放器生效（ExoPlayer / just_audio），并由系统列出手机扬声器、蓝牙、有线耳机等。
 */
object AudioOutputPlugin {
    fun register(engine: FlutterEngine, activity: MainActivity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "flutify/audio_output")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 返回 false：该系统没有可用的输出切换面板
                    "showSystemOutputSwitcher" -> result.success(
                        runCatching { SystemOutputSwitcherDialogController.showDialog(activity) }
                            .getOrDefault(false)
                    )
                    else -> result.notImplemented()
                }
            }
    }
}
