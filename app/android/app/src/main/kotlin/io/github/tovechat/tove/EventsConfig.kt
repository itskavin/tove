package io.github.tovechat.tove

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * What [EventsService] needs, set from Dart by [EventsPlugin.configure], plus its status for the settings page.
 * Plain SharedPreferences ("tove_events"); the bridge key is AES-GCM encrypted with a key that never leaves the
 * Android Keystore ([KeyBox]), so a copied prefs file (or a backup restored elsewhere) does not reveal it.
 */
class EventsConfig(
    val base: String,
    val key: String,
    val deviceId: String?,
    val heartbeat: Int,
    val systemEnabled: Boolean,
    val assistantName: String,
    val appName: String,
) {
    companion object {
        private const val PREFS = "tove_events"
        private const val RECENT_MAX = 200

        private fun prefs(c: Context): SharedPreferences = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun save(c: Context, enabled: Boolean, base: String, key: String, deviceId: String?, heartbeat: Int,
                 systemEnabled: Boolean, assistantName: String, appName: String) {
            val p = prefs(c).edit()
            val sealed = if (enabled) KeyBox.seal(key) else null
            p.putBoolean("enabled", enabled && sealed != null)
                .putString("base", base)
                .putString("device_id", deviceId)
                .putInt("heartbeat", heartbeat.coerceIn(15, 600))
                .putBoolean("system_enabled", systemEnabled)
                .putString("assistant_name", assistantName)
                .putString("app_name", appName)
            if (sealed != null) p.putString("key", sealed) else p.remove("key")
            if (prefs(c).getString("base", null) != base) p.putLong("last_id", 0)     // another bridge: new ids
            p.apply()
        }

        /** Null when turned off, or when the key cannot be decrypted. */
        fun load(c: Context): EventsConfig? {
            val p = prefs(c)
            if (!p.getBoolean("enabled", false)) return null
            val base = p.getString("base", null) ?: return null
            val key = KeyBox.open(p.getString("key", null) ?: return null) ?: return null
            return EventsConfig(base, key, p.getString("device_id", null), p.getInt("heartbeat", 80),
                p.getBoolean("system_enabled", true), p.getString("assistant_name", null) ?: "Hermes",
                p.getString("app_name", null) ?: "Tove")
        }

        fun enabled(c: Context) = prefs(c).getBoolean("enabled", false)
        fun appName(c: Context) = prefs(c).getString("app_name", null) ?: "Tove"

        fun lastId(c: Context) = prefs(c).getLong("last_id", 0)
        fun setLastId(c: Context, id: Long) {
            if (id > lastId(c)) prefs(c).edit().putLong("last_id", id).apply()
        }

        fun status(c: Context): String = prefs(c).getString("status", "off") ?: "off"
        fun setStatus(c: Context, s: String) {
            prefs(c).edit().putString("status", s).putLong("status_at", System.currentTimeMillis()).apply()
        }

        fun markConnected(c: Context) {
            val now = System.currentTimeMillis()
            prefs(c).edit().putLong("connected_at", now).putLong("heartbeat_at", now).apply()
        }

        fun markHeartbeat(c: Context) {
            prefs(c).edit().putLong("heartbeat_at", System.currentTimeMillis()).apply()
        }

        /** True the first time [messageId] is announced on this device (the last 200 are remembered). */
        @Synchronized
        fun claimNotice(c: Context, messageId: String): Boolean {
            val p = prefs(c)
            val recent = (p.getString("recent", "") ?: "").split(',').filter { it.isNotEmpty() }.toMutableList()
            if (messageId in recent) return false
            recent.add(messageId)
            while (recent.size > RECENT_MAX) recent.removeAt(0)
            p.edit().putString("recent", recent.joinToString(",")).apply()
            return true
        }

        fun snapshot(c: Context): Map<String, Any?> {
            val p = prefs(c)
            return mapOf(
                "enabled" to p.getBoolean("enabled", false),
                "status" to status(c),
                "statusAt" to p.getLong("status_at", 0),
                "connectedAt" to p.getLong("connected_at", 0),
                "heartbeatAt" to p.getLong("heartbeat_at", 0),
                "lastId" to lastId(c),
                "running" to (EventsService.instance != null),
            )
        }
    }
}

/** AES-256-GCM with a non-exportable Android Keystore key. */
internal object KeyBox {
    private const val ALIAS = "tove_events_key"
    private const val TAG = "ToveKeyBox"

    private fun secret(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build())
        return gen.generateKey()
    }

    fun seal(plain: String): String? = try {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, secret()) }
        val out = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(out, Base64.NO_WRAP)
    } catch (e: Exception) {
        Log.w(TAG, "Could not encrypt the key: ${e.javaClass.simpleName}")
        null
    }

    fun open(sealed: String): String? = try {
        val (iv, body) = sealed.split(':', limit = 2).map { Base64.decode(it, Base64.NO_WRAP) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, secret(), GCMParameterSpec(128, iv))
        }
        String(cipher.doFinal(body), Charsets.UTF_8)
    } catch (e: Exception) {
        Log.w(TAG, "Could not decrypt the key: ${e.javaClass.simpleName}")
        null
    }
}
