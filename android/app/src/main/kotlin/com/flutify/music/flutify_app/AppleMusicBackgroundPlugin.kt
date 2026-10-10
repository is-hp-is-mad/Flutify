@file:Suppress("DEPRECATION")

package com.flutify.music.flutify_app

import android.content.Context
import android.graphics.*
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.renderscript.Allocation
import android.renderscript.Element
import android.renderscript.RenderScript
import android.renderscript.ScriptIntrinsicBlur
import android.view.Surface
import android.view.animation.PathInterpolator
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import kotlin.math.*

/** Independent port of the documented micro-bitmap pipeline, not Apple code. */
class AppleMusicBackgroundPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding
    private lateinit var channel: MethodChannel
    private lateinit var thread: HandlerThread
    private lateinit var worker: Handler
    private val main = Handler(Looper.getMainLooper())
    private val backgrounds = mutableMapOf<Long, MicroArtwork>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        thread = HandlerThread("lyrics-micro-canvas").apply { start() }
        worker = Handler(thread.looper)
        channel = MethodChannel(binding.binaryMessenger, "com.flutify/apple_music_background")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "create") {
            val entry = binding.textureRegistry.createSurfaceTexture()
            val background = MicroArtwork(binding.applicationContext, entry, worker)
            backgrounds[entry.id()] = background
            result.success(entry.id())
            return
        }
        val id = call.argument<Number>("id")?.toLong()
        val background = backgrounds[id]
        if (call.method == "dispose") {
            backgrounds.remove(id)
            if (background != null) worker.post { background.close(); main.post { background.entry.release() } }
            result.success(null)
            return
        }
        if (background == null) {
            result.error("missing_texture", "Background is no longer available", null)
            return
        }
        if (call.method != "configure" && call.method != "artwork") {
            result.notImplemented()
            return
        }
        worker.post {
            try {
                if (call.method == "configure") background.configure(call)
                else background.setArtwork(call.argument<ByteArray>("bytes"))
                main.post { result.success(null) }
            } catch (e: Exception) {
                main.post { result.error("background_render", "Unable to update background", null) }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        val remaining = backgrounds.values.toList()
        backgrounds.clear()
        worker.post {
            remaining.forEach { it.close(); main.post { it.entry.release() } }
            thread.quitSafely()
        }
    }
}

private class MicroArtwork(
    private val context: Context,
    val entry: TextureRegistry.SurfaceTextureEntry,
    private val handler: Handler,
) {
    private val surface = Surface(entry.surfaceTexture())
    private var active = false
    private var reduced = false
    private var slow = false
    private var dark = true
    private var width = 1
    private var height = 1
    private var divisor = 24
    private var disposed = false
    private var staticMode = false
    private var overruns = 0
    private var elapsed = 0.0
    private var clock = 0L
    private var lastTick = 0L
    private var fadeStart = 0L
    private var artwork: Bitmap? = null
    private var queued: Bitmap? = null
    private var previous: Bitmap? = null
    private var buffer: Bitmap? = null
    private var blurred: Bitmap? = null
    private var distorted: Bitmap? = null
    private var dirty = true
    private var rs: RenderScript? = null
    private var blur: ScriptIntrinsicBlur? = null
    private var input: Allocation? = null
    private var output: Allocation? = null
    private val fadeCurve = PathInterpolator(0f, 0f, .3f, 1f)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private var meshVariant = 0
    private val tick = Runnable { render() }

    fun configure(call: MethodCall) {
        val nextActive = call.argument<Boolean>("active") ?: false
        if (nextActive != active) lastTick = 0
        active = nextActive
        if (!active) {
            // With no ticking clock, a pending fade would retain the old cover
            // forever. Settle on the latest artwork before rendering one frame.
            previous?.recycle(); previous = null
            queued?.let { queued = null; beginArtwork(it) }
        }
        val nextReduced = call.argument<Boolean>("reducedEffects") ?: false
        val nextDark = call.argument<Boolean>("dark") ?: true
        val density = call.argument<Number>("density")?.toDouble() ?: 1.0
        val nextDivisor = if (nextReduced) 72 else if (density * 160 >= 420) 24 else 16
        val nextWidth = (call.argument<Number>("width")?.toInt() ?: 1).coerceIn(1, 8192)
        val nextHeight = (call.argument<Number>("height")?.toInt() ?: 1).coerceIn(1, 8192)
        if (nextWidth != width || nextHeight != height || nextDivisor != divisor || nextDark != dark) dirty = true
        width = nextWidth; height = nextHeight; divisor = nextDivisor
        reduced = nextReduced; dark = nextDark
        slow = call.argument<Boolean>("reduceMotion") ?: false
        entry.surfaceTexture().setDefaultBufferSize(max(1, width / divisor), max(1, height / divisor))
        schedule()
    }

    fun setArtwork(bytes: ByteArray?) {
        // Flutter sends a decoded 128px PNG. Bound both encoded and decoded data.
        require(bytes == null || bytes.size <= 1024 * 1024)
        val image = if (bytes == null) Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.BLACK) }
        else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            require(bounds.outWidth in 1..512 && bounds.outHeight in 1..512)
            requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
        }
        if (previous != null) {
            queued?.recycle()
            queued = image
        } else beginArtwork(image)
        schedule()
    }

    private fun beginArtwork(image: Bitmap) {
        previous = if (active) blurred?.copy(Bitmap.Config.ARGB_8888, false) else null
        artwork?.recycle()
        artwork = image
        fadeStart = clock
        meshVariant = (meshVariant + 1) % 5
        dirty = true
    }

    private fun schedule() {
        handler.removeCallbacks(tick)
        if (!disposed) handler.post(tick)
    }

    private fun ensureBuffers(w: Int, h: Int) {
        if (buffer?.width == w && buffer?.height == h) return
        input?.destroy(); output?.destroy()
        buffer?.recycle(); blurred?.recycle(); distorted?.recycle()
        buffer = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        blurred = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        distorted = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val runtime = rs ?: RenderScript.create(context).also { rs = it }
        if (blur == null) blur = ScriptIntrinsicBlur.create(runtime, Element.U8_4(runtime)).apply { setRadius(25f) }
        input = Allocation.createFromBitmap(runtime, buffer)
        output = Allocation.createTyped(runtime, input!!.type)
    }

    private fun compose() {
        val image = artwork ?: return
        val w = max(1, (width * 1.3 / divisor).roundToInt())
        val h = max(1, (height * 1.3 / divisor).roundToInt())
        ensureBuffers(w, h)
        val canvas = Canvas(buffer!!)
        canvas.drawColor(Color.BLACK)
        val side = (max(w, h) * 1.3f).roundToInt().toFloat()
        paint.shader = null; paint.alpha = 255
        paint.colorFilter = ColorMatrixColorFilter(ColorMatrix().apply { setSaturation(if (reduced) 3.5f else 2.5f) })
        val periods = doubleArrayOf(-120000.0, 90000.0, 70000.0)
        for (i in 0..2) {
            val angle = ((elapsed / periods[i]) % 1 * 360).toFloat()
            val matrix = Matrix().apply {
                setScale(side / image.width, side / image.height)
                postRotate(angle, side / 2, side / 2)
                postTranslate((w - side) / 2, (h - side) / 2)
                if (i == 1) postTranslate(-.95f * w, -.7f * h)
                if (i == 2) { postTranslate(-.5f * w, .7f * h); postRotate(angle, w / 2f, h / 2f) }
            }
            canvas.drawBitmap(image, matrix, paint)
        }
        paint.colorFilter = null
        var source = buffer!!
        if (staticMode) {
            val mesh = FloatArray(72)
            for (y in 0..5) for (x in 0..5) {
                val i = (y * 6 + x) * 2
                val edge = sin(PI * x / 5) * sin(PI * y / 5)
                mesh[i] = (w * (x / 5.0 + .16 * edge * sin(y + meshVariant.toDouble()))).toFloat()
                mesh[i + 1] = (h * (y / 5.0 + .16 * edge * cos(x + meshVariant.toDouble()))).toFloat()
            }
            Canvas(distorted!!).apply { drawColor(Color.BLACK); drawBitmapMesh(source, 5, 5, mesh, 0, null, 0, paint) }
            source = distorted!!
        }
        Canvas(source).apply {
            drawColor(if (dark) 0x80000000.toInt() else 0x4D000000)
            drawColor(if (dark) 0x0DFFFFFF else 0x1AFFFFFF)
        }
        input!!.copyFrom(source)
        blur!!.setInput(input)
        blur!!.forEach(output)
        output!!.copyTo(blurred)
        dirty = false
    }

    private fun draw(canvas: Canvas, image: Bitmap, alpha: Int) {
        val shader = BitmapShader(image, Shader.TileMode.MIRROR, Shader.TileMode.MIRROR)
        shader.setLocalMatrix(Matrix().apply {
            setScale(canvas.width * 1.3f / image.width, canvas.height * 1.3f / image.height)
            postTranslate(-canvas.width * .15f, -canvas.height * .15f)
        })
        paint.shader = shader; paint.alpha = alpha; paint.colorFilter = null
        canvas.drawRect(0f, 0f, canvas.width.toFloat(), canvas.height.toFloat(), paint)
        paint.shader = null; paint.alpha = 255
    }

    private fun render() {
        if (disposed) return
        val now = SystemClock.uptimeMillis()
        val dt = if (active && lastTick > 0) now - lastTick else 0L
        lastTick = if (active) now else 0
        clock += dt
        elapsed += dt / if (slow) 2.1 else 1.0
        try {
            if (dirty || (active && !staticMode)) {
                val start = SystemClock.elapsedRealtimeNanos()
                compose()
                if (active && !staticMode && artwork != null) {
                    overruns = if (SystemClock.elapsedRealtimeNanos() - start > 15_000_000) overruns + 1 else 0
                    if (overruns >= 3) { staticMode = true; dirty = true }
                }
            }
            val canvas = surface.lockCanvas(null)
            try {
                canvas.drawColor(Color.BLACK)
                previous?.let { draw(canvas, it, 255) }
                val alpha = if (previous == null) 255 else (255 * fadeCurve.getInterpolation(((clock - fadeStart) / 1000f).coerceIn(0f, 1f))).roundToInt()
                blurred?.let { draw(canvas, it, alpha) }
            } finally { surface.unlockCanvasAndPost(canvas) }
            if (previous != null && clock - fadeStart >= 1000) {
                previous?.recycle(); previous = null
                queued?.let { queued = null; beginArtwork(it) }
            }
        } catch (e: Exception) {
            // Surface loss or unavailable intrinsic: freeze instead of spinning.
            active = false
        }
        if (active && (dirty || !staticMode || previous != null)) handler.postDelayed(tick, 42)
    }

    fun close() {
        disposed = true
        handler.removeCallbacks(tick)
        surface.release()
        input?.destroy(); output?.destroy(); blur?.destroy(); rs?.destroy()
        listOf(artwork, queued, previous, buffer, blurred, distorted).forEach { it?.recycle() }
    }
}
