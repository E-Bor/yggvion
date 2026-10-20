package dev.yggvion.yggvion

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.StatFs

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.yggvion/hardware").setMethodCallHandler { call, result ->
            if (call.method != "info") { result.notImplemented(); return@setMethodCallHandler }
            val memory = ActivityManager.MemoryInfo()
            (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
            result.success(mapOf("memory_bytes" to memory.totalMem, "free_bytes" to StatFs(filesDir.path).availableBytes, "name" to Build.MODEL))
        }
    }
}
