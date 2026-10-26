package io.github.simomagnus.universitynotes.widgets

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.widget.RemoteViews
import io.github.simomagnus.universitynotes.MainActivity
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Calendar

/**
 * Parti comuni dei widget: dati scritti dall'app, apertura dell'app su una
 * schermata, misure del widget (layout diversi per dimensione),
 * aggiornamento di tutti i widget.
 */
object WidgetSupport {
    const val CHANNEL = "io.github.simomagnus.universitynotes/widgets"

    /** Extra dell'intent con la schermata da aprire. */
    const val EXTRA_ROUTE = "uninotes_route"
    private const val ACTION_OPEN = "io.github.simomagnus.universitynotes.WIDGET"

    /** Apre il registratore. */
    const val ROUTE_RECORD = "registra"

    /** Apre il registratore e avvia subito la registrazione (widget «Registra
     *  lezione»), vedi lib/core/reminders/notification_plan.dart. */
    const val ROUTE_RECORD_START = "registra:avvia"

    /** Codice segreto dei widget (vedi [routeOf]). */
    private const val EXTRA_TOKEN = "uninotes_widget_token"
    private const val TOKEN_FILE = "uninotes_widgets"
    private const val TOKEN_KEY = "token"

    /**
     * Il plugin shared_preferences (API classica) salva in questo file con il
     * prefisso «flutter.»: vedi LegacySharedPreferencesPlugin.kt e
     * shared_preferences_legacy.dart (`_prefix = 'flutter.'`).
     */
    private const val PREFS_FILE = "FlutterSharedPreferences"
    private const val DATA_KEY = "flutter.uninotes_widget_data"

    /** Codice della PendingIntent dell'aggiornamento a mezzanotte. */
    private const val REQ_MIDNIGHT = 7300

    /**
     * Schermata chiesta da [intent] (null se nessuna).
     *
     * `registra:avvia` fa partire il microfono, quindi vale solo se l'intent
     * ha il codice segreto che l'app mette nelle PendingIntent dei suoi
     * widget: MainActivity è esportata (è l'icona dell'app) e un'altra app
     * potrebbe mandarle la stessa rotta. Senza il codice giusto diventa
     * `registra` (apre solo il registratore, nessuna registrazione).
     *
     * [fresh] falso (attività ricreata dopo la chiusura del processo) o
     * intent riaperto dalle app recenti (FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY):
     * è ancora quello del tocco di allora, con il codice giusto; senza questo
     * controllo riaprire UniNotes dalle app recenti avviava di nuovo il
     * microfono. Anche lì diventa `registra`.
     */
    fun routeOf(context: Context, intent: Intent?, fresh: Boolean = true): String? {
        val route = try {
            intent?.getStringExtra(EXTRA_ROUTE)
        } catch (e: Exception) {
            // extra rovinati (Bundle non leggibile mandato da un'altra app)
            null
        }?.takeIf { it.isNotBlank() } ?: return null
        if (route != ROUTE_RECORD_START) return route
        val fromHistory = intent != null &&
            (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (!fresh || fromHistory) return ROUTE_RECORD
        val given = try {
            intent?.getStringExtra(EXTRA_TOKEN)
        } catch (e: Exception) {
            null
        }
        val mine = token(context)
        val ok = given != null && mine != null && MessageDigest.isEqual(
            given.toByteArray(Charsets.UTF_8),
            mine.toByteArray(Charsets.UTF_8),
        )
        return if (ok) route else ROUTE_RECORD
    }

    /** Codice casuale dell'installazione, nelle preferenze private dell'app
     *  (null se non si riesce a leggerlo né a scriverlo). */
    @Synchronized
    private fun token(context: Context): String? = try {
        val prefs = context.getSharedPreferences(TOKEN_FILE, Context.MODE_PRIVATE)
        prefs.getString(TOKEN_KEY, null)?.takeIf { it.length == 32 } ?: run {
            val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
            val t = bytes.joinToString("") {
                (it.toInt() and 0xff).toString(16).padStart(2, '0')
            }
            if (prefs.edit().putString(TOKEN_KEY, t).commit()) t else null
        }
    } catch (e: Exception) {
        null
    }

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

    /** Apre l'app sulla schermata [route]; [requestCode] distingue i tocchi.
     *  PendingIntent immutabile verso MainActivity (dell'app). */
    fun openApp(context: Context, route: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = ACTION_OPEN
            // dati diversi per ogni schermata: PendingIntent distinti
            data = Uri.Builder().scheme("uninotes").authority("widget")
                .appendPath(route).build()
            putExtra(EXTRA_ROUTE, route)
            if (route == ROUTE_RECORD_START) token(context)?.let { putExtra(EXTRA_TOKEN, it) }
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    // ------------------------------------------------------------ misure

    /**
     * Misure del widget in dp.
     *
     * - Android 12+: quelle che il launcher dichiara (di solito verticale e
     *   orizzontale): ognuna avrà il suo layout e il sistema sceglie quello
     *   giusto anche ruotando, senza chiedere un nuovo disegno.
     * - Android 8-11: una sola misura, la più piccola delle due orientazioni
     *   (larghezza minima, altezza minima), che va bene in entrambe: su
     *   queste versioni la rotazione non ridisegna il widget.
     *
     * Vuota se il launcher non le ha ancora date.
     */
    fun sizes(manager: AppWidgetManager, widgetId: Int): List<SizeF> {
        val o: Bundle = try {
            manager.getAppWidgetOptions(widgetId) ?: Bundle()
        } catch (e: Exception) {
            Bundle()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val list: List<SizeF>? = try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    o.getParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, SizeF::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    o.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES)
                }
            } catch (e: Exception) {
                null
            }
            val clean = list.orEmpty().filter { it.width > 0f && it.height > 0f }
                .distinct().take(MAX_SIZES)
            if (clean.isNotEmpty()) return clean
        }
        val minW = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
        val minH = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
        val maxW = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 0)
        val maxH = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)
        if (minW <= 0 || minH <= 0) return emptyList()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && maxW > 0 && maxH > 0) {
            // verticale (stretto e alto) e orizzontale (largo e basso)
            return listOf(SizeF(minW.toFloat(), maxH.toFloat()), SizeF(maxW.toFloat(), minH.toFloat()))
                .distinct()
        }
        return listOf(SizeF(minW.toFloat(), minH.toFloat()))
    }

    /** RemoteViews per misura: su Android 12+ una mappa (il sistema sceglie la
     *  più grande che entra), prima un layout solo. Senza misure si usano
     *  [breakpoints] (12+) o [fallback]. */
    fun responsive(
        sizes: List<SizeF>,
        breakpoints: List<SizeF>,
        fallback: SizeF,
        build: (SizeF) -> RemoteViews,
    ): RemoteViews {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val list = sizes.ifEmpty { breakpoints }.distinct().take(MAX_SIZES)
            if (list.size > 1) return RemoteViews(list.associateWith(build))
            return build(list.firstOrNull() ?: fallback)
        }
        return build(sizes.firstOrNull() ?: fallback)
    }

    /** Limite delle RemoteViews per misura (RemoteViews.MAX_INIT_VIEW_COUNT). */
    private const val MAX_SIZES = 16

    /** dp → pixel. */
    fun px(context: Context, dp: Int): Int =
        Math.round(dp * context.resources.displayMetrics.density)

    // ------------------------------------------------------------ date

    /** Giorni da oggi alla data «aaaa-mm-gg» (null se non valida). */
    fun daysUntil(isoDate: String): Int? {
        val parts = isoDate.split("-")
        if (parts.size != 3) return null
        val y = parts[0].toIntOrNull() ?: return null
        val m = parts[1].toIntOrNull() ?: return null
        val d = parts[2].toIntOrNull() ?: return null
        if (m !in 1..12 || d !in 1..31) return null
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

    /** «Oggi», «Domani», «Tra 5 giorni» (corto: «Tra 5 gg»), come nell'app. */
    fun daysLabel(days: Int, short: Boolean = false): String = when {
        days <= 0 -> "Oggi"
        days == 1 -> "Domani"
        short -> "Tra $days gg"
        else -> "Tra $days giorni"
    }

    // ------------------------------------------------------------ aggiornamenti

    /**
     * I giorni mancanti cambiano a mezzanotte: allarme non urgente (nessun
     * risveglio del telefono, nessun permesso) poco dopo la mezzanotte, che
     * ridisegna «Prossime prove» alla prima accensione dello schermo.
     * Si rimette a ogni disegno; senza widget si toglie.
     */
    fun scheduleMidnightRefresh(context: Context) {
        try {
            val am = context.getSystemService(AlarmManager::class.java) ?: return
            val ids = AppWidgetManager.getInstance(context).getAppWidgetIds(
                ComponentName(context, UpcomingExamsWidget::class.java),
            )
            val intent = Intent(context, UpcomingExamsWidget::class.java).apply {
                action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
            }
            val pi = PendingIntent.getBroadcast(
                context,
                REQ_MIDNIGHT,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            if (ids.isEmpty()) {
                am.cancel(pi)
                return
            }
            val next = Calendar.getInstance().apply {
                add(Calendar.DAY_OF_YEAR, 1)
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 30)
                set(Calendar.MILLISECOND, 0)
            }
            am.set(AlarmManager.RTC, next.timeInMillis, pi)
        } catch (e: Exception) {
            // senza allarme restano l'aggiornamento ogni 12 ore e quelli
            // dell'app
        }
    }

    /** Ridisegna tutti i widget dell'app (dopo che l'app ha scritto i dati). */
    fun refreshAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val exams = manager.getAppWidgetIds(
            ComponentName(context, UpcomingExamsWidget::class.java),
        )
        for (id in exams) UpcomingExamsWidget.render(context, manager, id)
        RecordWidget.refresh(context)
    }
}
