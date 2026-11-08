package com.flutify.music.flutify_app.widget.actions

import android.content.Context
import android.content.Intent
import androidx.glance.GlanceId
import androidx.glance.action.ActionParameters
import androidx.glance.appwidget.action.ActionCallback
import com.flutify.music.flutify_app.widget.FlutifyWidgets
import com.flutify.music.flutify_app.widget.MediaKeyDispatcher
import com.flutify.music.flutify_app.widget.WidgetBridgePlugin
import com.flutify.music.flutify_app.widget.WidgetStateStore

/**
 * 播放 / 暂停：先乐观翻转图标再发媒体键，点下去立刻有反馈；
 * 真实状态随后由 Dart 推送校正（进程被杀时由 8 分钟超时兜底）。
 */
class PlayPauseAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val state = WidgetStateStore.current(context).withPauseTimeout()
        if (state.hasTrack) {
            val pausing = state.showsPause
            WidgetStateStore.update(context) {
                it.copy(isPlaying = !pausing, isBuffering = false, updatedAt = System.currentTimeMillis())
            }
        }
        // 乐观状态先落地再发键：Dart 的真实推送一定排在它后面，不会被它覆盖
        MediaKeyDispatcher.playPause(context)
        if (state.hasTrack) FlutifyWidgets.refreshAll(context)
    }
}

class NextAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        MediaKeyDispatcher.next(context)
    }
}

class PreviousAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        MediaKeyDispatcher.previous(context)
    }
}

/** 点封面 / 歌名 / 空态回 App（等价点 launcher 图标，singleTask 复用已有界面）。 */
class OpenAppAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        openApp(context)
    }
}

/**
 * 待播清单点一行：App 在跑就交给 Dart 直接跳到那首（带曲目 id 校验，防队列已变）；
 * 进程没起来 / Dart 拒绝时回 App。
 */
class PlayQueueItemAction : ActionCallback {
    override suspend fun onAction(context: Context, glanceId: GlanceId, parameters: ActionParameters) {
        val index = parameters[IndexKey] ?: return
        val trackId = parameters[TrackIdKey] ?: return
        if (!WidgetBridgePlugin.playQueueItem(index, trackId)) openApp(context)
    }

    companion object {
        val IndexKey = ActionParameters.Key<Int>("queueIndex")
        val TrackIdKey = ActionParameters.Key<String>("queueTrackId")
    }
}

private fun openApp(context: Context) {
    val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    } ?: return
    context.startActivity(intent)
}
