package io.github.tovechat.tove

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * The `io.github.tovechat.tove/call` MethodChannel.
 *
 * Flutter -> native: `startCall {muted}`, `updateCall {muted}`, `endCall {}`.
 * Native -> Flutter: `onMute {muted}`, `onEnd {}`.
 *
 * Every Flutter call is answered exactly once, including when a permission
 * dialog is dismissed, the activity disappears mid-request, the service fails
 * to enter the foreground, or the service never reports back (timeout).
 *
 * All methods run on the main thread.
 */
internal object CallBridge {
    const val CHANNEL = "io.github.tovechat.tove/call"
    private const val TAG = "HermesCallBridge"

    private const val REQUEST_MICROPHONE = 0x4851
    private const val REQUEST_NOTIFICATIONS = 0x4852

    /** Upper bound for the service to enter the foreground and report back. */
    private const val START_TIMEOUT_MS = 6_000L

    /** Dart must acknowledge onMute/onEnd within these, or the native side
     *  treats Dart as unreachable and tears the call down itself. */
    private const val MUTE_ACK_TIMEOUT_MS = 4_000L
    private const val END_ACK_TIMEOUT_MS = 8_000L

    private val main = Handler(Looper.getMainLooper())

    private var channel: MethodChannel? = null
    private var channelEngine: FlutterEngine? = null
    private var appContext: Context? = null

    private var activityRef: WeakReference<Activity>? = null
    private var activityStarted = false

    private var pendingStart: PendingStart? = null

    private class PendingStart(val result: MethodChannel.Result, val muted: Boolean) {
        var askedMicrophone = false
        var askedNotifications = false
        var waitingForService = false
        val timeout = Runnable {
            failPendingStart(
                "service_timeout",
                "The call service did not start in time.",
            )
        }
    }

    // ---- Engine and activity wiring -------------------------------------------------

    fun attach(engine: FlutterEngine, context: Context) {
        appContext = context.applicationContext
        channel?.setMethodCallHandler(null)
        channelEngine = engine
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::onMethodCall)
        }
    }

    fun detach(engine: FlutterEngine) {
        if (channelEngine !== engine) return
        channel?.setMethodCallHandler(null)
        channel = null
        channelEngine = null
        failPendingStart("engine_destroyed", "The Flutter engine was destroyed.")
        // Dart (and with it WebRTC) is gone, so the call cannot continue.
        HermesCallService.instance?.finishCall("engine_destroyed")
    }

    val currentActivity: Activity?
        get() = activityRef?.get()

    fun onActivityCreated(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    fun onActivityStarted(activity: Activity) {
        activityRef = WeakReference(activity)
        activityStarted = true
    }

    fun onActivityStopped(activity: Activity) {
        if (currentActivity === activity) activityStarted = false
    }

    fun onActivityDestroyed(activity: Activity) {
        if (currentActivity !== activity) return
        activityRef = null
        activityStarted = false
        val pending = pendingStart
        if (pending != null && !pending.waitingForService) {
            failPendingStart("not_visible", "Tove closed before the call could start.")
        }
    }

    fun onRequestPermissionsResult(requestCode: Int) {
        if (requestCode != REQUEST_MICROPHONE && requestCode != REQUEST_NOTIFICATIONS) return
        // Re-check the actual grant state instead of trusting the arrays, which
        // are empty when the request is interrupted.
        main.post { continueStart() }
    }

    // ---- Flutter -> native ------------------------------------------------------------

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startCall" -> {
                val muted = mutedArgument(call, result) ?: return
                startCall(muted, result)
            }
            "updateCall" -> {
                val muted = mutedArgument(call, result) ?: return
                val service = HermesCallService.instance
                service?.applyMutedFromFlutter(muted)
                result.success(mapOf("active" to HermesCallService.isActive))
            }
            "endCall" -> {
                failPendingStart("cancelled", "endCall was called before the call started.")
                HermesCallService.instance?.finishCall("flutter_end")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun mutedArgument(call: MethodCall, result: MethodChannel.Result): Boolean? {
        val value = (call.arguments as? Map<*, *>)?.get("muted")
        if (value is Boolean) return value
        result.error("bad_arguments", "${call.method} needs {muted: bool}.", null)
        return null
    }

    private fun startCall(muted: Boolean, result: MethodChannel.Result) {
        val service = HermesCallService.instance
        if (service != null && service.isForeground) {
            // Idempotent: already live, just sync the mute state.
            service.applyMutedFromFlutter(muted)
            result.success(startedPayload())
            return
        }
        if (pendingStart != null) {
            result.error("busy", "A call is already starting.", null)
            return
        }
        if (visibleActivity() == null) {
            // A microphone foreground service may only start while the app is
            // visible (while-in-use restriction), so never start from background.
            result.error(
                "not_visible",
                "Start a call only while Tove is open on screen.",
                null,
            )
            return
        }
        pendingStart = PendingStart(result, muted)
        continueStart()
    }

    private fun continueStart() {
        val pending = pendingStart ?: return
        if (pending.waitingForService) return
        val context = appContext
            ?: return failPendingStart("no_context", "The app context is not available.")

        if (!isGranted(context, Manifest.permission.RECORD_AUDIO)) {
            if (pending.askedMicrophone) {
                return failPendingStart(
                    "microphone_denied",
                    "Microphone permission was declined. Allow it in Settings to talk to Hermes.",
                )
            }
            val activity = visibleActivity()
                ?: return failPendingStart("not_visible", "Tove is not on screen.")
            pending.askedMicrophone = true
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MICROPHONE)
            return
        }

        if (Build.VERSION.SDK_INT >= 33 &&
            !isGranted(context, Manifest.permission.POST_NOTIFICATIONS) &&
            !pending.askedNotifications
        ) {
            val activity = visibleActivity()
                ?: return failPendingStart("not_visible", "Tove is not on screen.")
            // Asked once per start. If declined, the call still runs and the
            // result carries an honest warning instead of claiming controls.
            pending.askedNotifications = true
            activity.requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIFICATIONS,
            )
            return
        }

        if (visibleActivity() == null) {
            return failPendingStart("not_visible", "Tove is not on screen.")
        }

        pending.waitingForService = true
        main.postDelayed(pending.timeout, START_TIMEOUT_MS)
        try {
            HermesCallService.start(context, pending.muted)
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException (Android 12+),
            // SecurityException, IllegalStateException.
            Log.e(TAG, "startForegroundService failed", e)
            failPendingStart(
                "service_start_failed",
                "Android refused to start the call service (${e.javaClass.simpleName}).",
            )
        }
    }

    /**
     * Called by the service after startForeground. Returns false when nobody is
     * waiting any more (timed out or cancelled), so the service stops itself.
     */
    fun onServiceStartResult(errorCode: String?, message: String?): Boolean {
        val pending = pendingStart ?: return false
        if (!pending.waitingForService) return false
        if (errorCode != null) {
            failPendingStart(errorCode, message)
            return false
        }
        pendingStart = null
        main.removeCallbacks(pending.timeout)
        pending.result.success(startedPayload())
        return true
    }

    private fun failPendingStart(code: String, message: String?) {
        val pending = pendingStart ?: return
        pendingStart = null
        main.removeCallbacks(pending.timeout)
        if (pending.waitingForService) {
            HermesCallService.instance?.finishCall("start_failed:$code")
        }
        pending.result.error(code, message, null)
    }

    private fun startedPayload(): Map<String, Any?> {
        val context = appContext
        val visible = context != null && notificationsVisible(context)
        return mapOf(
            "notificationsVisible" to visible,
            "warning" to if (visible) null else context?.getString(R.string.call_warning_notifications_off),
        )
    }

    // ---- Native -> Flutter ------------------------------------------------------------

    /** [onOutcome] gets true only when Dart answered and did not return false. */
    fun sendMute(muted: Boolean, onOutcome: (Boolean) -> Unit) =
        invokeWithAck("onMute", mapOf("muted" to muted), MUTE_ACK_TIMEOUT_MS, onOutcome)

    fun sendEnd(onOutcome: (Boolean) -> Unit) =
        invokeWithAck("onEnd", emptyMap<String, Any>(), END_ACK_TIMEOUT_MS, onOutcome)

    private fun invokeWithAck(
        method: String,
        arguments: Map<String, Any>,
        timeoutMs: Long,
        onOutcome: (Boolean) -> Unit,
    ) {
        val target = channel
        if (target == null) {
            Log.w(TAG, "$method: no Flutter engine attached")
            onOutcome(false)
            return
        }
        val ack = Ack(method, onOutcome)
        main.postDelayed(ack.timeout, timeoutMs)
        target.invokeMethod(method, arguments, object : MethodChannel.Result {
            override fun success(result: Any?) = ack.complete(result != false)

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                Log.w(TAG, "$method failed in Dart: $errorCode $errorMessage")
                ack.complete(false)
            }

            override fun notImplemented() {
                Log.w(TAG, "$method has no Dart handler")
                ack.complete(false)
            }
        })
    }

    private class Ack(private val method: String, private val onOutcome: (Boolean) -> Unit) {
        private var done = false
        val timeout = Runnable {
            Log.w(TAG, "$method: Dart did not answer in time")
            complete(false)
        }

        fun complete(delivered: Boolean) {
            if (done) return
            done = true
            main.removeCallbacks(timeout)
            onOutcome(delivered)
        }
    }

    // ---- Helpers ----------------------------------------------------------------------

    private fun visibleActivity(): Activity? {
        val activity = currentActivity ?: return null
        if (!activityStarted || activity.isFinishing || activity.isDestroyed) return null
        return activity
    }

    private fun isGranted(context: Context, permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun notificationsVisible(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = manager.getNotificationChannel(CallNotification.CHANNEL_ID)
            if (channel != null && channel.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        return true
    }
}
