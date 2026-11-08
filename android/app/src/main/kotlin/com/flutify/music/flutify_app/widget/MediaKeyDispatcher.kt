package com.flutify.music.flutify_app.widget

import android.content.Context
import android.content.Intent
import android.view.KeyEvent

/**
 * 播控 = 模拟蓝牙耳机按键：向 audio_service 已 exported 的 MediaButtonReceiver 发媒体键广播。
 * 显式 setClassName 定向，避免国产 ROM 对隐式广播的限流；进程死了广播会先拉起本应用进程。
 */
object MediaKeyDispatcher {
    fun playPause(context: Context) = send(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)

    fun next(context: Context) = send(context, KeyEvent.KEYCODE_MEDIA_NEXT)

    fun previous(context: Context) = send(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS)

    fun send(context: Context, keyCode: Int) {
        dispatch(context, KeyEvent.ACTION_DOWN, keyCode)
        dispatch(context, KeyEvent.ACTION_UP, keyCode)
    }

    private fun dispatch(context: Context, action: Int, keyCode: Int) {
        val intent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
            setClassName(context, "com.ryanheise.audioservice.MediaButtonReceiver")
            putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(action, keyCode))
        }
        context.sendBroadcast(intent)
    }
}
