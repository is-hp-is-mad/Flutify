package com.flutify.music.flutify_app.widget

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject

/** 待播清单里的一项（只够小组件显示一行）。 */
data class QueueItem(val id: String, val title: String, val artist: String)

/** 桌面小组件的播放状态快照（Dart 侧经 WidgetBridgePlugin 推送）。 */
data class WidgetState(
    val id: String = "",
    val title: String = "",
    val artist: String = "",
    val album: String = "",
    val durationMs: Long = 0L,
    val isPlaying: Boolean = false,
    val isBuffering: Boolean = false,
    val coverPath: String? = null,
    val updatedAt: Long = 0L,
    /** 「来自 xx」：当前播放的歌单 / 专辑名，可为空。 */
    val contextName: String = "",
    /** 接下来要播的几首（用户队列在前），远程播放时为空。 */
    val queue: List<QueueItem> = emptyList(),
) {
    val hasTrack: Boolean get() = id.isNotEmpty() && title.isNotEmpty()

    /** 播放键显示「暂停」：播放中或正在缓冲（与系统媒体卡片一致）。 */
    val showsPause: Boolean get() = isPlaying || isBuffering

    /** Apple Music 同款：播放态 8 分钟无推送即视为已暂停（进程被回收、残留播放假象）。 */
    fun withPauseTimeout(now: Long = System.currentTimeMillis()): WidgetState =
        if (isPlaying && now - updatedAt > WidgetStateStore.PAUSE_TIMEOUT_MS) {
            copy(isPlaying = false, isBuffering = false)
        } else {
            this
        }
}

/**
 * 状态双写：SharedPreferences 供进程重启后恢复，StateFlow 供小组件会话内实时重组。
 *
 * Glance 的会话在点击 / 刚刷新后会保活一段时间，期间 updateAll 只触发重组、不会重新执行
 * provideGlance——所以组合里必须订阅 [flow]，不能在 provideGlance 里读一次快照。
 */
object WidgetStateStore {
    private const val FILE = "flutify_widget"
    const val PAUSE_TIMEOUT_MS = 480_000L

    @Volatile
    private var state: MutableStateFlow<WidgetState>? = null

    fun flow(context: Context): StateFlow<WidgetState> = holder(context)

    fun current(context: Context): WidgetState = holder(context).value

    fun write(context: Context, value: WidgetState) {
        update(context) { value }
    }

    /** 读-改-写（乐观更新、只换队列等），避免覆盖别的字段。 */
    fun update(context: Context, transform: (WidgetState) -> WidgetState): WidgetState {
        val flow = holder(context)
        val next = synchronized(this) {
            transform(flow.value).also { flow.value = it }
        }
        persist(context, next)
        return next
    }

    fun clear(context: Context) {
        holder(context).value = WidgetState()
        prefs(context).edit().clear().apply()
    }

    private fun holder(context: Context): MutableStateFlow<WidgetState> =
        state ?: synchronized(this) {
            state ?: MutableStateFlow(load(context)).also { state = it }
        }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    private fun persist(context: Context, s: WidgetState) {
        prefs(context).edit()
            .putString("id", s.id)
            .putString("title", s.title)
            .putString("artist", s.artist)
            .putString("album", s.album)
            .putLong("durationMs", s.durationMs)
            .putBoolean("isPlaying", s.isPlaying)
            .putBoolean("isBuffering", s.isBuffering)
            .putString("coverPath", s.coverPath)
            .putLong("updatedAt", s.updatedAt)
            .putString("contextName", s.contextName)
            .putString("queue", encodeQueue(s.queue))
            .apply()
    }

    private fun load(context: Context): WidgetState {
        val p = prefs(context)
        return WidgetState(
            id = p.getString("id", "") ?: "",
            title = p.getString("title", "") ?: "",
            artist = p.getString("artist", "") ?: "",
            album = p.getString("album", "") ?: "",
            durationMs = p.getLong("durationMs", 0L),
            isPlaying = p.getBoolean("isPlaying", false),
            isBuffering = p.getBoolean("isBuffering", false),
            coverPath = p.getString("coverPath", null),
            updatedAt = p.getLong("updatedAt", 0L),
            contextName = p.getString("contextName", "") ?: "",
            queue = decodeQueue(p.getString("queue", null)),
        )
    }

    private fun encodeQueue(queue: List<QueueItem>): String = JSONArray().apply {
        queue.forEach {
            put(JSONObject().put("id", it.id).put("title", it.title).put("artist", it.artist))
        }
    }.toString()

    private fun decodeQueue(raw: String?): List<QueueItem> {
        if (raw.isNullOrEmpty()) return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            List(array.length()) { i ->
                val o = array.getJSONObject(i)
                QueueItem(o.optString("id"), o.optString("title"), o.optString("artist"))
            }
        }.getOrDefault(emptyList())
    }
}
