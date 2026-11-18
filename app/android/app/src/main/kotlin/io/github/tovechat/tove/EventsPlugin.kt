package io.github.tovechat.tove

import android.app.Activity
import android.app.Application
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Channel `tove/events` between Dart's `InstantNotifications` and [EventsService].
 *
 * Dart → native: `configure {enabled, url, key, deviceId, heartbeat, systemEnabled, assistantName, appName}`
 * (starts or stops the service; called from the visible app, so Android 12+ allows the start), `status`,
 * `requestBatteryExemption` (the system dialog; falls back to the list), `openBatterySettings` (the system's
 * battery-optimisation list), `openNotificationSettings`, `launchChat`. `status` includes `batteryExempt`.
 * Native → Dart: `event` (an events-stream event as JSON, only while the app is on screen) and `open`
 * (a notification posted by the service was tapped while the app runs).
 */
class EventsPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, PluginRegistry.NewIntentListener {

    companion object {
        const val CHANNEL = "tove/events"
        private val main = Handler(Looper.getMainLooper())
    }

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var launchChat: String? = null

    private val callbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(a: Activity) {
            if (a === activity) EventsService.appVisible = true
        }

        override fun onActivityPaused(a: Activity) {
            if (a === activity) EventsService.appVisible = false
        }

        override fun onActivityCreated(a: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityStarted(a: Activity) = Unit
        override fun onActivityStopped(a: Activity) = Unit
        override fun onActivitySaveInstanceState(a: Activity, outState: Bundle) = Unit
        override fun onActivityDestroyed(a: Activity) = Unit
    }

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        appContext = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
        EventsService.ensureChannels(b.applicationContext)
        EventsService.forward = { json ->
            val ch = channel
            if (ch == null) false else {
                main.post { ch.invokeMethod("event", json) }
                true
            }
        }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        EventsService.forward = null
        EventsService.appVisible = false
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext ?: return result.error("detached", null, null)
        when (call.method) {
            "configure" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                val url = call.argument<String>("url") ?: ""
                val key = call.argument<String>("key") ?: ""
                EventsConfig.save(context, enabled && url.isNotEmpty() && key.isNotEmpty(), url, key,
                    call.argument<String>("deviceId"), call.argument<Int>("heartbeat") ?: 80,
                    call.argument<Boolean>("systemEnabled") ?: true,
                    call.argument<String>("assistantName") ?: "Hermes", call.argument<String>("appName") ?: "Tove")
                if (EventsConfig.enabled(context)) {
                    if (EventsConfig.status(context) in setOf("unauthorized", "unsupported", "blocked")) EventsConfig.setStatus(context, "off")
                    EventsService.start(context)
                } else {
                    EventsService.stop(context)
                }
                result.success(status(context))
            }
            "status" -> result.success(status(context))
            "requestBatteryExemption" -> result.success(requestExemption(context))
            "openBatterySettings" -> result.success(open(context, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)))
            "openNotificationSettings" -> result.success(open(context,
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)))
            "launchChat" -> {
                result.success(launchChat)
                launchChat = null
            }
            else -> result.notImplemented()
        }
    }

    private fun status(c: Context): Map<String, Any?> {
        val power = c.getSystemService(PowerManager::class.java)
        val nm = c.getSystemService(NotificationManager::class.java)
        return EventsConfig.snapshot(c) + mapOf(
            "batteryExempt" to (power?.isIgnoringBatteryOptimizations(c.packageName) ?: true),
            "notificationsAllowed" to (nm?.areNotificationsEnabled() ?: true),
            "sdk" to Build.VERSION.SDK_INT,
        )
    }

    /** The system dialog that lets the user exempt Tove from battery optimisation (what ntfy asks for too). */
    private fun requestExemption(c: Context): Boolean {
        val power = c.getSystemService(PowerManager::class.java)
        if (power?.isIgnoringBatteryOptimizations(c.packageName) == true) return true
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + c.packageName))
        return open(c, intent) || open(c, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
    }

    private fun open(c: Context, intent: Intent): Boolean = try {
        val a = activity
        if (a != null) a.startActivity(intent) else c.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (_: Exception) {
        false
    }

    private fun chatOf(intent: Intent?): String? =
        if (intent?.action == EventsService.ACTION_OPEN_CHAT) intent.getStringExtra(EventsService.EXTRA_CONVERSATION) else null

    override fun onNewIntent(intent: Intent): Boolean {
        val id = chatOf(intent) ?: return false
        channel?.invokeMethod("open", id)
        return true
    }

    private fun attach(b: ActivityPluginBinding) {
        detach()
        binding = b
        activity = b.activity
        b.addOnNewIntentListener(this)
        b.activity.application.registerActivityLifecycleCallbacks(callbacks)
        chatOf(b.activity.intent)?.let {
            launchChat = it
            b.activity.intent.action = Intent.ACTION_MAIN        // read once, also across config changes
        }
        EventsService.appVisible = true
    }

    private fun detach() {
        binding?.removeOnNewIntentListener(this)
        activity?.application?.unregisterActivityLifecycleCallbacks(callbacks)
        binding = null
        activity = null
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) = attach(b)
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = attach(b)
    override fun onDetachedFromActivityForConfigChanges() = detach()
    override fun onDetachedFromActivity() {
        detach()
        EventsService.appVisible = false
    }
}

/**
 * Starts [EventsService] after a reboot and after an app update when instant notifications are on. Both
 * broadcasts are exempt from the background foreground-service start rule, and `specialUse` may start from them.
 */
class EventsBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED ->
                if (EventsConfig.enabled(context)) EventsService.start(context)
        }
    }
}
