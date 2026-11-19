package com.flutify.music.flutify_app

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.mp4.FragmentedMp4Extractor
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File

/// 艺人页头部动态视频：ExoPlayer 硬解直接画进 Flutter 纹理，静音循环。
///
/// 之前用内嵌 WebView 播 base64 视频，平台视图合成 + 整段转码让滚动掉帧；
/// 纹理与页面其他内容同层合成，暂停 / 继续只是播放器状态切换。
/// 每个实例独占一个播放器和一个缓存文件，`dispose` 时一并清理。
class MotionVideoPlugin private constructor(
    private val context: Context,
    private val textures: TextureRegistry,
    private val channel: MethodChannel,
) : MethodChannel.MethodCallHandler {

    private val videos = mutableMapOf<Long, Video>()
    private val cacheDir = File(context.cacheDir, "motion_video")

    companion object {
        private const val CHANNEL = "com.flutify/motion_video"

        // Apple Music 的 HLS fMP4 常从 10s 开始计时。作为本地短片播放时忽略 tfdt，
        // 按样本时长从 0 累加；否则首帧会提前显示，再等 10s，且每次循环都会重等。
        // seek 会重置分段解码时间，因此首次播放和原播放器内循环都使用同一时间轴。
        internal fun extractorsFactory() = DefaultExtractorsFactory()
            .setFragmentedMp4ExtractorFlags(
                FragmentedMp4Extractor.FLAG_WORKAROUND_IGNORE_TFDT_BOX,
            )

        fun register(flutterEngine: FlutterEngine, context: Context): MotionVideoPlugin {
            val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            val plugin = MotionVideoPlugin(
                context.applicationContext,
                flutterEngine.renderer,
                channel,
            )
            channel.setMethodCallHandler(plugin)
            // 上次进程异常退出留下的缓存
            plugin.cacheDir.deleteRecursively()
            return plugin
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "create" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null || bytes.isEmpty()) {
                        result.error("motion_video_args", "create 需要 bytes", null)
                        return
                    }
                    val playing = call.argument<Boolean>("playing") ?: true
                    result.success(create(bytes, playing))
                }
                "setPlaying" -> {
                    val video = videos[call.argument<Number>("id")?.toLong()]
                    video?.player?.playWhenReady = call.argument<Boolean>("playing") ?: true
                    result.success(null)
                }
                "dispose" -> {
                    videos.remove(call.argument<Number>("id")?.toLong())?.release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("motion_video", e.message, null)
        }
    }

    private fun create(bytes: ByteArray, playing: Boolean): Long {
        val producer = textures.createSurfaceProducer()
        val id = producer.id()
        cacheDir.mkdirs()
        val file = File(cacheDir, "$id.mp4")
        file.writeBytes(bytes)

        val player = ExoPlayer.Builder(context)
            .setMediaSourceFactory(DefaultMediaSourceFactory(context, extractorsFactory()))
            .build()
        // 只要画面：不解码音轨，也不参与音频焦点（不能打断正在播放的音乐）
        player.trackSelectionParameters = player.trackSelectionParameters
            .buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
            .build()
        player.volume = 0f
        player.repeatMode = Player.REPEAT_MODE_ONE
        player.setVideoSurface(producer.surface)

        val video = Video(producer, player, file)
        videos[id] = video

        // 应用退到后台时 Surface 会被回收，回来后换新的
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                if (videos[id] === video) player.setVideoSurface(producer.surface)
            }

            override fun onSurfaceCleanup() {
                if (videos[id] === video) player.setVideoSurface(null)
            }
        })

        player.addListener(object : Player.Listener {
            override fun onVideoSizeChanged(size: VideoSize) {
                if (size.width <= 0 || size.height <= 0 || videos[id] !== video) return
                producer.setSize(size.width, size.height)
                channel.invokeMethod(
                    "size",
                    mapOf("id" to id, "width" to size.width, "height" to size.height),
                )
            }

            override fun onRenderedFirstFrame() {
                if (videos[id] === video) channel.invokeMethod("ready", mapOf("id" to id))
            }

            override fun onPlayerError(error: PlaybackException) {
                if (videos[id] === video) {
                    channel.invokeMethod("error", mapOf("id" to id, "message" to error.message))
                }
            }
        })

        player.setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
        player.playWhenReady = playing
        player.prepare()
        return id
    }

    private class Video(
        val producer: TextureRegistry.SurfaceProducer,
        val player: ExoPlayer,
        val file: File,
    ) {
        fun release() {
            player.release()
            producer.release()
            file.delete()
        }
    }
}
