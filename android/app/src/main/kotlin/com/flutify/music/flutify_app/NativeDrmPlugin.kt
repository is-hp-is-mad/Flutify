package com.flutify.music.flutify_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.drm.DefaultDrmSessionManager
import androidx.media3.exoplayer.drm.ExoMediaDrm
import androidx.media3.exoplayer.drm.FrameworkMediaDrm
import androidx.media3.exoplayer.drm.MediaDrmCallback
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.util.EventLogger
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID

/// Android 原生 DRM 播放插件：ExoPlayer（Media3）+ 设备 Widevine，纯音频、无界面。
///
/// 为什么需要它：部分 Android WebView 的 EME 在 createMediaKeys 阶段永不 settle
/// （真机实测：HyperOS + WebView Chrome/143），WebView 链路无法播放 DRM 曲目；
/// 原生 ExoPlayer 用系统 MediaDrm，不受此影响。HLS 清单、加密 m4a、license/证书反代
/// 全部复用 Dart 侧 EmePlayer 的本地回环 HTTP 服务，本插件只接收两个 URL：
/// 本地化后的 m3u8 与 license 反代地址（EXT-X-KEY 的 KEYFORMAT 已由 Dart 改写为
/// Widevine UUID 形式，这里对清单内容不做任何魔改）。
class NativeDrmPlugin(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val appContext = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private var player: ExoPlayer? = null
    private var requestedVolume = 1f
    private var eventSink: EventChannel.EventSink? = null

    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL).also {
        it.setMethodCallHandler(this)
    }
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL).also {
        it.setStreamHandler(this)
    }

    companion object {
        private const val METHOD_CHANNEL = "flutify/native_drm"
        private const val EVENT_CHANNEL = "flutify/native_drm/events"
        private const val POSITION_INTERVAL_MS = 500L
        private val registeredEngines = java.util.WeakHashMap<FlutterEngine, NativeDrmPlugin>()

        fun register(flutterEngine: FlutterEngine, context: Context): NativeDrmPlugin =
            registeredEngines.getOrPut(flutterEngine) {
                NativeDrmPlugin(context, flutterEngine.dartExecutor.binaryMessenger)
            }
    }

    // ---- MethodChannel ----
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "play" -> {
                    val hlsUrl = call.argument<String>("hlsUrl")
                    val licenseUrl = call.argument<String>("licenseUrl")
                    val provisionUrl = call.argument<String>("provisionUrl")
                    if (hlsUrl.isNullOrEmpty() || licenseUrl.isNullOrEmpty() || provisionUrl.isNullOrEmpty()) {
                        result.error("ndrm_args", "play 需要 hlsUrl / licenseUrl / provisionUrl", null)
                        return
                    }
                    val autoplay = call.argument<Boolean>("autoplay") ?: true
                    val positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L
                    play(hlsUrl, licenseUrl, provisionUrl, autoplay, positionMs)
                    result.success(null)
                }
                "pause" -> { player?.pause(); result.success(null) }
                "resume" -> { player?.play(); result.success(null) }
                "seek" -> {
                    val positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L
                    player?.seekTo(positionMs)
                    result.success(null)
                }
                "setVolume" -> {
                    val volume = call.argument<Number>("volume")?.toFloat() ?: 1f
                    requestedVolume = volume.coerceIn(0f, 1f)
                    player?.volume = requestedVolume
                    result.success(null)
                }
                "stop" -> { stopPlayback(); result.success(null) }
                "dispose" -> { release(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("ndrm", e.message, null)
        }
    }

    /// 播一首：回环 HLS（EXT-X-BYTERANGE 指向本地加密 m4a）+ Widevine。
    /// DRM 链手动装配（不走 drmConfiguration 的默认 HttpMediaDrmCallback）：
    /// license 与 provisioning 全部 POST 到 Dart 回环反代——设备 CDM 需 provisioning，
    /// 而其自带的 Google provisioning 地址在用户网络被掐（静默重试、永不返回）。
    /// 清单里 KEYFORMAT 已是 Widevine UUID，drm scheme 由 HLS EXT-X-KEY 识别。
    /// 切歌复用同一实例（stop + clearMediaItems 后重新 setMediaItem）。
    private fun play(hlsUrl: String, licenseUrl: String, provisionUrl: String,
                     autoplay: Boolean, positionMs: Long) {
        val p = ensurePlayer()
        drmCallback.licenseUrl = licenseUrl
        drmCallback.provisionUrl = provisionUrl
        p.stop()
        p.clearMediaItems()
        val item = MediaItem.Builder()
            .setUri(hlsUrl)
            .setMimeType(MimeTypes.APPLICATION_M3U8)
            .build()
        // Set the intent before prepare: a revoked transfer must never briefly play.
        p.playWhenReady = autoplay
        p.setMediaItem(item, positionMs.coerceAtLeast(0L))
        p.prepare()
    }

    /// DRM 请求全部走 Dart 回环反代；URL 每首歌一样，play() 时更新即可（无并发：赋值在 prepare 前）
    private val drmCallback = RelayDrmCallback()
    private val drmManager by lazy {
        DefaultDrmSessionManager.Builder()
            .setUuidAndExoMediaDrmProvider(C.WIDEVINE_UUID, FrameworkMediaDrm.DEFAULT_PROVIDER)
            .build(drmCallback)
    }

    private fun ensurePlayer(): ExoPlayer {
        player?.let { return it }
        val p = ExoPlayer.Builder(appContext)
            .setMediaSourceFactory(
                HlsMediaSource.Factory(DefaultHttpDataSource.Factory())
                    .setDrmSessionManagerProvider { drmManager }
            )
            // USAGE_MEDIA，交给系统管理音频焦点；纯音频播放，不持亮屏唤醒锁
            .setAudioAttributes(AudioAttributes.DEFAULT, true)
            .setHandleAudioBecomingNoisy(true)
            .build()
        // 诊断：打出 loader/DRM 全事件（drmSessionAcquired/drmKeysLoaded/
        // drmSessionManagerError/loadError 等），logcat tag 带 ndrm 前缀
        p.addAnalyticsListener(EventLogger(null, "ndrm"))
        p.volume = requestedVolume
        p.addListener(playerListener)
        handler.post(positionTicker)
        player = p
        return p
    }

    /// DRM 回调：license / provisioning 请求 POST 到 Dart 回环反代（HttpURLConnection 同步阻塞，
    /// MediaDrm 在工作线程调用本类方法，无需切线程；Dart 侧遵守 App 代理策略外发）。
    private class RelayDrmCallback : MediaDrmCallback {
        var licenseUrl: String = ""
        var provisionUrl: String = ""

        override fun executeKeyRequest(uuid: UUID, request: ExoMediaDrm.KeyRequest): MediaDrmCallback.Response {
            return MediaDrmCallback.Response(post(licenseUrl, request.data))
        }

        override fun executeProvisionRequest(uuid: UUID, request: ExoMediaDrm.ProvisionRequest): MediaDrmCallback.Response {
            // Widevine 约定（与 ExoPlayer 自带 HttpMediaDrmCallback 一致）：provision 数据是
            // ASCII 字符串，作为 query 参数 signedRequest 拼进目标地址，POST body 为空
            val dataString = String(request.data, Charsets.UTF_8)
            val target = if (!request.defaultUrl.isNullOrEmpty()) {
                val joiner = if (request.defaultUrl.contains("?")) "&signedRequest=" else "?signedRequest="
                request.defaultUrl + joiner + dataString
            } else {
                // 旧式 CDM 无 defaultUrl：回退 license 地址 + signedRequest
                "$licenseUrl?signedRequest=$dataString"
            }
            return MediaDrmCallback.Response(post(provisionUrl + "?target=" + URLEncoder.encode(target, "UTF-8"), ByteArray(0)))
        }

        /// body 原样 POST，响应全量返回；非 2xx 抛带状态码与错误正文（前 200B）的异常
        private fun post(url: String, body: ByteArray): ByteArray {
            val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15000
                readTimeout = 15000
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Content-Type", "application/octet-stream")
            }
            try {
                conn.outputStream.use { it.write(body) }
                val code = conn.responseCode
                if (code in 200..299) {
                    return conn.inputStream.use { it.readBytes() }
                }
                val errBytes = runCatching { conn.errorStream?.use { it.readBytes() } }.getOrNull()
                val errText = errBytes?.let { String(it, 0, minOf(it.size, 200)) }.orEmpty()
                throw IOException("DRM 反代 HTTP $code $errText")
            } finally {
                conn.disconnect()
            }
        }
    }

    private fun stopPlayback() {
        player?.let {
            it.stop()
            it.clearMediaItems()
        }
    }

    private fun release() {
        handler.removeCallbacks(positionTicker)
        player?.release()
        player = null
    }

    // ---- EventChannel ----
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun send(payload: Map<String, Any?>) {
        eventSink?.success(payload)
    }

    private val playerListener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) = sendState()

        override fun onIsPlayingChanged(isPlaying: Boolean) = sendState()

        override fun onPlayerError(error: PlaybackException) {
            val cause = error.cause
            // DrmSession 层异常常有两层 cause（DrmSessionException → HttpDrmCallback 的底层 IO 异常）
            val deep = cause?.cause?.message?.let { " <- $it" } ?: ""
            send(
                mapOf(
                    "type" to "error",
                    "code" to error.errorCode,
                    // cause 里通常带真正原因（DrmSessionException / HTTP 500 等）
                    "message" to (error.errorCodeName + ": " + (cause?.message ?: error.message ?: "unknown") + deep),
                )
            )
        }

        private fun sendState() {
            val p = player ?: return
            val name = when (p.playbackState) {
                Player.STATE_BUFFERING -> "buffering"
                Player.STATE_READY -> "ready"
                Player.STATE_ENDED -> "ended"
                else -> "idle"
            }
            send(mapOf("type" to "state", "state" to name, "playing" to p.isPlaying))
        }
    }

    private val positionTicker = object : Runnable {
        override fun run() {
            player?.let {
                send(
                    mapOf(
                        "type" to "position",
                        "position" to it.currentPosition,
                        "duration" to if (it.duration == C.TIME_UNSET) 0L else it.duration,
                    )
                )
            }
            handler.postDelayed(this, POSITION_INTERVAL_MS)
        }
    }
}
