package io.github.tovechat.tove

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.widget.RemoteViews

/**
 * Home-screen widgets. Both are plain RemoteViews with explicit, immutable PendingIntents into
 * [MainActivity] (see [LaunchPlugin] for the links). Colours come from the system's Material You
 * palette on Android 12+ (`values-v31/colors_widgets.xml`).
 *
 *  * [AskWidget]: an "Ask Tove" bar. The bar opens a new chat with the keyboard up; the mic opens
 *    live voice.
 *  * [QuickWidget]: 2x2 with Chat, Live and the last chat. The app reports the last chat through
 *    `tove/launch` `setRecentChat`; until it does, that row opens a new chat.
 */
object ToveWidgets {
    private const val PREFS = "tove_widgets"
    private const val KEY_ID = "recent_id"
    private const val KEY_TITLE = "recent_title"

    // Request codes keep each PendingIntent distinct.
    private const val RC_ASK = 7101
    private const val RC_ASK_MIC = 7102
    private const val RC_CHAT = 7103
    private const val RC_LIVE = 7104
    private const val RC_LAST = 7105

    fun setRecentChat(context: Context, id: String?, title: String?) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val cleanId = id?.takeIf { it.isNotBlank() }
        val cleanTitle = title?.trim()?.takeIf { it.isNotEmpty() && cleanId != null }
        if (prefs.getString(KEY_ID, null) == cleanId && prefs.getString(KEY_TITLE, null) == cleanTitle) return
        prefs.edit().putString(KEY_ID, cleanId).putString(KEY_TITLE, cleanTitle).apply()
        updateQuick(context)
    }

    private fun pending(context: Context, code: Int, link: String): PendingIntent =
        PendingIntent.getActivity(
            context, code, LaunchPlugin.openIntent(context, link),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    fun askViews(context: Context): RemoteViews =
        RemoteViews(context.packageName, R.layout.widget_ask).apply {
            setOnClickPendingIntent(R.id.widget_ask_bar, pending(context, RC_ASK, LaunchPlugin.LINK_NEW_CHAT_KEYBOARD))
            setOnClickPendingIntent(R.id.widget_ask_mic, pending(context, RC_ASK_MIC, LaunchPlugin.LINK_LIVE))
        }

    fun quickViews(context: Context): RemoteViews {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val id = prefs.getString(KEY_ID, null)
        val title = prefs.getString(KEY_TITLE, null)
        return RemoteViews(context.packageName, R.layout.widget_quick).apply {
            setOnClickPendingIntent(R.id.widget_quick_chat, pending(context, RC_CHAT, LaunchPlugin.LINK_NEW_CHAT_KEYBOARD))
            setOnClickPendingIntent(R.id.widget_quick_live, pending(context, RC_LIVE, LaunchPlugin.LINK_LIVE))
            if (id != null) {
                setTextViewText(R.id.widget_quick_last_title, title ?: context.getString(R.string.widget_last_chat_description))
                setOnClickPendingIntent(R.id.widget_quick_last, pending(context, RC_LAST, LaunchPlugin.chatLink(id)))
            } else {
                setTextViewText(R.id.widget_quick_last_title, context.getString(R.string.widget_last_chat_none))
                setOnClickPendingIntent(R.id.widget_quick_last, pending(context, RC_LAST, LaunchPlugin.LINK_NEW_CHAT))
            }
        }
    }

    private fun updateQuick(context: Context) {
        val manager = AppWidgetManager.getInstance(context) ?: return
        val ids = manager.getAppWidgetIds(ComponentName(context, QuickWidget::class.java))
        if (ids.isEmpty()) return
        manager.updateAppWidget(ids, quickViews(context))
    }
}

class AskWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        manager.updateAppWidget(ids, ToveWidgets.askViews(context))
    }
}

class QuickWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        manager.updateAppWidget(ids, ToveWidgets.quickViews(context))
    }
}
