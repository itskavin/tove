package io.github.tovechat.tove

import android.app.Activity
import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Channel `tove/launch` between Dart's `AppLinks` and the ways into the app from outside it: the
 * home-screen widgets ([ToveWidgets]) and the assistant gesture ([AssistActivity]).
 *
 * Both open [MainActivity] with an explicit intent, action [ACTION_OPEN] and a `tove://` link as its
 * data: `tove://chat/new` (optionally `?keyboard=1`), `tove://live`, `tove://chat/<id>`. A pairing
 * link (`tove://pair?u=...&c=...`, from the QR code the tove-setup Hermes skill shows) arrives as a
 * VIEW intent through the manifest's BROWSABLE filter. Dart parses the link; this side only checks
 * the action, scheme and (for VIEW) host. Flutter's own deep linking is off in the
 * manifest, so the link never becomes a route.
 *
 * Dart → native: `initialLink` → String? (the link that started the activity, once),
 * `setRecentChat {id?, title?}` (the quick widget's last chat; null clears it), `assistantStatus` →
 * `{supported, held}` (`held` null when unknown) and `openAssistantSettings` → bool.
 * Native → Dart: `link` (a link that reached the running activity).
 */
class LaunchPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, PluginRegistry.NewIntentListener {

    companion object {
        const val CHANNEL = "tove/launch"
        const val ACTION_OPEN = "io.github.tovechat.tove.action.OPEN"
        const val LINK_NEW_CHAT = "tove://chat/new"
        const val LINK_NEW_CHAT_KEYBOARD = "tove://chat/new?keyboard=1"
        const val LINK_LIVE = "tove://live"

        fun chatLink(id: String): String =
            Uri.Builder().scheme("tove").authority("chat").appendPath(id).build().toString()

        /** An explicit intent that opens [link] in the app's task (reused when it exists). */
        fun openIntent(context: Context, link: String): Intent =
            Intent(context, MainActivity::class.java)
                .setAction(ACTION_OPEN)
                .setData(Uri.parse(link))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

        /**
         * The link [intent] carries, or null. A relaunch from Recents repeats the old intent: ignored.
         * Our own explicit intents ([ACTION_OPEN]) may carry any `tove://` link. A VIEW intent from
         * outside (a scanned QR code, a tapped link) may only carry a pairing link, `tove://pair?...`,
         * which Dart asks the user about before it changes anything; other apps and web pages cannot
         * start a live call or open a chat this way.
         */
        fun linkOf(intent: Intent?): String? {
            if (intent == null) return null
            if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
            val data = intent.data ?: return null
            if (data.scheme != "tove") return null
            return when (intent.action) {
                ACTION_OPEN -> data.toString()
                Intent.ACTION_VIEW -> if (data.host == "pair") data.toString() else null
                else -> null
            }
        }
    }

    private var channel: MethodChannel? = null
    private var appContext: Context? = null
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var initialLink: String? = null

    // Dart asks for the initial link once per engine. The engine can outlive the activity (a live
    // call), so a later activity's link goes out as `link` instead.
    private var initialAsked = false

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        appContext = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext ?: return result.error("detached", null, null)
        when (call.method) {
            "initialLink" -> {
                initialAsked = true
                result.success(initialLink)
                initialLink = null
            }
            "setRecentChat" -> {
                ToveWidgets.setRecentChat(context, call.argument<String>("id"), call.argument<String>("title"))
                result.success(null)
            }
            "assistantStatus" -> result.success(assistantStatus(context))
            "openAssistantSettings" -> result.success(openAssistantSettings(context))
            else -> result.notImplemented()
        }
    }

    /**
     * Whether Tove holds the digital-assistant role. The role is not requestable by apps
     * (`requestable="false"` in the platform's roles.xml), so the user picks it in Settings.
     */
    private fun assistantStatus(c: Context): Map<String, Any?> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val roles = c.getSystemService(RoleManager::class.java)
            val available = roles?.isRoleAvailable(RoleManager.ROLE_ASSISTANT) == true
            return mapOf("supported" to available, "held" to (available && roles!!.isRoleHeld(RoleManager.ROLE_ASSISTANT)))
        }
        // Before Android 10 the choice is a secure setting holding the assistant's component.
        val held = try {
            Settings.Secure.getString(c.contentResolver, "assistant")?.startsWith(c.packageName + "/")
        } catch (_: Exception) {
            null
        }
        return mapOf("supported" to true, "held" to held)
    }

    /** "Digital assistant app" settings where the device has them, else Default apps, else Settings. */
    private fun openAssistantSettings(c: Context): Boolean {
        val tries = listOf(
            Intent(Settings.ACTION_VOICE_INPUT_SETTINGS),
            Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        val a = activity
        for (intent in tries) {
            try {
                if (a != null) a.startActivity(intent) else c.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: Exception) {
                // Not on this device: try the next.
            }
        }
        return false
    }

    override fun onNewIntent(intent: Intent): Boolean {
        val link = linkOf(intent) ?: return false
        channel?.invokeMethod("link", link)
        return true
    }

    private fun attach(b: ActivityPluginBinding) {
        detach()
        binding = b
        activity = b.activity
        b.addOnNewIntentListener(this)
        linkOf(b.activity.intent)?.let {
            if (initialAsked) channel?.invokeMethod("link", it) else initialLink = it
            // Read once, also across configuration changes.
            b.activity.intent.action = Intent.ACTION_MAIN
            b.activity.intent.data = null
        }
    }

    private fun detach() {
        binding?.removeOnNewIntentListener(this)
        binding = null
        activity = null
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) = attach(b)
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = attach(b)
    override fun onDetachedFromActivityForConfigChanges() = detach()
    override fun onDetachedFromActivity() = detach()
}

/**
 * The assistant entry point. Holding the digital-assistant role needs an exported activity for
 * `android.intent.action.ASSIST` (or a full VoiceInteractionService, which Tove does not need). The
 * long-press of Home or the power key starts this; it hands over to [MainActivity] in the app's own
 * task with [LaunchPlugin.LINK_LIVE] and finishes at once, so it never shows or stays in Recents.
 */
class AssistActivity : Activity() {
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            startActivity(LaunchPlugin.openIntent(this, LaunchPlugin.LINK_LIVE))
        } catch (_: Exception) {
            // Nothing else to do: the activity closes either way.
        }
        finish()
    }
}
