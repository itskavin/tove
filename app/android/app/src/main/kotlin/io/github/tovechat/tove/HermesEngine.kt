package io.github.tovechat.tove

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * Owns the single Flutter engine for the process.
 *
 * MainActivity attaches to it instead of creating its own, and the engine is
 * kept when the activity goes away during a live call. All methods run on the
 * main thread.
 */
internal object HermesEngine {
    private const val TAG = "HermesEngine"
    private const val ENGINE_ID = "tove_main"

    /** After a call ends with no UI attached, give Dart time to finish its
     *  teardown (close the peer connection, POST /api/stop), then free it. */
    private const val HEADLESS_RELEASE_DELAY_MS = 15_000L

    /** Lets flutter_webrtc's AudioSwitch finish its own deactivate first. */
    private const val AUDIO_MODE_CHECK_DELAY_MS = 1_500L

    private val main = Handler(Looper.getMainLooper())

    private val releaseIfHeadless = Runnable {
        if (!HermesCallService.isActive && CallBridge.currentActivity == null) {
            Log.i(TAG, "Releasing headless engine after the call ended")
            cached()?.destroy()
        }
    }

    fun obtain(context: Context): FlutterEngine {
        main.removeCallbacks(releaseIfHeadless)
        cached()?.let { return it }

        val appContext = context.applicationContext
        // Plugins register automatically. FlutterActivity starts the Dart
        // entrypoint the first time it attaches, so it is not started here.
        val engine = FlutterEngine(appContext)
        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() = Unit

            override fun onEngineWillDestroy() {
                FlutterEngineCache.getInstance().remove(ENGINE_ID)
                CallBridge.detach(engine)
            }
        })
        CallBridge.attach(engine, appContext)
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    fun shouldDestroyWithActivity(): Boolean = !HermesCallService.isActive

    /** Normal end: Dart already tore WebRTC down (or is finishing it). */
    fun onCallFinished() {
        main.removeCallbacks(releaseIfHeadless)
        if (CallBridge.currentActivity == null) {
            main.postDelayed(releaseIfHeadless, HEADLESS_RELEASE_DELAY_MS)
        }
    }

    /**
     * Defensive path when Dart could not be reached (no handler, error,
     * timeout) for a Mute or End the user asked for. Destroying the engine
     * detaches flutter_webrtc, whose onDetachedFromEngine disposes every peer
     * connection and local track (the microphone) and stops its AudioSwitch,
     * which abandons audio focus and restores the audio mode.
     *
     * If an activity is still attached it is finished instead: the call is no
     * longer active, so its onDestroy destroys the engine through
     * [shouldDestroyWithActivity]. Destroying an engine under a live activity
     * would crash the activity.
     */
    fun forceTeardown(context: Context) {
        main.removeCallbacks(releaseIfHeadless)
        val appContext = context.applicationContext
        val activity = CallBridge.currentActivity
        if (activity != null && !activity.isFinishing && !activity.isDestroyed) {
            Log.w(TAG, "Dart unreachable: finishing the activity to release the engine")
            activity.finish()
        } else {
            Log.w(TAG, "Dart unreachable: destroying the headless engine")
            cached()?.destroy()
        }
        main.postDelayed({ resetAudioModeIfIdle(appContext) }, AUDIO_MODE_CHECK_DELAY_MS)
    }

    private fun resetAudioModeIfIdle(context: Context) {
        if (HermesCallService.isActive) return
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        if (audio.mode == AudioManager.MODE_IN_COMMUNICATION) {
            Log.w(TAG, "Audio mode still MODE_IN_COMMUNICATION after teardown; resetting")
            audio.mode = AudioManager.MODE_NORMAL
        }
    }

    private fun cached(): FlutterEngine? = FlutterEngineCache.getInstance().get(ENGINE_ID)
}
