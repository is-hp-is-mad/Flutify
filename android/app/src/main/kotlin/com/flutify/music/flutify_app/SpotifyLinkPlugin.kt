package com.flutify.music.flutify_app

import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 系统里点开的 `spotify:` / `open.spotify.com` 链接（与 Windows 同名通道 `flutify/protocol`）。
 *
 * - `initialLink`：启动 Intent 里的链接，Dart 取一次后视为就绪；
 * - 运行中收到的新 Intent（singleTask → onNewIntent）推送 `openLink`；Dart 未就绪时先存着。
 * 「设为默认」由系统的打开方式选择器负责，这里不提供 status / setDefault。
 */
object SpotifyLinkPlugin {
    private var channel: MethodChannel? = null
    private var pending: String? = null
    private var dartReady = false
    private var engine: FlutterEngine? = null

    fun register(engine: FlutterEngine, activity: MainActivity) {
        // 引擎由 audio_service 缓存、与后台媒体服务共用：Activity 重建（返回键退出再进入）时引擎不变，
        // Dart 侧的主界面仍在、不会再取 initialLink，所以只有换了新引擎才重置「就绪」
        if (this.engine !== engine) {
            this.engine = engine
            dartReady = false
        }
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "flutify/protocol").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialLink" -> {
                        result.success(pending ?: "")
                        pending = null
                        dartReady = true
                    }
                    else -> result.notImplemented()
                }
            }
        }
        consume(activity, activity.intent)
    }

    /** 处理一个 Intent：取出链接后把它从 Intent 上清掉，避免 Activity 重建 / 从最近任务进入时重复播放。 */
    fun consume(activity: MainActivity, intent: Intent?) {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return
        // 从「最近任务」重新进入会带着当初的 Intent：不是新的点击
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        val link = intent.dataString?.takeIf { isSpotifyLink(it) } ?: return
        activity.intent = Intent(intent).apply { data = null }
        deliver(link)
    }

    private fun deliver(link: String) {
        val target = channel
        if (!dartReady || target == null) {
            pending = link
            return
        }
        target.invokeMethod("openLink", link)
    }

    private fun isSpotifyLink(link: String): Boolean =
        link.startsWith("spotify:", ignoreCase = true) ||
            Regex("^https?://(open|play)\\.spotify\\.com/", RegexOption.IGNORE_CASE).containsMatchIn(link)
}
