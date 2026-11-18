package io.github.tovechat.tove

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log

/**
 * Microphone-type foreground service for a live voice session.
 *
 * It does not own WebRTC. Dart does, through flutter_webrtc, on the engine that
 * [HermesEngine] keeps alive. This service keeps the process and that engine
 * running with the screen off, shows the ongoing notification, and turns its
 * Mute/End actions into `onMute`/`onEnd` calls to Dart. If Dart cannot be
 * reached it tears the engine down itself, so the microphone never stays open.
 *
 * Audio focus and MODE_IN_COMMUNICATION are owned by flutter_webrtc's
 * AudioSwitch (USAGE_VOICE_COMMUNICATION), started with the peer connection
 * and stopped when it is disposed or the plugin detaches. This service never
 * requests focus itself: a second request from the same app would make
 * AudioSwitch see a focus loss.
 */
class HermesCallService : Service() {

    companion object {
        private const val TAG = "HermesCallService"

        const val ACTION_START = "io.github.tovechat.tove.call.START"
        const val ACTION_MUTE = "io.github.tovechat.tove.call.MUTE"
        const val ACTION_UNMUTE = "io.github.tovechat.tove.call.UNMUTE"
        const val ACTION_END = "io.github.tovechat.tove.call.END"
        const val ACTION_REPOST = "io.github.tovechat.tove.call.REPOST"
        private const val EXTRA_MUTED = "muted"

        /** Dart acknowledged onEnd; it must call endCall within this. */
        private const val END_DEADLINE_MS = 10_000L

        /** After the task is swiped away, how long Dart gets to end cleanly. */
        private const val TASK_REMOVED_GRACE_MS = 4_000L

        @Volatile
        var instance: HermesCallService? = null
            private set

        val isActive: Boolean
            get() = instance?.isForeground == true

        /** Only called by CallBridge while the activity is visible. */
        fun start(context: Context, muted: Boolean) {
            val intent = Intent(context, HermesCallService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_MUTED, muted)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    private val main = Handler(Looper.getMainLooper())

    var isForeground = false
        private set
    private var muted = false
    private var startedAtWallMs = 0L
    private var muteInFlight = false
    private var ending = false
    private var finished = false

    private val endDeadline = Runnable {
        Log.w(TAG, "Dart acknowledged onEnd but never called endCall; tearing down")
        teardownWithoutFlutter("end_deadline")
    }

    private val taskRemovedDeadline = Runnable {
        Log.w(TAG, "Call still live after the task was removed; tearing down")
        teardownWithoutFlutter("task_removed")
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> handleStart(intent.getBooleanExtra(EXTRA_MUTED, false))
            ACTION_MUTE -> handleUserMute(true)
            ACTION_UNMUTE -> handleUserMute(false)
            ACTION_END -> requestEnd("user")
            ACTION_REPOST -> if (isForeground) refresh() else stopIfIdle()
            else -> stopIfIdle()
        }
        // Never restarted by the system: a restarted service would have no call.
        return START_NOT_STICKY
    }

    private fun handleStart(startMuted: Boolean) {
        if (isForeground) {
            applyMutedFromFlutter(startMuted)
            CallBridge.onServiceStartResult(null, null)
            return
        }
        muted = startMuted
        startedAtWallMs = System.currentTimeMillis()
        ending = false
        finished = false
        muteInFlight = false

        try {
            enterForeground(allowCallStyle = true)
        } catch (e: IllegalArgumentException) {
            // Defensive: a platform that rejects the CallStyle template.
            Log.w(TAG, "CallStyle rejected for startForeground, retrying plain", e)
            try {
                enterForeground(allowCallStyle = false)
            } catch (inner: Exception) {
                failStart(inner)
                return
            }
        } catch (e: Exception) {
            // SecurityException: RECORD_AUDIO or FOREGROUND_SERVICE_MICROPHONE
            // missing, or the app is not in an eligible (visible) state.
            // ForegroundServiceStartNotAllowedException on Android 12+.
            failStart(e)
            return
        }
        isForeground = true
        Log.i(TAG, "Microphone foreground service started")
        if (!CallBridge.onServiceStartResult(null, null)) {
            // Flutter stopped waiting (timeout or endCall). Do not run orphaned.
            finishCall("orphan_start")
        }
    }

    private fun enterForeground(allowCallStyle: Boolean) {
        val notification = CallNotification.build(
            this, muted, startedAtWallMs, ending = false, allowCallStyle = allowCallStyle,
        )
        // The microphone FGS type exists from API 30; Android 10 and older take
        // the type from the manifest only.
        if (Build.VERSION.SDK_INT >= 30) {
            startForeground(
                CallNotification.NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(CallNotification.NOTIFICATION_ID, notification)
        }
    }

    private fun failStart(e: Exception) {
        Log.e(TAG, "Could not enter the foreground", e)
        finished = true
        CallBridge.onServiceStartResult(
            "foreground_denied",
            "Android refused the microphone call service (${e.javaClass.simpleName}).",
        )
        stopSelf()
    }

    /** Flutter is the source of truth; called from startCall/updateCall. */
    fun applyMutedFromFlutter(value: Boolean) {
        if (!isForeground || finished) return
        if (muted == value) return
        muted = value
        refresh()
    }

    private fun handleUserMute(target: Boolean) {
        if (!isForeground) return stopIfIdle()
        if (ending || finished || muteInFlight) return
        if (target == muted) return refresh()
        muteInFlight = true
        CallBridge.sendMute(target) { delivered ->
            muteInFlight = false
            if (finished) return@sendMute
            if (delivered) {
                muted = target
                refresh()
            } else {
                // Without Dart nothing can toggle the WebRTC track. Ending the
                // call is the only way to honour a mute we cannot confirm.
                teardownWithoutFlutter("mute_unreachable")
            }
        }
    }

    private fun requestEnd(reason: String) {
        if (!isForeground) return stopIfIdle()
        if (ending || finished) return
        Log.i(TAG, "Ending call: $reason")
        ending = true
        refresh()
        CallBridge.sendEnd { delivered ->
            if (finished) return@sendEnd
            if (delivered) {
                main.postDelayed(endDeadline, END_DEADLINE_MS)
            } else {
                teardownWithoutFlutter("end_unreachable")
            }
        }
    }

    /** Normal stop: Dart called endCall, or an internal path decided to stop. */
    fun finishCall(reason: String) {
        if (finished && !isForeground) {
            stopSelf()
            return
        }
        Log.i(TAG, "Call finished: $reason")
        finished = true
        isForeground = false
        main.removeCallbacksAndMessages(null)
        stopForegroundCompat()
        stopSelf()
        HermesEngine.onCallFinished()
    }

    private fun teardownWithoutFlutter(reason: String) {
        finishCall(reason)
        HermesEngine.forceTeardown(applicationContext)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if (!isForeground || finished) return
        // The user swiped Tove away: end the session. Dart gets a short
        // window to close the peer connection and POST /api/stop.
        requestEnd("task_removed")
        main.postDelayed(taskRemovedDeadline, TASK_REMOVED_GRACE_MS)
    }

    override fun onDestroy() {
        val wasLive = isForeground && !finished
        main.removeCallbacksAndMessages(null)
        if (wasLive) {
            Log.w(TAG, "Destroyed while a call was live")
            finished = true
            isForeground = false
            stopForegroundCompat()
            val appContext = applicationContext
            CallBridge.sendEnd { delivered ->
                if (!delivered) HermesEngine.forceTeardown(appContext)
            }
            HermesEngine.onCallFinished()
        }
        if (instance === this) instance = null
        super.onDestroy()
    }

    private fun refresh() {
        if (!isForeground) return
        CallNotification.post(this, muted, startedAtWallMs, ending)
    }

    private fun stopIfIdle() {
        if (!isForeground) stopSelf()
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
    }
}
