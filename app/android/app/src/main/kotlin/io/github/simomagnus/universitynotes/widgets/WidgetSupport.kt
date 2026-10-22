package io.github.simomagnus.universitynotes.widgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import io.github.simomagnus.universitynotes.MainActivity
import org.json.JSONObject
import java.util.Calendar

/**
 * Parti comuni dei widget: dati scritti dall'app, apertura dell'app su una
 * schermata, aggiornamento di tutti i widget.
 */
object WidgetSupport {
    const val CHANNEL = "io.github.simomagnus.universitynotes/widgets"

    /** Extra dell'intent con la schermata da aprire. */
    const val EXTRA_ROUTE = "uninotes_route"
    private const val ACTION_OPEN = "io.github.simomagnus.universitynotes.WIDGET"

    /**
     * Il plugin shared_preferences (API classica) salva in questo file con il
     * prefisso «flutter.»: vedi LegacySharedPreferencesPlugin.kt e
     * shared_preferences_legacy.dart (`_prefix = 'flutter.'`).
     */
    private const val PREFS_FILE = "FlutterSharedPreferences"
    private const val DATA_KEY = "flutter.uninotes_widget_data"

    fun routeOf(intent: Intent?): String? =
        intent?.getStringExtra(EXTRA_ROUTE)?.takeIf { it.isNotBlank() }

    /** Dati JSON dei widget (null se l'app non li ha ancora scritti). */
    fun data(context: Context): JSONObject? = try {
        // anche la lettura dentro il try: un valore di altro tipo (versioni
        // vecchie, preferenze rovinate) lancerebbe ClassCastException in
        // onUpdate e chiuderebbe l'app
        val raw = context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
            .getString(DATA_KEY, null)
        if (raw == null) null else JSONObject(raw)
    } catch (e: Exception) {
        null
    }

    /** Apre l'app sulla schermata [route]; [requestCode] distingue i tocchi. */
    fun openApp(context: Context, route: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = ACTION_OPEN
            // dati diversi per ogni schermata: PendingIntent distinti
            data = Uri.Builder().scheme("uninotes").authority("widget")
                .appendPath(route).build()
            putExtra(EXTRA_ROUTE, route)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** Giorni da oggi alla data «aaaa-mm-gg» (null se non valida). */
    fun daysUntil(isoDate: String): Int? {
        val parts = isoDate.split("-")
        if (parts.size != 3) return null
        val y = parts[0].toIntOrNull() ?: return null
        val m = parts[1].toIntOrNull() ?: return null
        val d = parts[2].toIntOrNull() ?: return null
        val today = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 12)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val day = Calendar.getInstance().apply {
            clear()
            set(y, m - 1, d, 12, 0, 0)
        }
        val diff = day.timeInMillis - today.timeInMillis
        return Math.round(diff / 86_400_000.0).toInt()
    }

    fun daysLabel(days: Int): String = when {
        days <= 0 -> "Oggi"
        days == 1 -> "Domani"
        else -> "Tra $days giorni"
    }

    /** Ridisegna tutti i widget dell'app (dopo che l'app ha scritto i dati). */
    fun refreshAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val exams = manager.getAppWidgetIds(
            ComponentName(context, UpcomingExamsWidget::class.java),
        )
        for (id in exams) UpcomingExamsWidget.render(context, manager, id)
        val record = manager.getAppWidgetIds(
            ComponentName(context, RecordWidget::class.java),
        )
        for (id in record) RecordWidget.render(context, manager, id)
    }
}
