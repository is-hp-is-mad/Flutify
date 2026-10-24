package com.flutify.music.flutify_app

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 歌词外显的原生桥：
 * - Flyme 状态栏歌词：把当前歌词行写进 audio_service 播放通知的 ticker，并加上 Flyme 的
 *   「常驻显示 ticker / 只更新 ticker」标志。通知属于本应用，直接按同一 id 重发即可，
 *   不需要改 audio_service；audio_service 自己重发通知后，下一句歌词会重新带上标志。
 * - 蓝牙音频设备：监听 A2DP 连接变化，上报已连接设备（名称 / 地址 / 是否车载），
 *   供 Dart 侧决定是否把媒体信息换成歌词（车机屏幕显示歌词）。
 */
class LyricBridgePlugin private constructor(private val activity: MainActivity) :
    EventChannel.StreamHandler {

    companion object {
        /** audio_service 播放通知的固定 id（AudioService.NOTIFICATION_ID）。 */
        private const val AUDIO_SERVICE_NOTIFICATION_ID = 1124

        /** Flyme：常驻显示 ticker（状态栏歌词）。 */
        private const val FLAG_ALWAYS_SHOW_TICKER = 0x01000000

        /** Flyme：只更新 ticker，不重新弹出整条通知。 */
        private const val FLAG_ONLY_UPDATE_TICKER = 0x02000000

        private const val REQUEST_BLUETOOTH = 0x4C42

        fun register(engine: FlutterEngine, activity: MainActivity) {
            val plugin = LyricBridgePlugin(activity)
            val messenger = engine.dartExecutor.binaryMessenger
            MethodChannel(messenger, "flutify/lyric_bridge").setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "isFlyme" -> result.success(isFlyme())
                        "setTicker" -> {
                            plugin.setTicker(call.argument<String>("text"))
                            result.success(null)
                        }
                        "hasBluetoothPermission" -> result.success(plugin.hasBluetoothPermission())
                        "requestBluetoothPermission" -> {
                            plugin.requestBluetoothPermission()
                            result.success(null)
                        }
                        "connectedDevices" -> plugin.queryConnected { result.success(it) }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("LYRIC_BRIDGE", e.message, null)
                }
            }
            EventChannel(messenger, "flutify/bluetooth_audio").setStreamHandler(plugin)
        }

        fun isFlyme(): Boolean {
            val display = Build.DISPLAY ?: ""
            return Build.MANUFACTURER.equals("meizu", ignoreCase = true) ||
                display.contains("flyme", ignoreCase = true)
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null

    // -------------------------------------------------------------------------
    // Flyme 状态栏歌词
    // -------------------------------------------------------------------------

    private fun setTicker(text: String?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val manager = activity.getSystemService(NotificationManager::class.java) ?: return
        // 只改当前还在显示的播放通知；通知已移除（停止播放）时不能把它重新发出来
        val active = manager.activeNotifications.firstOrNull {
            it.id == AUDIO_SERVICE_NOTIFICATION_ID && it.packageName == activity.packageName
        } ?: return
        val notification: Notification = active.notification
        val lyric = text?.takeIf { it.isNotBlank() }
        notification.tickerText = lyric
        notification.flags = if (lyric != null) {
            notification.flags or FLAG_ALWAYS_SHOW_TICKER or FLAG_ONLY_UPDATE_TICKER
        } else {
            notification.flags and (FLAG_ALWAYS_SHOW_TICKER or FLAG_ONLY_UPDATE_TICKER).inv()
        }
        manager.notify(active.tag, AUDIO_SERVICE_NOTIFICATION_ID, notification)
    }

    // -------------------------------------------------------------------------
    // 蓝牙音频设备
    // -------------------------------------------------------------------------

    private fun hasBluetoothPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(activity, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestBluetoothPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !hasBluetoothPermission()) {
            activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), REQUEST_BLUETOOTH)
        }
    }

    private fun adapter(): BluetoothAdapter? =
        activity.getSystemService(BluetoothManager::class.java)?.adapter

    /** 当前已连接的 A2DP 设备；没有权限 / 没有蓝牙时为空列表。 */
    private fun queryConnected(done: (List<Map<String, Any>>) -> Unit) {
        val adapter = adapter()
        if (adapter == null || !hasBluetoothPermission() || !safeEnabled(adapter)) {
            done(emptyList())
            return
        }
        val ok = adapter.getProfileProxy(activity, object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                val devices = try {
                    proxy.connectedDevices.map(::describe)
                } catch (_: SecurityException) {
                    emptyList()
                }
                adapter.closeProfileProxy(profile, proxy)
                main.post { done(devices) }
            }

            override fun onServiceDisconnected(profile: Int) {}
        }, BluetoothProfile.A2DP)
        if (!ok) done(emptyList())
    }

    private fun safeEnabled(adapter: BluetoothAdapter): Boolean = try {
        adapter.isEnabled
    } catch (_: SecurityException) {
        false
    }

    private fun describe(device: BluetoothDevice): Map<String, Any> {
        val cls = try { device.bluetoothClass } catch (_: SecurityException) { null }
        val major = cls?.deviceClass ?: 0
        // 车载音响 / 车载免提套件都按「车载」处理
        val isCar = major == BluetoothClass.Device.AUDIO_VIDEO_CAR_AUDIO ||
            major == BluetoothClass.Device.AUDIO_VIDEO_HANDSFREE
        val name = try { device.name } catch (_: SecurityException) { null }
        return mapOf(
            "address" to (device.address ?: ""),
            "name" to (name ?: ""),
            "isCar" to isCar,
        )
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                // 连接状态或适配器开关变化：重新查询完整列表，Dart 侧只处理快照
                queryConnected { sink?.success(it) }
            }
        }
        receiver = r
        val filter = IntentFilter().apply {
            addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
        }
        ContextCompat.registerReceiver(activity, r, filter, ContextCompat.RECEIVER_NOT_EXPORTED) // 系统广播不受 NOT_EXPORTED 限制
        queryConnected { sink?.success(it) }
    }

    override fun onCancel(arguments: Any?) {
        receiver?.let { runCatching { activity.unregisterReceiver(it) } }
        receiver = null
        sink = null
    }
}
