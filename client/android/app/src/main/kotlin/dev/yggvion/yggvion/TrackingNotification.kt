package dev.yggvion.yggvion

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.net.Uri
import android.os.*
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.UUID

/** Native actions survive Flutter suspension/process death. Only the private,
 * explicit receiver can modify them; each button is bound to a state revision. */
object TrackingNotification {
    private const val CHANNEL = "task_tracking"
    const val ID = 0x79677472
    private const val STORE = "system_tracking"
    var bridge: MethodChannel? = null

    private fun read(context: Context): JSONObject = JSONObject(
        context.getSharedPreferences(STORE, Context.MODE_PRIVATE)
            .getString("value", "{\"pending\":[]}")!!)

    private fun save(context: Context, envelope: JSONObject) {
        if (!context.getSharedPreferences(STORE, Context.MODE_PRIVATE).edit()
                .putString("value", envelope.toString()).commit()) {
            throw IOException("Не удалось сохранить действие таймера")
        }
    }

    fun pending(context: Context): Any = codec(read(context).getJSONArray("pending"))!!

    fun publish(context: Context, args: Map<*, *>): Boolean {
        val envelope = read(context)
        val acknowledged = (args["acknowledged"] as List<*>).toSet()
        val old = envelope.getJSONArray("pending")
        val remaining = JSONArray()
        for (i in 0 until old.length()) {
            val command = old.getJSONObject(i)
            if (!acknowledged.contains(command.getString("id"))) remaining.put(command)
        }
        envelope.put("pending", remaining)
        val accepted = remaining.length() == 0
        if (accepted) {
            envelope.put("state", (args["state"] as? Map<*, *>)?.let { JSONObject(it) }
                ?: JSONObject.NULL)
            envelope.put("revision", UUID.randomUUID().toString())
        }
        save(context, envelope)
        refresh(context)
        return accepted
    }

    fun clear(context: Context) {
        save(context, JSONObject().put("pending", JSONArray()))
        context.stopService(Intent(context, TrackingNotificationService::class.java))
        manager(context).cancel(ID)
    }

    fun perform(context: Context, intent: Intent) {
        val envelope = read(context)
        val state = envelope.optJSONObject("state") ?: return
        if (envelope.optString("revision") != intent.getStringExtra("revision") ||
            state.getString("taskId") != intent.getStringExtra("taskId")) return
        val action = intent.getStringExtra("action") ?: return
        if (action !in listOf("pause", "resume", "stop") ||
            action == "pause" && !state.getBoolean("running") ||
            action == "resume" && state.getBoolean("running")) return
        val pending = envelope.getJSONArray("pending")
        if (pending.length() >= 1024) throw IOException("Откройте Yggvion для сохранения таймера")
        val time = maxOf(System.currentTimeMillis(), state.getLong("updatedAtMs"))
        val session = if (action == "resume") UUID.randomUUID().toString() else null
        pending.put(JSONObject().put("id", UUID.randomUUID().toString())
            .put("taskId", state.getString("taskId"))
            .put("deviceId", state.getString("deviceId"))
            .put("action", action).put("atMs", time)
            .put("sessionIds", state.getJSONArray("sessionIds"))
            .put("newSessionId", session ?: JSONObject.NULL))
        state.put("elapsedMs", elapsed(state, time)).put("updatedAtMs", time)
            .put("running", action == "resume")
            .put("sessionIds", JSONArray().apply { if (session != null) put(session) })
        envelope.put("state", if (action == "stop") JSONObject.NULL else state)
            .put("revision", UUID.randomUUID().toString())
        save(context, envelope)
        refresh(context)
        bridge?.invokeMethod("actionsChanged", null)
    }

    private fun elapsed(state: JSONObject, now: Long): Long =
        maxOf(0, state.getLong("elapsedMs")) + if (state.getBoolean("running"))
            maxOf(0, now - state.getLong("updatedAtMs")) else 0

    private fun manager(context: Context) = context.getSystemService(NotificationManager::class.java)

    fun refresh(context: Context) {
        val state = read(context).optJSONObject("state")
        if (state?.getBoolean("running") == true) {
            val service = Intent(context, TrackingNotificationService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(service)
                else context.startService(service)
            } catch (error: IllegalStateException) {
                // A remote timer can arrive while Android prohibits starting
                // services. Keep the notification; retry when the app resumes.
                show(context)
            }
        } else {
            context.stopService(Intent(context, TrackingNotificationService::class.java))
            if (state == null) manager(context).cancel(ID) else show(context)
        }
    }

    fun show(context: Context) {
        notification(context)?.let { manager(context).notify(ID, it) }
    }

    fun notification(context: Context): Notification? {
        val envelope = read(context)
        val state = envelope.optJSONObject("state") ?: return null
        if (Build.VERSION.SDK_INT >= 26) {
            manager(context).createNotificationChannel(NotificationChannel(CHANNEL,
                "Текущая задача", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Таймер и управление задачей на экране блокировки"
                setSound(null, null)
            })
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL)
                      else Notification.Builder(context)
        val running = state.getBoolean("running")
        val elapsed = elapsed(state, System.currentTimeMillis())
        val planned = state.getLong("plannedMs")
        val open = PendingIntent.getActivity(context, 1, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        fun action(value: String, label: String, icon: Int): Notification.Action {
            val intent = Intent(context, TrackingActionReceiver::class.java)
                .setData(Uri.parse("yggvion-tracking://${envelope.getString("revision")}/$value"))
                .putExtra("revision", envelope.getString("revision"))
                .putExtra("taskId", state.getString("taskId"))
                .putExtra("action", value)
            return Notification.Action.Builder(icon, label,
                PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_IMMUTABLE)).build()
        }
        val minutes = elapsed / 60000
        val planMinutes = planned / 60000
        return builder.setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(state.getString("title"))
            .setContentText("${if (running) "В работе" else "Пауза"} · $minutes / $planMinutes мин")
            .setColor(state.optLong("accent", Color.rgb(156, 185, 255).toLong()).toInt())
            .setWhen(System.currentTimeMillis() - elapsed).setUsesChronometer(running)
            .setShowWhen(running).setOngoing(true).setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC).setCategory(Notification.CATEGORY_STOPWATCH)
            .setContentIntent(open)
            .setProgress(1000, if (planned > 0) minOf(1000, elapsed * 1000 / planned).toInt() else 0, false)
            .addAction(action(if (running) "pause" else "resume", if (running) "Пауза" else "Продолжить",
                if (running) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play))
            .addAction(action("stop", "Стоп", android.R.drawable.ic_menu_close_clear_cancel))
            .build()
    }

    private fun codec(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { codec(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { codec(value.get(it)) }
        else -> value
    }
}

class TrackingActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try { TrackingNotification.perform(context, intent) }
        catch (error: Exception) {
            android.util.Log.e("YggvionTracking", "Timer action could not be saved", error)
        }
    }
}

/** Only while the user tracks a task. The OS chronometer runs independently;
 * a small native update once a minute refreshes the progress, without Flutter,
 * network requests, a wake lock or exact alarms. */
class TrackingNotificationService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            TrackingNotification.show(this@TrackingNotificationService)
            handler.postDelayed(this, 60000)
        }
    }
    override fun onBind(intent: Intent?) = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = TrackingNotification.notification(this)
        if (notification == null) { stopSelf(); return START_NOT_STICKY }
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(TrackingNotification.ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else { startForeground(TrackingNotification.ID, notification) }
        handler.removeCallbacks(tick)
        handler.postDelayed(tick, 60000)
        return START_STICKY
    }
    override fun onDestroy() {
        handler.removeCallbacks(tick)
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_DETACH)
        else stopForeground(false)
        super.onDestroy()
    }
}
