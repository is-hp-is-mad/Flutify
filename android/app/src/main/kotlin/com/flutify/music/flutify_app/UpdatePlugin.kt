package com.flutify.music.flutify_app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Exposes only downloaded APKs, never the app's credentials or other files. */
object UpdatePlugin {
    fun register(engine: FlutterEngine, activity: MainActivity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "flutify/updates")
            .setMethodCallHandler { call, result ->
                if (call.method != "installApk") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val path = call.argument<String>("path") ?: error("Missing APK path")
                    val apk = File(path).canonicalFile
                    val root = File(activity.cacheDir, "flutify-updates").canonicalFile
                    require(apk.path.startsWith(root.path + File.separator) && apk.isFile && apk.extension == "apk") {
                        "Invalid APK path"
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        !activity.packageManager.canRequestPackageInstalls()) {
                        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}")))
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", apk)
                    activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    })
                    result.success(true)
                } catch (e: Exception) {
                    result.error("UPDATE_INSTALL", e.message, null)
                }
            }
    }
}
