package io.github.tovechat.tove

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Speech services for `lib/src/speech/speech_platform.dart`.
 *
 * Methods (`io.github.tovechat.tove/speech`):
 *  * Recogniser: `sttAvailability`, `sttStart {language, preferOnDevice, allowNetwork}` →
 *    `{onDevice}`, `sttStop`, `sttCancel`, `sttLanguages {language}` (API 33+),
 *    `sttDownloadLanguage {language}` (API 33+). With `preferOnDevice` (API 31+) the on-device
 *    recogniser (`createOnDeviceSpeechRecognizer`) is used; otherwise the default one, which "is
 *    likely to stream audio to remote servers" and is much better with accents. Only the
 *    on-device path asks for offline models (`EXTRA_PREFER_OFFLINE`).
 *  * Permission: `micPermission`, `requestMicPermission` → granted|denied|permanentlyDenied.
 *    RECORD_AUDIO is already declared for live voice.
 *  * Microphone: `micStart {sampleRate}`, `micStop` (16-bit mono chunks for offline dictation).
 *  * PCM player: `pcmOpen {sampleRate}`, `pcmWrite {id, pcm}`, `pcmPause`, `pcmResume`,
 *    `pcmStop`. A `{type: pcm, event: done, id}` event follows once each write has been heard.
 *  * Focus: `requestFocus {mayDuck}` → granted, `abandonFocus`.
 *  * `networkInfo` → `{connected, unmetered, wifi}`, `freeBytes {path}`.
 *
 * Events (`io.github.tovechat.tove/speech_events`): maps with `type` stt|mic|pcm|focus|noisy.
 *
 * A [FlutterPlugin] so the engine's activity binding delivers permission results; added from
 * MainActivity.configureFlutterEngine. The engine can outlive an activity during a call;
 * [ActivityAware] tracks the current one.
 */
class SpeechChannel :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    PluginRegistry.RequestPermissionsResultListener {

    private var context: Context? = null
    private var methods: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var binding: ActivityPluginBinding? = null
    private val main = Handler(Looper.getMainLooper())

    // ---- FlutterPlugin / ActivityAware ---------------------------------------------------------

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        methods = MethodChannel(b.binaryMessenger, METHODS).also { it.setMethodCallHandler(this) }
        eventChannel = EventChannel(b.binaryMessenger, EVENTS).also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        destroyRecognizer()
        downloader?.destroy()
        downloader = null
        stopMic()
        pcmStop()
        abandonFocus()
        methods?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methods = null
        eventChannel = null
        sink = null
        context = null
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        binding = b
        b.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)

    override fun onDetachedFromActivity() {
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
        pendingPermission?.success(permissionState())
        pendingPermission = null
    }

    private val activity: Activity? get() = binding?.activity

    // ---- Events --------------------------------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            sink?.success(event)
        } else {
            main.post { sink?.success(event) }
        }
    }

    // ---- Methods -------------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.error("no_context", "Not attached.", null)
        try {
            when (call.method) {
                "sttAvailability" -> result.success(availability(ctx))
                "sttStart" -> sttStart(
                    ctx,
                    call.argument<String>("language"),
                    call.argument<Boolean>("preferOnDevice") != false,
                    call.argument<Boolean>("allowNetwork") != false,
                    result,
                )
                "sttStop" -> {
                    recognizer?.stopListening()
                    result.success(null)
                }
                "sttCancel" -> {
                    destroyRecognizer()
                    result.success(null)
                }
                "sttLanguages" -> sttLanguages(ctx, call.argument<String>("language"), result)
                "sttDownloadLanguage" -> result.success(sttDownload(ctx, call.argument<String>("language")))
                "micPermission" -> result.success(permissionState())
                "requestMicPermission" -> requestPermission(result)
                "micStart" -> micStart(ctx, call.argument<Int>("sampleRate") ?: 16000, result)
                "micStop" -> {
                    stopMic()
                    result.success(null)
                }
                "pcmOpen" -> {
                    pcmOpen(call.argument<Int>("sampleRate") ?: 24000)
                    result.success(null)
                }
                "pcmWrite" -> {
                    val id = call.argument<Int>("id") ?: 0
                    val pcm = call.argument<ByteArray>("pcm") ?: ByteArray(0)
                    pcmWrite(id, pcm)
                    result.success(null)
                }
                "pcmPause" -> {
                    synchronized(trackLock) { runCatching { track?.pause() } }
                    result.success(null)
                }
                "pcmResume" -> {
                    synchronized(trackLock) { runCatching { track?.play() } }
                    result.success(null)
                }
                "pcmStop" -> {
                    pcmStop()
                    result.success(null)
                }
                "requestFocus" -> result.success(requestFocus(ctx, call.argument<Boolean>("mayDuck") == true))
                "abandonFocus" -> {
                    abandonFocus()
                    result.success(null)
                }
                "networkInfo" -> result.success(networkInfo(ctx))
                "freeBytes" -> {
                    val path = call.argument<String>("path") ?: ctx.filesDir.path
                    result.success(runCatching { StatFs(path).availableBytes }.getOrNull())
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.w(TAG, "${call.method} failed", e)
            result.error("failed", e.message, null)
        }
    }

    // ---- Recogniser ----------------------------------------------------------------------------

    private var recognizer: SpeechRecognizer? = null
    private var downloader: SpeechRecognizer? = null
    private var lastRms = 0L

    private fun onDeviceAvailable(ctx: Context): Boolean =
        Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)

    private fun availability(ctx: Context): Map<String, Any> = mapOf(
        "sdk" to Build.VERSION.SDK_INT,
        "available" to SpeechRecognizer.isRecognitionAvailable(ctx),
        "onDevice" to onDeviceAvailable(ctx),
    )

    private fun recognizerIntent(ctx: Context, language: String?, offline: Boolean = true): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, ctx.packageName)
            // Forcing offline on the default recogniser swapped Google's server model for the small
            // on-device one (and en-US when the en-IN pack was missing): the main accuracy loss.
            if (offline) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            if (!language.isNullOrBlank()) {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, language)
            }
            // People pause mid-sentence; the default end-of-speech (about 1 s) cut them off. Some
            // recognisers ignore these hints; Dart restarts them in hold-to-talk mode anyway.
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 2000L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1500L)
            if (Build.VERSION.SDK_INT >= 33) {
                // Punctuation and capitals, and the user's own words unmasked.
                putExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING, RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY)
                putExtra(RecognizerIntent.EXTRA_MASK_OFFENSIVE_WORDS, false)
            }
        }

    private fun sttStart(
        ctx: Context,
        language: String?,
        preferOnDevice: Boolean,
        allowNetwork: Boolean,
        result: MethodChannel.Result,
    ) {
        if (!granted(ctx)) return result.error("permission", "Microphone permission is off.", null)
        destroyRecognizer()
        var onDevice = false
        var sr: SpeechRecognizer? = null
        if (preferOnDevice && Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)) {
            sr = runCatching { SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx) }.getOrNull()
            onDevice = sr != null
        }
        if (sr == null) {
            if (!allowNetwork) {
                return result.error("onDeviceUnavailable", "On-device recognition is not available.", null)
            }
            if (!SpeechRecognizer.isRecognitionAvailable(ctx)) {
                return result.error("unavailable", "No speech recogniser.", null)
            }
            sr = SpeechRecognizer.createSpeechRecognizer(ctx)
        }
        val created = sr ?: return result.error("unavailable", "No speech recogniser.", null)
        created.setRecognitionListener(listenerFor(created))
        recognizer = created
        created.startListening(recognizerIntent(ctx, language, offline = onDevice))
        result.success(mapOf("onDevice" to onDevice))
    }

    private fun listenerFor(sr: SpeechRecognizer) = object : RecognitionListener {
        private fun current() = recognizer === sr

        override fun onReadyForSpeech(params: Bundle?) {
            if (current()) emit(mapOf("type" to "stt", "event" to "ready"))
        }

        override fun onBeginningOfSpeech() {
            if (current()) emit(mapOf("type" to "stt", "event" to "begin"))
        }

        override fun onRmsChanged(rmsdB: Float) {
            val now = SystemClock.uptimeMillis()
            if (!current() || now - lastRms < 50) return
            lastRms = now
            emit(mapOf("type" to "stt", "event" to "rms", "rms" to rmsdB.toDouble()))
        }

        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onEndOfSpeech() {
            if (current()) emit(mapOf("type" to "stt", "event" to "end"))
        }

        override fun onError(error: Int) {
            if (!current()) return
            emit(mapOf("type" to "stt", "event" to "error", "code" to error))
            main.post { if (recognizer === sr) destroyRecognizer() }
        }

        override fun onResults(results: Bundle?) {
            if (!current()) return
            emit(mapOf("type" to "stt", "event" to "final", "text" to firstResult(results)))
            main.post { if (recognizer === sr) destroyRecognizer() }
        }

        override fun onPartialResults(partialResults: Bundle?) {
            if (current()) emit(mapOf("type" to "stt", "event" to "partial", "text" to firstResult(partialResults)))
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun firstResult(b: Bundle?): String =
        b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""

    private fun destroyRecognizer() {
        val sr = recognizer ?: return
        recognizer = null
        runCatching { sr.cancel() }
        runCatching { sr.destroy() }
    }

    private fun sttLanguages(ctx: Context, language: String?, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) return result.success(null)
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)) return result.success(null)
        val sr = runCatching { SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx) }.getOrNull()
            ?: return result.success(null)
        var answered = false
        fun finish(value: Any?) {
            if (answered) return
            answered = true
            result.success(value)
            main.post { runCatching { sr.destroy() } }
        }
        sr.checkRecognitionSupport(
            recognizerIntent(ctx, language),
            ctx.mainExecutor,
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) = finish(
                    mapOf(
                        "installed" to support.installedOnDeviceLanguages,
                        "pending" to support.pendingOnDeviceLanguages,
                        "supported" to support.supportedOnDeviceLanguages,
                        "online" to support.onlineLanguages,
                    ),
                )

                override fun onError(error: Int) = finish(null)
            },
        )
        // Some recognition services never answer.
        main.postDelayed({ finish(null) }, 4000)
    }

    private fun sttDownload(ctx: Context, language: String?): Boolean {
        if (Build.VERSION.SDK_INT < 33 || language.isNullOrBlank()) return false
        if (!SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)) return false
        downloader?.destroy()
        val sr = runCatching { SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx) }.getOrNull() ?: return false
        downloader = sr
        return runCatching { sr.triggerModelDownload(recognizerIntent(ctx, language)); true }.getOrDefault(false)
    }

    // ---- Permission ----------------------------------------------------------------------------

    private var pendingPermission: MethodChannel.Result? = null

    private fun granted(ctx: Context) =
        ctx.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun permissionState(): String {
        val ctx = context ?: return "denied"
        if (granted(ctx)) return "granted"
        val asked = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ASKED, false)
        val a = activity
        // After a denial, no rationale means "don't ask again" (or a policy block).
        if (asked && a != null && !a.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) {
            return "permanentlyDenied"
        }
        return "denied"
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val ctx = context ?: return result.success("denied")
        if (granted(ctx)) return result.success("granted")
        val a = activity ?: return result.success(permissionState())
        if (pendingPermission != null) return result.error("busy", "A permission prompt is already open.", null)
        if (permissionState() == "permanentlyDenied") return result.success("permanentlyDenied")
        pendingPermission = result
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ASKED, true).apply()
        a.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MIC)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_MIC) return false
        val pending = pendingPermission ?: return true
        pendingPermission = null
        // Re-read the real state; the arrays are empty when the prompt is interrupted.
        pending.success(permissionState())
        return true
    }

    // ---- Microphone (offline dictation) --------------------------------------------------------

    @Volatile private var recording = false
    private var recorder: AudioRecord? = null
    private var micThread: Thread? = null

    @SuppressLint("MissingPermission") // Checked just before.
    private fun micStart(ctx: Context, rate: Int, result: MethodChannel.Result) {
        if (!granted(ctx)) return result.error("permission", "Microphone permission is off.", null)
        stopMic()
        val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return result.error("unavailable", "The microphone format is not supported.", null)
        val chunkBytes = rate / 10 * 2 // 100 ms
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            maxOf(min, chunkBytes * 4),
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return result.error("unavailable", "The microphone could not be opened.", null)
        }
        recorder = rec
        recording = true
        rec.startRecording()
        micThread = Thread({
            val buf = ByteArray(chunkBytes)
            while (recording) {
                val n = rec.read(buf, 0, buf.size)
                if (n > 0) {
                    emit(mapOf("type" to "mic", "pcm" to buf.copyOf(n)))
                } else if (n < 0) {
                    emit(mapOf("type" to "mic", "error" to "read failed ($n)"))
                    break
                }
            }
        }, "speech-mic").also { it.start() }
        result.success(null)
    }

    private fun stopMic() {
        recording = false
        val rec = recorder ?: return
        recorder = null
        runCatching { rec.stop() }
        runCatching { micThread?.join(300) }
        micThread = null
        runCatching { rec.release() }
    }

    // ---- PCM player (Kokoro) -------------------------------------------------------------------

    private class Chunk(val id: Int, val pcm: ByteArray, val gen: Int)

    private val trackLock = Any()
    private var track: AudioTrack? = null
    private var trackRate = 0
    private var trackFrames = 0
    private val queue = LinkedBlockingQueue<Chunk>()
    private val marks = ConcurrentLinkedQueue<Pair<Int, Long>>()
    private val generation = AtomicInteger(0)
    @Volatile private var writtenFrames = 0L
    private var writer: Thread? = null
    @Volatile private var volume = 1f

    private fun pcmOpen(rate: Int) {
        synchronized(trackLock) {
            if (track != null && trackRate == rate) return
        }
        pcmStop()
        val min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val bytes = maxOf(min * 2, rate / 5 * 2) // at least 200 ms
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(bytes)
            .build()
        if (Build.VERSION.SDK_INT >= 31) {
            // Start (and restart after an underrun) as soon as 20 ms is queued, so a short
            // sentence never waits for the buffer to fill.
            runCatching { t.setStartThresholdInFrames(rate / 50) }
        }
        t.setVolume(volume)
        t.play()
        val gen = generation.get()
        synchronized(trackLock) {
            track = t
            trackRate = rate
            trackFrames = bytes / 2
            writtenFrames = 0
        }
        writer = Thread({ writeLoop(gen) }, "speech-pcm").also { it.start() }
        main.post(poller)
    }

    private fun pcmWrite(id: Int, pcm: ByteArray) {
        queue.add(Chunk(id, pcm, generation.get()))
    }

    private fun writeLoop(gen: Int) {
        var idleSince = 0L
        var padded = true
        while (generation.get() == gen) {
            val c = queue.poll(40, TimeUnit.MILLISECONDS)
            if (c == null) {
                // Below API 31 a stream track that ran dry restarts only when its buffer
                // fills, so pad with silence when nothing more is coming soon.
                if (Build.VERSION.SDK_INT < 31 && !padded) {
                    if (idleSince == 0L) idleSince = SystemClock.uptimeMillis()
                    if (SystemClock.uptimeMillis() - idleSince > 120) {
                        val frames = synchronized(trackLock) { trackFrames }
                        if (!write(gen, ByteArray(frames * 2))) return
                        padded = true
                    }
                }
                continue
            }
            if (c.gen != gen) continue
            idleSince = 0L
            padded = false
            if (!write(gen, c.pcm)) return
            marks.add(c.id to writtenFrames)
        }
    }

    /** Non-blocking writes, so pause and stop never wait on a full buffer. */
    private fun write(gen: Int, pcm: ByteArray): Boolean {
        var off = 0
        while (off < pcm.size) {
            if (generation.get() != gen) return false
            val n = synchronized(trackLock) {
                val t = track ?: return false
                t.write(pcm, off, pcm.size - off, AudioTrack.WRITE_NON_BLOCKING)
            }
            when {
                n < 0 -> {
                    emit(mapOf("type" to "pcm", "event" to "error", "message" to "Audio output failed ($n)."))
                    return false
                }
                n == 0 -> SystemClock.sleep(10)
                else -> off += n
            }
        }
        writtenFrames += pcm.size / 2
        return true
    }

    private val poller = object : Runnable {
        override fun run() {
            val head = synchronized(trackLock) {
                val t = track ?: return
                t.playbackHeadPosition.toLong() and 0xffffffffL
            }
            while (true) {
                val m = marks.peek() ?: break
                if (m.second > head) break
                marks.poll()
                emit(mapOf("type" to "pcm", "event" to "done", "id" to m.first))
            }
            main.postDelayed(this, 40)
        }
    }

    private fun pcmStop() {
        generation.incrementAndGet()
        queue.clear()
        marks.clear()
        main.removeCallbacks(poller)
        synchronized(trackLock) {
            track?.let { t ->
                runCatching { t.pause() }
                runCatching { t.flush() }
                runCatching { t.release() }
            }
            track = null
            trackRate = 0
            writtenFrames = 0
        }
        runCatching { writer?.join(200) }
        writer = null
    }

    // ---- Audio focus ---------------------------------------------------------------------------

    private var focusRequest: AudioFocusRequest? = null
    private var focusHeld = false
    private var noisyRegistered = false

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                setVolume(1f)
                emit(mapOf("type" to "focus", "change" to "gain"))
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                focusHeld = false
                emit(mapOf("type" to "focus", "change" to "loss"))
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ->
                emit(mapOf("type" to "focus", "change" to "lossTransient"))
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                setVolume(0.25f)
                emit(mapOf("type" to "focus", "change" to "duck"))
            }
        }
    }

    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                emit(mapOf("type" to "noisy"))
            }
        }
    }

    private fun setVolume(v: Float) {
        volume = v
        synchronized(trackLock) { runCatching { track?.setVolume(v) } }
    }

    private fun requestFocus(ctx: Context, mayDuck: Boolean): Boolean {
        val am = ctx.getSystemService(AudioManager::class.java) ?: return true
        // Never talk over a phone call (ringing or in progress).
        if (am.mode == AudioManager.MODE_IN_CALL || am.mode == AudioManager.MODE_RINGTONE) return false
        val gain = if (mayDuck) AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK else AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
        val granted = if (Build.VERSION.SDK_INT >= 26) {
            val req = AudioFocusRequest.Builder(gain)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusListener, main)
                .setWillPauseWhenDucked(false)
                .build()
            focusRequest = req
            am.requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, gain) ==
                AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
        focusHeld = granted
        if (granted && !noisyRegistered) {
            val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            if (Build.VERSION.SDK_INT >= 33) {
                ctx.registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                ctx.registerReceiver(noisyReceiver, filter)
            }
            noisyRegistered = true
        }
        setVolume(1f)
        return granted
    }

    private fun abandonFocus() {
        val ctx = context ?: return
        val am = ctx.getSystemService(AudioManager::class.java)
        if (am != null) {
            if (Build.VERSION.SDK_INT >= 26) {
                focusRequest?.let { am.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(focusListener)
            }
        }
        focusRequest = null
        focusHeld = false
        if (noisyRegistered) {
            runCatching { ctx.unregisterReceiver(noisyReceiver) }
            noisyRegistered = false
        }
    }

    // ---- Environment ---------------------------------------------------------------------------

    private fun networkInfo(ctx: Context): Map<String, Boolean> {
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
            ?: return mapOf("connected" to true, "unmetered" to false, "wifi" to false)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
            ?: return mapOf("connected" to false, "unmetered" to false, "wifi" to false)
        return mapOf(
            "connected" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
            "unmetered" to (
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ||
                    !cm.isActiveNetworkMetered
                ),
            "wifi" to (
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                ),
        )
    }

    companion object {
        const val METHODS = "io.github.tovechat.tove/speech"
        const val EVENTS = "io.github.tovechat.tove/speech_events"
        private const val TAG = "HermesSpeech"
        private const val REQUEST_MIC = 0x5350
        private const val PREFS = "speech_channel"
        private const val KEY_ASKED = "mic_asked"
    }
}
