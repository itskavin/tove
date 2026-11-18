package io.github.tovechat.tove

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlin.random.Random

/**
 * "Instant notifications": one long-lived `GET /api/events` stream to the user's own bridge (API.md "Events"),
 * held by this low-importance foreground service, so replies, finished live tasks and the assistant's alerts and
 * briefings arrive with only Tove installed: no Google Play services, no distributor app. This is what ntfy does.
 *
 * Why `specialUse`: none of the specific types fits. `dataSync` is for transfers, has a 6 h per 24 h limit on
 * Android 15+ and may not start from BOOT_COMPLETED; `remoteMessaging` is for relaying text messages between a
 * user's devices; `shortService` lasts about 3 minutes. A persistent push connection to a self-hosted server is the
 * documented example of a special use, declared with PROPERTY_SPECIAL_USE_FGS_SUBTYPE in the manifest. It has no time
 * limit and may start after boot and after an app update.
 *
 * Battery: the bridge sends a 6-byte heartbeat every 80 s (under Cloudflare's 100 s idle limit) and nothing else
 * while idle. The phone never sends anything on its own; the socket read times out at 2 × heartbeat + 20 s, so a dead
 * connection is replaced when the device next wakes. A foreground service keeps network access in Doze, the CPU
 * still sleeps between packets, and a short wake lock covers only the handling of an event. Reconnects back off
 * (2 s doubling to 5 min, with jitter) and wait for a validated network.
 *
 * The bridge URL and key come from Dart ([EventsPlugin.configure]); the key is stored encrypted with an Android
 * Keystore key ([KeyBox]). While the app is on screen, events go to Dart (in-app banner or nothing); otherwise this
 * service posts the system notification itself on the app's "Replies" channel, deduplicated by message id.
 */
class EventsService : Service() {

    companion object {
        private const val TAG = "ToveEvents"
        const val CHANNEL_CONNECTION = "tove_connection"
        const val CHANNEL_REPLIES = "hermes_replies"          // shared with Dart's LocalNotificationSink
        const val NOTIFICATION_ID = 0x5445
        const val ACTION_OPEN_CHAT = "io.github.tovechat.tove.OPEN_CHAT"
        const val EXTRA_CONVERSATION = "tove_conversation_id"
        const val EXTRA_MESSAGE = "tove_message_id"
        private const val ACTION_START = "io.github.tovechat.tove.events.START"
        private const val MAX_BACKOFF_MS = 5 * 60_000L
        private const val STABLE_AFTER_MS = 60_000L

        @Volatile
        var instance: EventsService? = null
            private set

        /** Set by [EventsPlugin] while Dart listens; returns true when the event went to Dart. */
        @Volatile
        var forward: ((String) -> Boolean)? = null

        /** The activity is resumed (set by [EventsPlugin]). */
        @Volatile
        var appVisible = false

        fun start(context: Context): Boolean {
            val intent = Intent(context, EventsService::class.java).setAction(ACTION_START)
            return try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
                true
            } catch (e: Exception) {
                // ForegroundServiceStartNotAllowedException from the background (Android 12+), or a SecurityException.
                Log.w(TAG, "Could not start the events service", e)
                EventsConfig.setStatus(context, "blocked")
                false
            }
        }

        fun stop(context: Context) {
            instance?.shutdown("stop") ?: context.stopService(Intent(context, EventsService::class.java))
        }

        fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_CONNECTION) == null) {
                // MIN: no status-bar icon, no sound, collapsed at the bottom of the shade.
                manager.createNotificationChannel(NotificationChannel(
                    CHANNEL_CONNECTION, context.getString(R.string.events_channel_name), NotificationManager.IMPORTANCE_MIN,
                ).apply {
                    description = context.getString(R.string.events_channel_description)
                    setShowBadge(false)
                    enableVibration(false)
                    enableLights(false)
                    setSound(null, null)
                })
            }
            if (manager.getNotificationChannel(CHANNEL_REPLIES) == null) {
                // Same id, name and importance as flutter_local_notifications creates it with.
                manager.createNotificationChannel(NotificationChannel(
                    CHANNEL_REPLIES, context.getString(R.string.replies_channel_name), NotificationManager.IMPORTANCE_DEFAULT,
                ).apply { description = context.getString(R.string.replies_channel_description) })
            }
        }

        /** The same id as Dart's `ReplyNotice.notificationId`, so either side can replace or clear it. */
        fun noticeId(key: String): Int {
            var h = 0
            for (c in key) h = (h * 31 + c.code) and 0x3fffffff
            return h
        }
    }

    @Volatile private var running = false
    private var worker: Thread? = null
    private val lock = Object()
    @Volatile private var connection: HttpURLConnection? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var isForeground = false

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (EventsConfig.load(this) == null) {
            // Turned off, signed out, or the key cannot be read: nothing to hold open.
            enterForeground()          // startForegroundService needs a startForeground before stopping
            shutdown("not configured")
            return START_NOT_STICKY
        }
        enterForeground()
        if (!isForeground) return START_NOT_STICKY
        if (worker?.isAlive != true) {
            running = true
            listenForNetwork()
            worker = Thread(::loop, "tove-events").also { it.isDaemon = true; it.start() }
        } else {
            wake()                     // a kick (app start, settings): reconnect now if waiting
        }
        // Sticky: if the system kills the process, it restarts the service (allowed for a sticky foreground service).
        return START_STICKY
    }

    private fun enterForeground() {
        if (isForeground) return
        try {
            val n = ongoing(getString(R.string.events_status_connecting))
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
            isForeground = true
        } catch (e: Exception) {
            Log.e(TAG, "Could not enter the foreground", e)
            EventsConfig.setStatus(this, "blocked")
            isForeground = false
            stopSelf()
        }
    }

    // ---- the connection loop (worker thread)
    private fun loop() {
        var attempt = 0
        while (running) {
            val cfg = EventsConfig.load(this)
            if (cfg == null) {
                shutdownFromWorker("not configured")
                return
            }
            if (!hasNetwork()) {
                status("waiting_network")
                pause(15 * 60_000L)         // the network callback wakes it sooner
                continue
            }
            status("connecting")
            val started = System.currentTimeMillis()
            val outcome = try {
                read(cfg)
            } catch (e: Exception) {
                if (running) Log.i(TAG, "Events stream ended: ${e.javaClass.simpleName}")
                "io"
            } finally {
                connection?.disconnect()
                connection = null
            }
            if (!running) return
            when (outcome) {
                "unauthorized", "unsupported" -> {
                    // The key is wrong or the bridge has no events: retrying cannot help. Dart shows the status.
                    status(outcome)
                    shutdownFromWorker(outcome)
                    return
                }
            }
            if (System.currentTimeMillis() - started > STABLE_AFTER_MS) attempt = 0
            val base = minOf(MAX_BACKOFF_MS, 2_000L shl minOf(attempt, 8))
            val delay = if (outcome == "busy") maxOf(base, 60_000L) else base
            attempt++
            status("reconnecting")
            pause((delay * (0.8 + Random.nextDouble() * 0.4)).toLong())
        }
    }

    /** One stream until it ends. Returns why: "io", "busy", "server", "unauthorized", "unsupported". */
    private fun read(cfg: EventsConfig): String {
        val q = StringBuilder("/api/events?heartbeat=").append(cfg.heartbeat)
        cfg.deviceId?.let { q.append("&device_id=").append(URLEncoder.encode(it, "UTF-8")) }
        val c = URL(cfg.base.trimEnd('/') + q).openConnection() as HttpURLConnection
        connection = c
        c.connectTimeout = 20_000
        c.readTimeout = (cfg.heartbeat * 2 + 20) * 1000
        c.useCaches = false
        c.instanceFollowRedirects = false
        c.setRequestProperty("Authorization", "Bearer " + cfg.key)
        c.setRequestProperty("Accept", "text/event-stream")
        val last = EventsConfig.lastId(this)
        if (last > 0) c.setRequestProperty("Last-Event-ID", last.toString())
        when (val code = c.responseCode) {
            200 -> Unit
            401 -> return "unauthorized"
            404 -> return "unsupported"
            429 -> return "busy"
            else -> {
                Log.i(TAG, "Events stream refused: HTTP $code")
                return "server"
            }
        }
        status("connected")
        EventsConfig.markConnected(this)
        val reader = BufferedReader(InputStreamReader(c.inputStream, Charsets.UTF_8))
        var event: String? = null
        var id: Long? = null
        val data = StringBuilder()
        while (running) {
            val line = reader.readLine() ?: return "io"
            when {
                line.isEmpty() -> {
                    if (event != null && data.isNotEmpty()) dispatch(event, id, data.toString())
                    event = null; id = null; data.setLength(0)
                }
                line.startsWith(":") -> EventsConfig.markHeartbeat(this)
                line.startsWith("event:") -> event = line.substring(6).trim()
                line.startsWith("id:") -> id = line.substring(3).trim().toLongOrNull()
                line.startsWith("data:") -> {
                    if (data.isNotEmpty()) data.append('\n')
                    data.append(line.substring(5).removePrefix(" "))
                }
            }
        }
        return "io"
    }

    private fun dispatch(type: String, id: Long?, data: String) {
        val power = getSystemService(PowerManager::class.java)
        val wl = power?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "tove:events")?.apply { acquire(10_000L) }
        try {
            EventsConfig.markHeartbeat(this)
            val json = try { JSONObject(data) } catch (_: Exception) { return }
            if (id != null) EventsConfig.setLastId(this, id)
            if (type == "hello") return
            val wire = JSONObject().put("type", type).put("id", id ?: JSONObject.NULL).put("data", json).toString()
            // On screen: Dart decides (banner for another chat, nothing for the open one).
            if (appVisible && forward?.invoke(wire) == true) return
            notifyFor(type, json)
        } finally {
            if (wl?.isHeld == true) wl.release()
        }
    }

    // ---- system notifications for events nobody on this device saw
    private fun notifyFor(type: String, d: JSONObject) {
        val cfg = EventsConfig.load(this) ?: return
        if (!cfg.systemEnabled) return
        val status = d.optString("status")
        val watched = d.optBoolean("watched", false)
        val kind = when (type) {
            "reply.done" -> when {
                watched -> null              // a reader on some device followed it to the end
                status == "stopped" -> null
                status == "failed" || status == "interrupted" -> "failed"
                else -> "reply"
            }
            "task.done" -> when {
                watched || status == "stopped" -> null
                status == "failed" || status == "interrupted" -> "task_failed"
                else -> "task"
            }
            "notify" -> "reply"
            "test" -> "test"
            else -> null
        } ?: return
        val conv = d.optString("conversation_id").takeIf { it.isNotEmpty() && it != "null" }
        val msg = d.optString("message_id").takeIf { it.isNotEmpty() && it != "null" }
        if (msg != null && !EventsConfig.claimNotice(this, msg)) return       // already announced
        val title = d.optString("title").takeIf { it.isNotBlank() && it != "null" }
        val preview = d.optString("preview").takeIf { it.isNotBlank() && it != "null" }
        val heading = title ?: when (kind) {
            "task", "task_failed" -> getString(R.string.events_task_heading, cfg.assistantName)
            "test" -> getString(R.string.events_test_heading, cfg.appName)
            else -> cfg.assistantName
        }
        val body = when (kind) {
            "failed" -> if (preview == null) getString(R.string.events_failed) else getString(R.string.events_failed_with, preview)
            "task_failed" -> getString(R.string.events_task_failed)
            else -> preview ?: when (kind) {
                "task" -> getString(R.string.events_task_body)
                "test" -> getString(R.string.events_test_body)
                else -> getString(R.string.events_reply_body)
            }
        }
        val nid = noticeId(conv ?: msg ?: kind)
        val open = Intent(this, MainActivity::class.java)
            .setAction(ACTION_OPEN_CHAT)
            .putExtra(EXTRA_CONVERSATION, conv)
            .putExtra(EXTRA_MESSAGE, msg)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(this, nid, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        ensureChannels(this)
        val n = builder(CHANNEL_REPLIES)
            .setSmallIcon(R.drawable.ic_stat_hermes)
            .setColor(getColor(R.color.hermes_accent))
            .setContentTitle(heading)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        try {
            getSystemService(NotificationManager::class.java)?.notify(nid, n)
        } catch (e: RuntimeException) {
            Log.w(TAG, "Could not post a notification", e)     // POST_NOTIFICATIONS denied (Android 13+)
        }
    }

    // ---- helpers
    @Suppress("DEPRECATION")
    private fun builder(channel: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channel) else Notification.Builder(this)

    private fun ongoing(text: String): Notification {
        ensureChannels(this)
        val open = PendingIntent.getActivity(
            this, NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return builder(CHANNEL_CONNECTION)
            .setSmallIcon(R.drawable.ic_stat_hermes)
            .setContentTitle(getString(R.string.events_ongoing_title, EventsConfig.appName(this)))
            .setContentText(text)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setLocalOnly(true)
            .setContentIntent(open)
            .build()
    }

    private fun status(s: String) {
        if (EventsConfig.status(this) == s) return
        EventsConfig.setStatus(this, s)
        val text = when (s) {
            "connected" -> getString(R.string.events_status_connected)
            "waiting_network" -> getString(R.string.events_status_offline)
            "reconnecting" -> getString(R.string.events_status_reconnecting)
            else -> getString(R.string.events_status_connecting)
        }
        if (isForeground) {
            try {
                getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, ongoing(text))
            } catch (_: RuntimeException) {
            }
        }
    }

    private fun hasNetwork(): Boolean {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return true
        if (Build.VERSION.SDK_INT < 23) return true
        val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    private fun listenForNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        if (Build.VERSION.SDK_INT < 24 || networkCallback != null) return
        val cb = object : ConnectivityManager.NetworkCallback() {
            private var current: Network? = null
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return
                if (current != null && current != network) connection?.disconnect()   // Wi-Fi ↔ mobile: move over now
                current = network
                wake()
            }

            override fun onLost(network: Network) {
                if (network == current) {
                    current = null
                    connection?.disconnect()
                }
            }
        }
        try {
            cm.registerDefaultNetworkCallback(cb)
            networkCallback = cb
        } catch (e: RuntimeException) {
            Log.w(TAG, "No network callback", e)
        }
    }

    private fun pause(ms: Long) {
        synchronized(lock) {
            if (running) lock.wait(ms)
        }
    }

    private fun wake() {
        synchronized(lock) { lock.notifyAll() }
    }

    private fun shutdownFromWorker(reason: String) {
        android.os.Handler(mainLooper).post { shutdown(reason) }
    }

    fun shutdown(reason: String) {
        Log.i(TAG, "Events service stopping: $reason")
        running = false
        wake()
        connection?.disconnect()
        networkCallback?.let {
            try {
                getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it)
            } catch (_: RuntimeException) {
            }
        }
        networkCallback = null
        if (EventsConfig.status(this) !in setOf("unauthorized", "unsupported", "blocked")) EventsConfig.setStatus(this, "off")
        isForeground = false
        @Suppress("DEPRECATION")
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else stopForeground(true)
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Not expected for specialUse (no time limit); stop cleanly if a future Android adds one.
        shutdown("timeout")
    }

    override fun onDestroy() {
        running = false
        wake()
        connection?.disconnect()
        if (instance === this) instance = null
        super.onDestroy()
    }
}
