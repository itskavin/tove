package io.github.tovechat.tove

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Log

/**
 * The ongoing-call notification. Platform APIs only (no androidx).
 *
 * Lock-screen safe by construction: the text is a fixed status line (live,
 * muted, ending), never transcript, task or bridge content, so it is posted
 * with VISIBILITY_PUBLIC and Mute/End work from the lock screen.
 */
internal object CallNotification {
    private const val TAG = "HermesCallNotification"
    const val CHANNEL_ID = "hermes_live_call"
    const val NOTIFICATION_ID = 0x4C49

    private const val REQUEST_CONTENT = 1
    private const val REQUEST_MUTE = 2
    private const val REQUEST_UNMUTE = 3
    private const val REQUEST_END = 4
    private const val REQUEST_REPOST = 5

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        // LOW: shown in the shade, status bar and lock screen, but no sound,
        // vibration or heads-up, so updates never buzz.
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.call_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = context.getString(R.string.call_channel_description)
            setShowBadge(false)
            enableVibration(false)
            enableLights(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    fun build(
        context: Context,
        muted: Boolean,
        startedAtWallMs: Long,
        ending: Boolean,
        allowCallStyle: Boolean = true,
    ): Notification {
        ensureChannel(context)
        val builder = newBuilder(context)
            .setSmallIcon(R.drawable.ic_stat_hermes)
            .setColor(context.getColor(R.color.hermes_accent))
            .setContentTitle(context.getString(R.string.call_title))
            .setContentText(
                context.getString(
                    when {
                        ending -> R.string.call_text_ending
                        muted -> R.string.call_text_muted
                        else -> R.string.call_text_live
                    },
                ),
            )
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setLocalOnly(true)
            .setShowWhen(true)
            .setWhen(startedAtWallMs)
            .setUsesChronometer(true)
            .setContentIntent(contentIntent(context))
            // Android 14+ lets users swipe away non-CallStyle FGS notifications;
            // post it again so the controls stay reachable.
            .setDeleteIntent(serviceIntent(context, HermesCallService.ACTION_REPOST, REQUEST_REPOST))

        if (Build.VERSION.SDK_INT >= 31) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }

        if (ending) return builder.build()

        val muteAction = if (muted) {
            action(context, R.drawable.ic_call_mic, R.string.call_action_unmute,
                HermesCallService.ACTION_UNMUTE, REQUEST_UNMUTE)
        } else {
            action(context, R.drawable.ic_call_mic_off, R.string.call_action_mute,
                HermesCallService.ACTION_MUTE, REQUEST_MUTE)
        }
        val endIntent = serviceIntent(context, HermesCallService.ACTION_END, REQUEST_END)

        if (allowCallStyle && Build.VERSION.SDK_INT >= 31) {
            // CallStyle: the system draws the red Hang up button from endIntent,
            // ranks the notification as an ongoing call, shows the status-bar
            // call chip, and keeps it non-dismissible on Android 14+. Mute is
            // added as an extra (non-contextual) action.
            val person = Person.Builder()
                .setName(context.getString(R.string.call_person))
                .setIcon(Icon.createWithResource(context, R.mipmap.ic_launcher))
                .setImportant(true)
                .build()
            builder.setStyle(Notification.CallStyle.forOngoingCall(person, endIntent))
            builder.addAction(muteAction)
        } else {
            builder.addAction(muteAction)
            builder.addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(context, R.drawable.ic_call_end),
                    context.getString(R.string.call_action_end),
                    endIntent,
                ).build(),
            )
        }
        return builder.build()
    }

    /** Updates the posted notification; falls back to a plain style if the
     *  platform rejects CallStyle for any reason. */
    fun post(context: Context, muted: Boolean, startedAtWallMs: Long, ending: Boolean) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        try {
            manager.notify(NOTIFICATION_ID, build(context, muted, startedAtWallMs, ending))
        } catch (e: RuntimeException) {
            Log.w(TAG, "CallStyle update rejected, using a plain notification", e)
            try {
                manager.notify(
                    NOTIFICATION_ID,
                    build(context, muted, startedAtWallMs, ending, allowCallStyle = false),
                )
            } catch (inner: RuntimeException) {
                Log.e(TAG, "Could not update the call notification", inner)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun newBuilder(context: Context): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
                .setPriority(Notification.PRIORITY_LOW)
                .setSound(null)
                .setVibrate(null)
        }

    private fun action(
        context: Context,
        icon: Int,
        label: Int,
        serviceAction: String,
        requestCode: Int,
    ): Notification.Action = Notification.Action.Builder(
        Icon.createWithResource(context, icon),
        context.getString(label),
        serviceIntent(context, serviceAction, requestCode),
    ).build()

    /** Explicit, immutable, and aimed at the non-exported service. */
    private fun serviceIntent(context: Context, serviceAction: String, requestCode: Int): PendingIntent =
        PendingIntent.getService(
            context,
            requestCode,
            Intent(context, HermesCallService::class.java).setAction(serviceAction),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun contentIntent(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context,
            REQUEST_CONTENT,
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
}
