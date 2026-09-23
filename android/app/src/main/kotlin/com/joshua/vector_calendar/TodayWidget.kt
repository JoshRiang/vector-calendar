package com.joshua.vector_calendar

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.util.Calendar
import kotlin.concurrent.thread

/**
 * VECTOR Calendar home-screen widget: a real month grid.
 *
 * Renders a 7-column calendar the way a calendar widget is expected to look --
 * weekday headers, a ringed "today", and a dot under any day that has tasks
 * scheduled. The dot count is driven by the API, not guessed.
 *
 * Date maths uses java.util.Calendar, not java.time: minSdk is 21 and
 * java.time requires API 26.
 */
class TodayWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.widget_today)
            views.setTextViewText(R.id.widget_primary,
                context.getString(R.string.widget_loading))
            mgr.updateAppWidget(id, views)
            // The fetch runs in onReceive under goAsync(): a thread started
            // here can be killed the moment onUpdate returns, which made
            // every fetch fail and the widget show "Server unreachable".
        }
    }


    /**
     * The fetch runs here, not in onUpdate, so that goAsync() can hold the
     * broadcast open. A thread started from onUpdate is killed with the process
     * as soon as onUpdate returns, which made the request die and the widget
     * report "Server unreachable" while the server was healthy.
     */
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != AppWidgetManager.ACTION_APPWIDGET_UPDATE) return
        val pending = goAsync()
        val mgr = AppWidgetManager.getInstance(context)
        val ids = mgr.getAppWidgetIds(
            android.content.ComponentName(context, javaClass))
        thread {
            try {
                for (id in ids) refresh(context, mgr, id)
            } finally {
                pending.finish()
            }
        }
    }

    /** Zero-padded day number for a day-of-month. */
    private fun pad(n: Int): String = if (n < 10) "0" + n else n.toString()

    private fun refresh(context: Context, mgr: AppWidgetManager, id: Int) {
        val views = RemoteViews(context.packageName, R.layout.widget_today)
        val cal = Calendar.getInstance()
        val today = cal.get(Calendar.DAY_OF_MONTH)
        val month = cal.get(Calendar.MONTH)
        val year = cal.get(Calendar.YEAR)

        // Which days of THIS month have work. Derived from real tasks, so an
        // empty month shows no dots rather than decoration.
        val busy = HashSet<Int>()
        var startableCount = 0
        var planned = 0
        try {
            val todayJson = JSONObject(httpGet(context, "/today"))
            val st = todayJson.optJSONArray("startable") ?: JSONArray()
            startableCount = st.length()
            for (i in 0 until st.length()) {
                planned += st.getJSONObject(i).optInt("minutes", 0)
            }
            if (startableCount > 0) busy.add(today)
            val done = todayJson.optJSONArray("done_today") ?: JSONArray()
            for (i in 0 until done.length()) {
                val at = done.getJSONObject(i).optString("completed_at", "")
                if (at.length >= 10) {
                    val d = at.substring(8, 10).toIntOrNull()
                    if (d != null) busy.add(d)
                }
            }
        } catch (e: Exception) {
            // Offline: still draw the month, just without dots. A calendar that
            // vanishes when the network blips is worse than one with no dots.
        }

        val monthNames = arrayOf("January", "February", "March", "April", "May",
            "June", "July", "August", "September", "October", "November",
            "December")
        views.setTextViewText(R.id.cal_title,
            monthNames[month] + " " + year.toString())
        views.setTextViewText(R.id.cal_today, today.toString())

        // Build the grid: leading blanks, then days 1..lengthOfMonth.
        val first = Calendar.getInstance().apply {
            set(Calendar.YEAR, year)
            set(Calendar.MONTH, month)
            set(Calendar.DAY_OF_MONTH, 1)
        }
        // Calendar.MONDAY = 2; shift so Sunday (1) starts the week at index 0.
        val lead = (first.get(Calendar.DAY_OF_WEEK) + 6) % 7
        val dim = first.getActualMaximum(Calendar.DAY_OF_MONTH)
        val cells = IntArray(42)
        for (i in 0 until 42) {
            val dayNum = i - lead + 1
            cells[i] = if (dayNum in 1..dim) dayNum else 0
        }
        val ids = intArrayOf(
            R.id.d0, R.id.d1, R.id.d2, R.id.d3, R.id.d4, R.id.d5, R.id.d6,
            R.id.d7, R.id.d8, R.id.d9, R.id.d10, R.id.d11, R.id.d12, R.id.d13,
            R.id.d14, R.id.d15, R.id.d16, R.id.d17, R.id.d18, R.id.d19, R.id.d20,
            R.id.d21, R.id.d22, R.id.d23, R.id.d24, R.id.d25, R.id.d26, R.id.d27,
            R.id.d28, R.id.d29, R.id.d30, R.id.d31, R.id.d32, R.id.d33, R.id.d34,
            R.id.d35, R.id.d36, R.id.d37, R.id.d38, R.id.d39, R.id.d40, R.id.d41)
        for (i in 0 until 42) {
            val d = cells[i]
            if (d == 0) {
                views.setTextViewText(ids[i], "")
            } else if (d == today) {
                views.setTextViewText(ids[i], "[" + pad(d) + "]")
            } else if (busy.contains(d)) {
                views.setTextViewText(ids[i], pad(d) + "\u00b7")
            } else {
                views.setTextViewText(ids[i], pad(d))
            }
        }

        views.setTextViewText(R.id.widget_badge, "TODAY")
        views.setTextViewText(R.id.widget_secondary,
            if (startableCount == 0) context.getString(R.string.widget_all_clear)
            else startableCount.toString() + " to start  \u00b7  " +
                 planned.toString() + " min planned")

        val open = Intent(context, MainActivity::class.java)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        views.setOnClickPendingIntent(R.id.widget_root,
            PendingIntent.getActivity(context, 0, open, flags))
        mgr.updateAppWidget(id, views)
    }


    /** Group digits so a 7-figure amount stays readable in a narrow widget. */
    private fun fmt(v: Double): String = String.format("%,.0f", v)

    /**
     * Endpoints tried in order, after the configured one.
     *
     * The public URL is the only endpoint that works away from home, but it can
     * be unreachable while a private address still answers -- Tailscale DNS up
     * with the tunnel down, a captive portal, a slow cold start. The app has
     * this failover and works; the widget did not, which is why the app
     * recovered while the widget kept reporting "Server unreachable".
     */
    private val FALLBACK_BASES = listOf(
        "http://10.11.11.235:8790",
        "http://100.89.180.23:8790",
    )

    private fun candidateBases(context: Context): List<String> {
        val primary = context.getString(R.string.vector_api_base).trimEnd('/')
        return (listOf(primary) + FALLBACK_BASES)
            .map { it.trimEnd('/') }
            .distinct()
    }

    private fun httpGet(context: Context, path: String): String =
        http(context, "GET", path, null)

    private fun httpPost(context: Context, path: String): String =
        http(context, "POST", path, "{}")

    /**
     * HTTP entry point with endpoint failover. A widget provider runs on the
     * main thread, so every caller is responsible for being off it.
     *
     * Only a transport failure (IOException) moves on to the next endpoint: if
     * the server answered at all, another address would answer the same way.
     */
    private fun http(context: Context, method: String, path: String,
                     body: String?): String {
        var lastError: java.io.IOException? = null
        for (base in candidateBases(context)) {
            try {
                return httpOnce(context, base, method, path, body)
            } catch (e: java.io.IOException) {
                lastError = e
            }
        }
        throw java.io.IOException(
            "no VECTOR endpoint reachable: " + (lastError?.message ?: "unknown"))
    }

    /** One request against one base. */
    private fun httpOnce(context: Context, base: String, method: String,
                         path: String, body: String?): String {
        val userId = context.getString(R.string.vector_user_id)
        val key = context.getString(R.string.vector_api_key)
        val conn = (URL(base + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            // 5s, not 8s: an appwidget update is time-limited, and a dead
            // private address must not eat the budget before the live one.
            connectTimeout = 5000
            readTimeout = 5000
            setRequestProperty("X-User-Id", userId)
            setRequestProperty("Accept", "application/json")
            if (key.isNotEmpty()) setRequestProperty("X-Api-Key", key)
            if (body != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
        }
        try {
            if (body != null) {
                conn.outputStream.use { it.write(body.toByteArray()) }
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            return stream?.bufferedReader()?.use { it.readText() } ?: ""
        } finally {
            conn.disconnect()
        }
    }

    /**
     * Report a widget event to the server.
     *
     * The widget shows "Server unreachable" for every exception it catches,
     * which hides a code bug behind a network diagnosis. Beaconing the real
     * exception is the only way to tell the two apart on a device. Runs
     * SYNCHRONOUSLY: every caller is already off the main thread, and a nested
     * thread could outlive goAsync()'s finisher and be killed before sending.
     */
    private fun beacon(context: Context, stage: String, detail: String) {
        try {
            val base = context.getString(R.string.vector_api_base).trimEnd('/')
            val url = java.net.URL(base + "/diag?stage=" +
                java.net.URLEncoder.encode(stage, "UTF-8") + "&detail=" +
                java.net.URLEncoder.encode(detail.take(500), "UTF-8"))
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 4000
                readTimeout = 4000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("X-User-Id",
                    context.getString(R.string.vector_user_id))
            }
            conn.outputStream.use { it.write("{}".toByteArray()) }
            conn.responseCode
            conn.disconnect()
        } catch (e: Exception) {
            // Never let the diagnostic become the failure.
        }
    }


}
