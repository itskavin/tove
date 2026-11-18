package io.github.tovechat.tove

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Hosts the Flutter UI on the process-wide engine from [HermesEngine].
 *
 * The engine outlives this activity while a voice session is live, so Dart
 * (which owns WebRTC) keeps handling notification actions after the screen
 * turns off or the activity is destroyed. Without a live session the engine is
 * destroyed with the activity, exactly like a stock FlutterActivity.
 */
class MainActivity : FlutterActivity() {

    private var device: DeviceChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before super: super.onCreate calls provideFlutterEngine, which binds
        // the call channel, and the channel needs to know this activity exists.
        CallBridge.onActivityCreated(this)
        super.onCreate(savedInstanceState)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        HermesEngine.obtain(context)

    override fun shouldDestroyEngineWithHost(): Boolean =
        HermesEngine.shouldDestroyWithActivity()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        device?.detach()
        device = DeviceChannel(flutterEngine.dartExecutor.binaryMessenger, this)
        if (!flutterEngine.plugins.has(EventsPlugin::class.java)) flutterEngine.plugins.add(EventsPlugin())
        if (!flutterEngine.plugins.has(SpeechChannel::class.java)) flutterEngine.plugins.add(SpeechChannel())
        if (!flutterEngine.plugins.has(LaunchPlugin::class.java)) flutterEngine.plugins.add(LaunchPlugin())
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        device?.detach()
        device = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onStart() {
        super.onStart()
        CallBridge.onActivityStarted(this)
    }

    override fun onStop() {
        CallBridge.onActivityStopped(this)
        super.onStop()
    }

    override fun onDestroy() {
        // Before super: super.onDestroy asks shouldDestroyEngineWithHost and may
        // destroy the engine, and any pending permission request must resolve.
        CallBridge.onActivityDestroyed(this)
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        // Always forward too, so plugins that use the activity callback still work.
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        CallBridge.onRequestPermissionsResult(requestCode)
    }
}
