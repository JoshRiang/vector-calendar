package com.joshua.vector_calendar

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * Today home-screen widget.
 *
 * Fetches the API on a background thread (a widget provider runs on the main
 * thread, so network work here must never be done inline) and renders with
 * RemoteViews. Falls back to a readable message instead of an empty box when
 * the server is unreachable -- a widget that silently shows nothing is
 * indistinguishable from a broken app.
 */
class TodayWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_today)
            views.setTextViewText(R.id.widget_primary, context.getString(R.string.widget_loading))
            views.setTextViewText(R.id.widget_secondary, "")
            appWidgetManager.updateAppWidget(id, views)
            thread { refresh(context, appWidgetManager, id) }
        }
    }

    private fun refresh(context: Context, mgr: AppWidgetManager, id: Int) {
        val views = RemoteViews(context.packageName, R.layout.widget_today)
        try {
            val body = httpGet(context, "/today")
            val (primary, secondary, badge) = render(body)
            views.setTextViewText(R.id.widget_primary, primary)
            views.setTextViewText(R.id.widget_secondary, secondary)
            views.setTextViewText(R.id.widget_badge, badge)
        } catch (e: Exception) {
            views.setTextViewText(R.id.widget_primary, context.getString(R.string.widget_offline))
            views.setTextViewText(R.id.widget_secondary, context.getString(R.string.widget_offline_hint))
            views.setTextViewText(R.id.widget_badge, "")
        }

        // Tapping the widget opens the app.
        val intent = Intent(context, MainActivity::class.java)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        views.setOnClickPendingIntent(
            R.id.widget_root,
            PendingIntent.getActivity(context, 0, intent, flags)
        )
        mgr.updateAppWidget(id, views)
    }

    /** Today content. Returns (primary, secondary, badge). */
    private fun render(body: String): Triple<String, String, String> {

        val o = JSONObject(body)
        val startable = o.optJSONArray("startable") ?: JSONArray()
        val done = o.optJSONArray("done_today") ?: JSONArray()
        val focus = o.optInt("focus_minutes", 0)
        var planned = 0
        for (i in 0 until startable.length()) {
            planned += startable.getJSONObject(i).optInt("minutes", 0)
        }
        val primary = if (startable.length() == 0)
            "Nothing to start"
        else
            startable.getJSONObject(0).optString("title", "Untitled")
        val secondary = startable.length().toString() + " to start  \u00b7  " +
            planned.toString() + " min  \u00b7  " + done.length().toString() + " done"
        val badge = if (focus > 0) focus.toString() + "M FOCUSED" else "TODAY"
        return Triple(primary, secondary, badge)
    }

    /** Group digits so a 7-figure amount stays readable in a narrow widget. */
    private fun fmt(v: Double): String {
        val s = String.format("%,.0f", v)
        return s
    }

    private fun httpGet(context: Context, path: String): String {
        val base = context.getString(R.string.vector_api_base).trimEnd('/')
        val userId = context.getString(R.string.vector_user_id)
        val conn = (URL(base + path).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 8000
            readTimeout = 8000
            setRequestProperty("X-User-Id", userId)
            // Shared secret, required once the API is publicly reachable.
            val apiKey = context.getString(R.string.vector_api_key)
            if (apiKey.isNotEmpty()) setRequestProperty("X-Api-Key", apiKey)
            setRequestProperty("Accept", "application/json")
        }
        try {
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            return stream?.bufferedReader()?.use { it.readText() } ?: ""
        } finally {
            conn.disconnect()
        }
    }
}
