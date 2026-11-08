package com.flutify.music.flutify_app.widget

import android.app.LocaleManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.LocaleList
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/**
 * Dart ↔ 原生的小组件通道（channel `flutify/widget_bridge`）。
 *
 * Dart → 原生：「update」曲目 + 播放态、「queue」来源名 + 待播清单、「clear」清空、
 * 「requestPin」从 App 内把某款小组件加到桌面、「setLocale」把 App 内语言同步成系统的单应用语言。
 * 所有写入按到达顺序串行处理：先把封面解码进 [ArtworkCache]，再写状态、刷新全部小组件——
 * 组合时封面已就绪，也不会出现后到的旧状态覆盖新状态。
 *
 * 原生 → Dart：「playQueueItem」待播清单点一行。
 */
object WidgetBridgePlugin {
    private var channel: MethodChannel? = null
    private var engine: FlutterEngine? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val writes = Channel<suspend () -> Unit>(Channel.UNLIMITED)

    init {
        scope.launch {
            for (write in writes) runCatching { write() }
        }
    }

    fun register(engine: FlutterEngine, context: Context) {
        // 引擎由 audio_service 缓存：Activity 重建时引擎不变，只有换了新引擎才重建通道
        if (this.engine === engine) return
        this.engine = engine
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "flutify/widget_bridge").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        val args = call.arguments as? Map<*, *>
                        enqueue(context) { current -> applyUpdate(current, args) }
                        result.success(null)
                    }
                    "queue" -> {
                        val args = call.arguments as? Map<*, *>
                        enqueue(context) { current -> applyQueue(current, args) }
                        result.success(null)
                    }
                    "clear" -> {
                        writes.trySend {
                            WidgetStateStore.clear(context)
                            FlutifyWidgets.refreshAll(context)
                        }
                        result.success(null)
                    }
                    "requestPin" -> result.success(requestPin(context, call.arguments as? String))
                    "setLocale" -> {
                        setLocale(context, call.arguments as? String)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /**
     * 请求桌面添加 [style] 款小组件，返回桌面是否接受了请求（之后由系统 / 桌面弹窗让用户确认）。
     *
     * 小组件列表之外的另一条添加路径（澎湃 OS 里经典小组件藏在列表底部的「安卓小部件」分区，不好找）。
     * 澎湃桌面收到请求后对非 miuiWidget 组件直接弹确认框。
     */
    private fun requestPin(context: Context, style: String?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val receiver = when (style) {
            "nowPlaying" -> NowPlayingWidgetReceiver::class.java
            "albumCard" -> AlbumCardWidgetReceiver::class.java
            "cover" -> CoverWidgetReceiver::class.java
            "upNext" -> UpNextWidgetReceiver::class.java
            else -> return false
        }
        val manager = context.getSystemService(AppWidgetManager::class.java) ?: return false
        if (!manager.isRequestPinAppWidgetSupported) return false
        return runCatching {
            manager.requestPinAppWidget(ComponentName(context, receiver), null, null)
        }.getOrDefault(false)
    }

    /**
     * App 内语言（Flutter 侧设置，默认简体中文）→ 系统的单应用语言，[tag] 为空表示跟随系统。
     *
     * 小组件文字（「来自 xx」「接下来播放」等）在本进程按 Android 资源取，不同步的话系统是英文时
     * 小组件就是英文、和 App 对不上。Android 13 以下没有单应用语言，维持系统语言。
     * MainActivity 声明了 configChanges=locale，切换不会重建界面。
     */
    private fun setLocale(context: Context, tag: String?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val manager = context.getSystemService(LocaleManager::class.java) ?: return
        val target = if (tag.isNullOrEmpty()) LocaleList.getEmptyLocaleList() else LocaleList.forLanguageTags(tag)
        if (manager.applicationLocales == target) return
        manager.applicationLocales = target
        writes.trySend {
            // 等新的语言配置下发到本进程后再重画
            delay(800)
            FlutifyWidgets.refreshAll(context)
        }
    }

    /** 交给 Dart 播放待播清单第 [index] 项；Dart 未就绪、拒绝或 2 秒无响应返回 false。 */
    suspend fun playQueueItem(index: Int, trackId: String): Boolean {
        val ch = channel ?: return false
        return withTimeoutOrNull(2_000L) {
            withContext(Dispatchers.Main) {
                suspendCancellableCoroutine { cont ->
                    ch.invokeMethod(
                        "playQueueItem",
                        mapOf("index" to index, "id" to trackId),
                        object : MethodChannel.Result {
                            override fun success(result: Any?) {
                                if (cont.isActive) cont.resume(result == true)
                            }

                            override fun error(code: String, message: String?, details: Any?) {
                                if (cont.isActive) cont.resume(false)
                            }

                            override fun notImplemented() {
                                if (cont.isActive) cont.resume(false)
                            }
                        },
                    )
                }
            }
        } ?: false
    }

    private fun enqueue(context: Context, transform: (WidgetState) -> WidgetState) {
        writes.trySend {
            val next = transform(WidgetStateStore.current(context))
            ArtworkCache.load(next.coverPath)
            WidgetStateStore.update(context) { transform(it) }
            FlutifyWidgets.refreshAll(context)
        }
    }

    private fun applyUpdate(current: WidgetState, map: Map<*, *>?): WidgetState {
        if (map == null) return current.copy(updatedAt = System.currentTimeMillis())
        fun str(key: String): String = (map[key] as? String).orEmpty()
        val id = str("id")
        val sameTrack = id == current.id
        return current.copy(
            id = id,
            title = str("title"),
            artist = str("artist"),
            album = str("album"),
            durationMs = (map["durationMs"] as? Number)?.toLong() ?: 0L,
            isPlaying = map["isPlaying"] as? Boolean ?: false,
            isBuffering = map["isBuffering"] as? Boolean ?: false,
            coverPath = (map["coverPath"] as? String)?.takeIf { it.isNotEmpty() },
            updatedAt = System.currentTimeMillis(),
            // 顺序切到下一首时先把它从「接下来」里摘掉，完整清单随后由 queue 推送校正
            queue = if (!sameTrack && current.queue.firstOrNull()?.id == id) current.queue.drop(1) else current.queue,
        )
    }

    private fun applyQueue(current: WidgetState, map: Map<*, *>?): WidgetState {
        val items = (map?.get("items") as? List<*>).orEmpty().mapNotNull { raw ->
            val item = raw as? Map<*, *> ?: return@mapNotNull null
            QueueItem(
                id = (item["id"] as? String).orEmpty(),
                title = (item["title"] as? String).orEmpty(),
                artist = (item["artist"] as? String).orEmpty(),
            )
        }
        return current.copy(contextName = (map?.get("context") as? String).orEmpty(), queue = items)
    }
}
