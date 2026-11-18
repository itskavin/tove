package io.github.tovechat.tove

import android.app.Activity
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.Display
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

/**
 * Small device services for the Flutter UI (channel `io.github.tovechat.tove/device`):
 *
 *  * `info` → `{sdk, refreshRates, hardwareKeyboard}`: lets Dart pick cheaper effects below API 29
 *    and show keyboard shortcuts only with a physical keyboard.
 *  * `setHighRefresh {on}` → refresh status: asks for the display mode with the highest refresh rate
 *    at the current resolution while live mode is open or the thread scrolls (spec §6.10), and gives
 *    the choice back to the system after. The system's own peak-rate setting (Smooth display,
 *    Bedtime and similar modes) and battery saver still cap it; the status reports both.
 *  * `refreshStatus` → `{supportedHz, currentHz, requestedHz, peakSettingHz, powerSave}`.
 *  * `playTone {tones: [[hz, ms]…], gain}`: short generated sine cues on the voice-communication
 *    stream, so they follow the call's audio route. No audio files are shipped.
 *  * `moveTaskToBack` → `true` when the task went to the background: Back at the app's root
 *    minimises it like Home instead of finishing the activity.
 *  * `haptic {kind: light|medium|heavy|selection}` → `true` when it played. Uses the vibrator's
 *    primitives (API 30+) or predefined effects (API 29+) with touch usage, so it follows the touch
 *    intensity setting but never depends on the view's haptic flag or on an OEM mapping the legacy
 *    `HapticFeedbackConstants` to nothing; older devices use the view's feedback.
 *  * `setRefreshRate {hz}` → refresh status: asks for the mode at the current resolution whose
 *    rate is closest to `hz` (0 gives the choice back to the system). Dart's `RefreshPolicy` picks
 *    `hz` from the Display setting and what the UI is doing.
 *  * `emailApp {package?}` → `true` when an email app (that package, when given: Gmail is
 *    `com.google.android.gm`) can take a draft; `composeEmail {package?, to, subject, body}` →
 *    `true` when its compose screen opened (`ACTION_SENDTO mailto:` with the extras; round 8).
 *  * `share {text, subject?}` → `true` when the system share sheet opened: plain text only
 *    (`ACTION_SEND` in a chooser), no permissions, nothing leaves the device unless the user picks a
 *    target.
 *
 * Bound per activity; the engine can outlive it during a call, so the activity is held weakly.
 */
internal class DeviceChannel(messenger: BinaryMessenger, activity: Activity) {
    private val channel = MethodChannel(messenger, NAME)
    private val activity = WeakReference(activity)
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(info())
                "setHighRefresh" -> {
                    setHighRefresh(call.argument<Boolean>("on") == true)
                    result.success(refreshStatus())
                }
                "refreshStatus" -> result.success(refreshStatus())
                "playTone" -> {
                    @Suppress("UNCHECKED_CAST")
                    val tones = (call.argument<List<List<Number>>>("tones") ?: emptyList())
                    val gain = call.argument<Double>("gain") ?: 0.125
                    playTone(tones.map { it[0].toDouble() to it[1].toInt() }, gain)
                    result.success(null)
                }
                "share" -> result.success(share(call.argument<String>("text") ?: "", call.argument<String>("subject")))
                "emailApp" -> result.success(emailApp(call.argument<String>("package")))
                "composeEmail" -> result.success(
                    composeEmail(
                        call.argument<String>("package"),
                        call.argument<List<String>>("to") ?: emptyList(),
                        call.argument<String>("subject") ?: "",
                        call.argument<String>("body") ?: "",
                    ),
                )
                "moveTaskToBack" -> result.success(this.activity.get()?.moveTaskToBack(true) == true)
                "haptic" -> result.success(haptic(call.argument<String>("kind") ?: "light"))
                "setRefreshRate" -> {
                    setRefreshRate(call.argument<Double>("hz") ?: 0.0)
                    result.success(refreshStatus())
                }
                else -> result.notImplemented()
            }
        }
    }

    fun detach() = channel.setMethodCallHandler(null)

    private fun share(text: String, subject: String?): Boolean {
        val a = activity.get() ?: return false
        if (text.isEmpty()) return false
        return try {
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
                if (!subject.isNullOrBlank()) putExtra(Intent.EXTRA_SUBJECT, subject)
            }
            a.startActivity(Intent.createChooser(send, null))
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun emailIntent(pkg: String?, to: List<String>, subject: String, body: String): Intent =
        Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:")).apply {
            if (to.isNotEmpty()) putExtra(Intent.EXTRA_EMAIL, to.toTypedArray())
            if (subject.isNotEmpty()) putExtra(Intent.EXTRA_SUBJECT, subject)
            if (body.isNotEmpty()) putExtra(Intent.EXTRA_TEXT, body)
            if (pkg != null) setPackage(pkg)
        }

    /** Whether an email app (the one in [pkg], when given) can take a draft. */
    private fun emailApp(pkg: String?): Boolean {
        val a = activity.get() ?: return false
        return try {
            emailIntent(pkg, emptyList(), "", "").resolveActivity(a.packageManager) != null
        } catch (_: Exception) {
            false
        }
    }

    private fun composeEmail(pkg: String?, to: List<String>, subject: String, body: String): Boolean {
        val a = activity.get() ?: return false
        return try {
            a.startActivity(emailIntent(pkg, to, subject, body))
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun info(): Map<String, Any> {
        val rates = activity.get()?.let { a ->
            @Suppress("DEPRECATION")
            val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) a.display else a.windowManager.defaultDisplay
            display?.supportedModes?.map { it.refreshRate.toDouble() }?.distinct()
        } ?: emptyList()
        val config = activity.get()?.resources?.configuration
        // A physical keyboard that is attached and not hidden (lid, folio).
        val hardKeyboard = config != null &&
            config.keyboard != android.content.res.Configuration.KEYBOARD_NOKEYS &&
            config.hardKeyboardHidden == android.content.res.Configuration.HARDKEYBOARDHIDDEN_NO
        return mapOf("sdk" to Build.VERSION.SDK_INT, "refreshRates" to rates, "hardwareKeyboard" to hardKeyboard)
    }

    private fun display(a: Activity): Display? {
        @Suppress("DEPRECATION")
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) a.display else a.windowManager.defaultDisplay
    }

    private fun setHighRefresh(on: Boolean) {
        val a = activity.get() ?: return
        val display = display(a) ?: return
        val params = a.window.attributes
        if (!on) {
            params.preferredDisplayModeId = 0
            params.preferredRefreshRate = 0f
        } else {
            val current = display.mode
            val best = display.supportedModes
                .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
                .maxByOrNull { it.refreshRate } ?: return
            // Both: some OEM policies honour only one of them.
            params.preferredDisplayModeId = best.modeId
            params.preferredRefreshRate = best.refreshRate
        }
        a.window.attributes = params
    }

    private fun setRefreshRate(hz: Double) {
        val a = activity.get() ?: return
        val display = display(a) ?: return
        val params = a.window.attributes
        if (hz <= 0) {
            if (params.preferredDisplayModeId == 0 && params.preferredRefreshRate == 0f) return
            params.preferredDisplayModeId = 0
            params.preferredRefreshRate = 0f
        } else {
            val current = display.mode
            val best = display.supportedModes
                .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
                .minByOrNull { kotlin.math.abs(it.refreshRate - hz) } ?: return
            if (params.preferredDisplayModeId == best.modeId) return
            params.preferredDisplayModeId = best.modeId
            params.preferredRefreshRate = best.refreshRate
        }
        a.window.attributes = params
    }

    private fun vibrator(a: Activity): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            a.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            a.getSystemService(Vibrator::class.java)
        }

    private fun haptic(kind: String): Boolean {
        val a = activity.get() ?: return false
        val v = vibrator(a)
        if (v != null && v.hasVibrator() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val effect = hapticEffect(v, kind)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                v.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(
                    effect,
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION).build(),
                )
            }
            return true
        }
        val constant = when (kind) {
            "heavy" -> HapticFeedbackConstants.LONG_PRESS
            "selection" -> HapticFeedbackConstants.CLOCK_TICK
            else -> HapticFeedbackConstants.VIRTUAL_KEY
        }
        @Suppress("DEPRECATION")
        return a.window.decorView.performHapticFeedback(
            constant,
            HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING,
        )
    }

    private fun hapticEffect(v: Vibrator, kind: String): VibrationEffect {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val (primitive, scale) = when (kind) {
                "selection" -> VibrationEffect.Composition.PRIMITIVE_TICK to 0.6f
                "medium" -> VibrationEffect.Composition.PRIMITIVE_CLICK to 0.8f
                "heavy" -> VibrationEffect.Composition.PRIMITIVE_CLICK to 1f
                else -> VibrationEffect.Composition.PRIMITIVE_CLICK to 0.5f
            }
            if (v.areAllPrimitivesSupported(primitive)) {
                return VibrationEffect.startComposition().addPrimitive(primitive, scale).compose()
            }
        }
        return VibrationEffect.createPredefined(
            when (kind) {
                "selection" -> VibrationEffect.EFFECT_TICK
                "heavy" -> VibrationEffect.EFFECT_HEAVY_CLICK
                else -> VibrationEffect.EFFECT_CLICK
            },
        )
    }

    private fun refreshStatus(): Map<String, Any?> {
        val a = activity.get() ?: return emptyMap()
        val display = display(a)
        val params = a.window.attributes
        val requested = display?.supportedModes?.firstOrNull { it.modeId == params.preferredDisplayModeId }
        // Readable system setting; null when an OEM hides it.
        val peak = runCatching {
            Settings.System.getFloat(a.contentResolver, "peak_refresh_rate")
        }.getOrNull()
        val power = a.getSystemService(PowerManager::class.java)
        return mapOf(
            "supportedHz" to (display?.supportedModes?.map { it.refreshRate.toDouble() }?.distinct() ?: emptyList()),
            "currentHz" to display?.refreshRate?.toDouble(),
            "requestedHz" to requested?.refreshRate?.toDouble(),
            "peakSettingHz" to peak?.toDouble(),
            "powerSave" to (power?.isPowerSaveMode == true),
        )
    }

    private fun playTone(tones: List<Pair<Double, Int>>, gain: Double) {
        if (tones.isEmpty()) return
        Thread {
            try {
                val rate = 24_000
                val total = tones.sumOf { it.second } * rate / 1000
                val pcm = ShortArray(total)
                var offset = 0
                for ((hz, ms) in tones) {
                    val n = ms * rate / 1000
                    val ramp = min(n / 4, rate / 125) // ≤ 8 ms fade in and out, no clicks
                    for (i in 0 until n) {
                        val env = when {
                            i < ramp -> i.toDouble() / ramp
                            i > n - ramp -> (n - i).toDouble() / ramp
                            else -> 1.0
                        }
                        val v = sin(2 * PI * hz * i / rate) * gain * env
                        if (offset + i < total) pcm[offset + i] = (v * Short.MAX_VALUE).toInt().toShort()
                    }
                    offset += n
                }
                val track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build(),
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(rate)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build(),
                    )
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .setBufferSizeInBytes(pcm.size * 2)
                    .build()
                track.write(pcm, 0, pcm.size)
                track.play()
                val durationMs = total * 1000L / rate
                main.postDelayed({ runCatching { track.release() } }, durationMs + 200)
            } catch (_: Throwable) {
                // Cues are optional.
            }
        }.start()
    }

    companion object {
        const val NAME = "io.github.tovechat.tove/device"
    }
}
