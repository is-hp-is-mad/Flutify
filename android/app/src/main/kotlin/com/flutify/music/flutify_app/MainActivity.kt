package com.flutify.music.flutify_app

import android.content.Context
import android.content.Intent
import com.flutify.music.flutify_app.widget.WidgetBridgePlugin
import com.ryanheise.audioservice.AudioServiceActivity
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

// audio_service 要求：Activity 与后台媒体服务共用同一个 Flutter 引擎（通知栏 / 锁屏控件）
class MainActivity : AudioServiceActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        val engineId = AudioServicePlugin.getFlutterEngineId()
        FlutterEngineCache.getInstance().get(engineId)?.let { return it }

        val launchArgs = extractLaunchArgs(intent)
        if (launchArgs.isEmpty()) {
            return super.provideFlutterEngine(context)
        }

        // AudioServicePlugin.getFlutterEngine() 不转发 Dart 入口参数，
        // 在带启动参数时提前创建并缓存同一个引擎，使 main(List<String> args) 在全平台一致生效。
        val engine = FlutterEngine(context.applicationContext)
        var route = initialRoute
        if (route == null && shouldHandleDeeplinking()) {
            val data = intent?.data
            if (data != null) {
                route = data.path
                val query = data.query
                if (!query.isNullOrEmpty()) {
                    route = "$route?$query"
                }
            }
        }
        engine.navigationChannel.setInitialRoute(route ?: "/")
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
            launchArgs,
        )
        FlutterEngineCache.getInstance().put(engineId, engine)
        return engine
    }

    private fun extractLaunchArgs(intent: Intent?): List<String> {
        if (intent == null) return emptyList()
        val result = mutableListOf<String>()

        intent.getStringArrayExtra("flutify_args")?.forEach { arg ->
            val trimmed = arg.trim()
            if (trimmed.isNotEmpty()) result.add(trimmed)
        }
        intent.getStringExtra("flutify_args")?.let { raw ->
            raw.trim().split(Regex("\\s+"))
                .filter { it.isNotEmpty() }
                .forEach { result.add(it) }
        }

        @Suppress("DEPRECATION")
        val mockExtra = intent.extras?.get("flutify_mock")
        val wantsMock = when (mockExtra) {
            is Boolean -> mockExtra
            is Number -> mockExtra.toInt() != 0
            is String -> mockExtra.equals("true", ignoreCase = true) || mockExtra == "1"
            else -> false
        }
        if (wantsMock && "--mock" !in result) {
            result.add("--mock")
        }

        intent.getStringExtra("flutify_e2e")?.trim()?.let { dir ->
            if (dir.isNotEmpty()) {
                result.add("--self-test-e2e=$dir")
            }
        }
        return result
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Android 原生 DRM 播放引擎（该机型 WebView EME 不可用，走 ExoPlayer + MediaDrm）
        NativeDrmPlugin.register(flutterEngine, this)
        UpdatePlugin.register(flutterEngine, this)
        // 歌词外显：Flyme 状态栏歌词、蓝牙（车机）媒体信息换歌词
        LyricBridgePlugin.register(flutterEngine, this)
        AudioOutputPlugin.register(flutterEngine, this)
        // 系统里点开的 spotify: / open.spotify.com 链接
        SpotifyLinkPlugin.register(flutterEngine, this)
        // 桌面小组件：Dart 播放状态 → WidgetStateStore → 刷新 Now Playing
        WidgetBridgePlugin.register(flutterEngine, applicationContext)
        // 小米 HyperOS 柔光玻璃与跨品牌 Android 原生渲染
        HyperGlassPlugin.register(flutterEngine, this)
        if (!flutterEngine.plugins.has(AppleMusicBackgroundPlugin::class.java)) {
            flutterEngine.plugins.add(AppleMusicBackgroundPlugin())
        }
    }

    // singleTask：已在运行时点开链接走这里，不再开第二个界面
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        SpotifyLinkPlugin.consume(this, intent)
    }
}
