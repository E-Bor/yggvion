package dev.yggvion.yggvion

import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val tracking = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.yggvion/tracking")
        TrackingNotification.bridge = tracking
        tracking.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "pending" -> result.success(TrackingNotification.pending(this))
                    "publish" -> result.success(TrackingNotification.publish(this, call.arguments as Map<*, *>))
                    "clear" -> { TrackingNotification.clear(this); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("tracking_failed", "Не удалось обновить таймер на экране блокировки", null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "dev.yggvion/notification_settings").setMethodCallHandler { call, result ->
            if (call.method != "open") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                } else {
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName"))
                }
                startActivity(intent)
                result.success(true)
            } catch (e: android.content.ActivityNotFoundException) {
                result.error("settings_unavailable", "Notification settings are unavailable", null)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        TrackingNotification.bridge?.setMethodCallHandler(null)
        TrackingNotification.bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
