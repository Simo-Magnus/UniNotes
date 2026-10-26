package io.github.simomagnus.universitynotes.widgets

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.format.DateUtils
import android.util.SizeF
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import io.github.simomagnus.universitynotes.R
import io.github.simomagnus.universitynotes.RecordingCommandReceiver
import io.github.simomagnus.universitynotes.RecordingNotification

/**
 * Widget «Registra lezione».
 *
 * - **Fermo**: il pulsante arancione dell'app. Il tocco apre MainActivity
 *   con la rotta `registra:avvia` (PendingIntent immutabile, con il codice
 *   segreto di [WidgetSupport.routeOf]): l'app avvia la registrazione con
 *   lo stesso percorso del pulsante «Registra» (corso attuale, lingua delle
 *   lezioni, nome «AAAA-MM-GG HH:MM», permesso del microfono) e, appena è
 *   partita, torna alla schermata Home (moveTaskToBack). Serve l'attività:
 *   da Android 14 un servizio in primo piano di tipo `microphone` va
 *   avviato con un'attività dell'app visibile (docs/widget.md).
 * - **In registrazione / in pausa**: pallino rosso, stato, corso, tempo che
 *   scorre (Chronometer delle RemoteViews; in pausa un testo fisso) e i
 *   comandi Pausa/Riprendi, Salva ed Elimina. I comandi sono broadcast
 *   espliciti e immutabili al ricevitore non esportato della notifica
 *   ([RecordingCommandReceiver]), che li passa al registratore come i
 *   pulsanti della notifica. «Elimina» vuole un secondo tocco entro 4
 *   secondi («Tocca di nuovo per eliminare»), e la registrazione va
 *   comunque in «Eliminati di recente» (recuperabile per 30 giorni).
 *
 * Stato: un'unica fonte, la notifica della registrazione. Ogni volta che
 * l'app mostra o aggiorna la notifica (RecordingNotification.handle,
 * `show`) il widget riceve lo stesso stato, e alla fine (`stopped`) torna
 * fermo: vale per registrazioni avviate dall'app, dalla notifica o dal
 * widget. Lo stato vive solo in memoria nel processo dell'app: se il
 * sistema chiude l'app durante la registrazione, il primo disegno in un
 * processo nuovo (controllo periodico non urgente, riapertura dell'app,
 * tocco su un comando) trova lo stato vuoto e rimette il widget fermo,
 * invece di lasciarlo bloccato su «In registrazione».
 */
class RecordWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) render(context, appWidgetManager, id)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        render(context, appWidgetManager, appWidgetId)
    }

    /** Registrazione in corso secondo l'app (dalla notifica). */
    data class Live(
        val paused: Boolean,
        /** Tempo registrato quando l'app l'ha mandato. */
        val elapsedMs: Long,
        /** SystemClock.elapsedRealtime() in quel momento. */
        val at: Long,
        val course: String,
    )

    companion object {
        /** Comandi del widget per [RecordingCommandReceiver]. */
        const val CMD_DELETE = "elimina_widget"
        const val CMD_VERIFY = "verifica_widget"

        /** Comando verso l'app (Flutter): elimina la registrazione. */
        const val CMD_DISCARD = "elimina"

        private const val ACTION = "io.github.simomagnus.universitynotes.REGISTRAZIONE_WIDGET"

        /** Finestra per il secondo tocco su «Elimina». */
        private const val CONFIRM_MS = 4_000L

        /** Controllo dello stato durante la registrazione (allarme non
         *  urgente: arriva alla prima accensione dello schermo). */
        private const val VERIFY_MS = 5 * 60_000L

        // codici delle PendingIntent (diversi da quelli della notifica)
        private const val REQ_PAUSE = 7201
        private const val REQ_RESUME = 7202
        private const val REQ_SAVE = 7203
        private const val REQ_DELETE = 7204
        private const val REQ_VERIFY = 7205
        private const val REQ_START = 1_000_000
        private const val REQ_OPEN = 2_000_000

        @Volatile
        var live: Live? = null
            private set

        /** Fine della finestra di conferma di «Elimina» (elapsedRealtime). */
        private var armedUntil = 0L
        private val handler by lazy { Handler(Looper.getMainLooper()) }

        private val idleBreakpoints = listOf(SizeF(40f, 40f), SizeF(110f, 40f), SizeF(160f, 40f))
        private val recBreakpoints = listOf(
            SizeF(40f, 40f),
            SizeF(40f, 78f),
            SizeF(110f, 40f),
            SizeF(110f, 78f),
            SizeF(110f, 120f),
            SizeF(200f, 40f),
            SizeF(250f, 110f),
        )
        private val fallback = SizeF(110f, 40f)

        /** Nuovo stato dall'app (null = nessuna registrazione). */
        fun setLive(context: Context, state: Live?) {
            live = state
            if (state == null) armedUntil = 0L
            scheduleVerify(context, state != null)
            refresh(context)
        }

        fun refresh(context: Context) {
            try {
                val manager = AppWidgetManager.getInstance(context)
                val ids = manager.getAppWidgetIds(ComponentName(context, RecordWidget::class.java))
                for (id in ids) render(context, manager, id)
            } catch (e: Exception) {
            }
        }

        /** Registrazione davvero in corso in questo processo: stato
         *  ricevuto e app (Flutter) ancora collegata. */
        private fun running(): Boolean = live != null && RecordingNotification.onCommand != null

        /** Tocco su «Elimina»: il primo arma la conferma, il secondo (entro
         *  [CONFIRM_MS]) chiede all'app di eliminare. */
        fun onDeleteTap(context: Context) {
            if (!running()) {
                setLive(context, null)
                return
            }
            val now = SystemClock.elapsedRealtime()
            if (now < armedUntil) {
                armedUntil = 0L
                RecordingNotification.onCommand?.invoke(CMD_DISCARD)
                refresh(context)
                return
            }
            armedUntil = now + CONFIRM_MS
            refresh(context)
            handler.postDelayed({
                if (armedUntil != 0L && SystemClock.elapsedRealtime() >= armedUntil) {
                    armedUntil = 0L
                    refresh(context)
                }
            }, CONFIRM_MS + 100L)
        }

        /** Controllo periodico durante la registrazione. */
        fun verify(context: Context) {
            if (running()) scheduleVerify(context, true) else setLive(context, null)
        }

        /** Comando che arriva quando l'app non registra più (processo nuovo,
         *  app chiusa dal sistema): il widget torna fermo. */
        fun stale(context: Context) {
            if (!running()) setLive(context, null)
        }

        private fun command(context: Context, command: String, requestCode: Int): PendingIntent {
            val intent = Intent(context, RecordingCommandReceiver::class.java).apply {
                action = ACTION
                // dati diversi per comando: PendingIntent distinte anche da
                // quelle della notifica
                data = Uri.Builder().scheme("uninotes").authority("registrazione")
                    .appendPath(command).build()
                putExtra(RecordingNotification.EXTRA_COMMAND, command)
            }
            return PendingIntent.getBroadcast(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun scheduleVerify(context: Context, on: Boolean) {
            try {
                val am = context.getSystemService(AlarmManager::class.java) ?: return
                val pi = command(context, CMD_VERIFY, REQ_VERIFY)
                if (on) {
                    am.set(
                        AlarmManager.ELAPSED_REALTIME,
                        SystemClock.elapsedRealtime() + VERIFY_MS,
                        pi,
                    )
                } else {
                    am.cancel(pi)
                }
            } catch (e: Exception) {
            }
        }

        fun render(context: Context, manager: AppWidgetManager, widgetId: Int) {
            val state = if (running()) live else null
            val armed = state != null && SystemClock.elapsedRealtime() < armedUntil
            val views = WidgetSupport.responsive(
                WidgetSupport.sizes(manager, widgetId),
                if (state == null) idleBreakpoints else recBreakpoints,
                fallback,
            ) { size ->
                val plan = WidgetPlan.record(size.width, size.height, state != null)
                if (state == null) idle(context, widgetId, plan) else recording(context, widgetId, plan, state, armed)
            }
            try {
                manager.updateAppWidget(widgetId, views)
            } catch (e: Exception) {
            }
        }

        private fun idle(context: Context, widgetId: Int, plan: WidgetPlan.Record): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_registra)
            val start = WidgetSupport.openApp(context, WidgetSupport.ROUTE_RECORD_START, REQ_START + widgetId)
            val pill = plan.mode == WidgetPlan.RecordMode.IDLE_PILL
            v.setViewVisibility(R.id.record_icon_group, if (pill) View.GONE else View.VISIBLE)
            v.setViewVisibility(R.id.record_pill, if (pill) View.VISIBLE else View.GONE)
            v.setTextViewText(
                R.id.record_pill_label,
                context.getString(if (plan.longLabel) R.string.widget_registra_nome else R.string.widget_registra_testo),
            )
            v.setOnClickPendingIntent(android.R.id.background, start)
            v.setOnClickPendingIntent(R.id.record_pill, start)
            v.setOnClickPendingIntent(R.id.record_icon_button, start)
            return v
        }

        private fun recording(
            context: Context,
            widgetId: Int,
            plan: WidgetPlan.Record,
            state: Live,
            armed: Boolean,
        ): RemoteViews {
            val row = plan.mode == WidgetPlan.RecordMode.REC_ROW
            val v = RemoteViews(
                context.packageName,
                if (row) R.layout.widget_registra_riga else R.layout.widget_registra_attivo,
            )
            v.setOnClickPendingIntent(
                android.R.id.background,
                WidgetSupport.openApp(context, WidgetSupport.ROUTE_RECORD, REQ_OPEN + widgetId),
            )
            v.setContentDescription(android.R.id.background, context.getString(R.string.widget_registra_apri))

            // tempo: cronometro del sistema mentre registra, testo fisso in
            // pausa (un cronometro fermo cambierebbe valore se il launcher
            // ridisegna il widget più tardi)
            val now = SystemClock.elapsedRealtime()
            if (state.paused) {
                v.setViewVisibility(R.id.rec_time, View.GONE)
                v.setViewVisibility(R.id.rec_time_fixed, if (armed) View.GONE else View.VISIBLE)
                v.setTextViewText(R.id.rec_time_fixed, DateUtils.formatElapsedTime(state.elapsedMs / 1000))
                v.setChronometer(R.id.rec_time, now - state.elapsedMs, null, false)
            } else {
                v.setViewVisibility(R.id.rec_time_fixed, View.GONE)
                v.setViewVisibility(R.id.rec_time, if (armed) View.GONE else View.VISIBLE)
                v.setChronometer(R.id.rec_time, state.at - state.elapsedMs, null, true)
            }
            v.setViewVisibility(R.id.rec_confirm, if (armed) View.VISIBLE else View.GONE)
            // pallino rosso solo mentre registra
            v.setViewVisibility(R.id.rec_dot, if (state.paused) View.INVISIBLE else View.VISIBLE)

            if (!row) {
                v.setTextViewText(
                    R.id.rec_status,
                    context.getString(if (state.paused) R.string.widget_registra_in_pausa else R.string.widget_registra_in_corso),
                )
                val showCourse = plan.course && state.course.isNotEmpty()
                v.setViewVisibility(R.id.rec_course, if (showCourse) View.VISIBLE else View.GONE)
                if (showCourse) v.setTextViewText(R.id.rec_course, " · " + state.course.take(120))
                val size = when {
                    plan.big -> 26f
                    plan.controls -> 20f
                    else -> 15f
                }
                v.setTextViewTextSize(R.id.rec_time, TypedValue.COMPLEX_UNIT_SP, size)
                v.setTextViewTextSize(R.id.rec_time_fixed, TypedValue.COMPLEX_UNIT_SP, size)
                val labels = if (plan.labels) View.VISIBLE else View.GONE
                v.setViewVisibility(R.id.rec_pause_label, labels)
                v.setTextViewText(
                    R.id.rec_pause_label,
                    context.getString(if (state.paused) R.string.widget_registra_riprendi else R.string.widget_registra_pausa),
                )
                v.setViewVisibility(R.id.rec_save_label, labels)
                v.setViewVisibility(R.id.rec_delete_label, if (plan.labels && !armed) View.VISIBLE else View.GONE)
                v.setViewVisibility(R.id.rec_delete_armed_label, if (plan.labels && armed) View.VISIBLE else View.GONE)
            }

            // Pausa / Riprendi
            v.setImageViewResource(
                R.id.rec_pause_icon,
                if (state.paused) R.drawable.ic_widget_play else R.drawable.ic_widget_pause,
            )
            v.setContentDescription(
                R.id.rec_pause,
                context.getString(if (state.paused) R.string.widget_registra_riprendi else R.string.widget_registra_pausa),
            )
            v.setOnClickPendingIntent(
                R.id.rec_pause,
                if (state.paused) {
                    command(context, "riprendi", REQ_RESUME)
                } else {
                    command(context, "pausa", REQ_PAUSE)
                },
            )

            // Salva ed Elimina (solo se c'è posto)
            val controls = if (plan.controls) View.VISIBLE else View.GONE
            v.setViewVisibility(R.id.rec_save, controls)
            v.setViewVisibility(R.id.rec_delete, controls)
            v.setOnClickPendingIntent(R.id.rec_save, command(context, "salva", REQ_SAVE))
            v.setOnClickPendingIntent(R.id.rec_delete, command(context, CMD_DELETE, REQ_DELETE))
            v.setInt(
                R.id.rec_delete,
                "setBackgroundResource",
                if (armed) R.drawable.widget_button_delete_armed else R.drawable.widget_button_delete,
            )
            v.setImageViewResource(
                R.id.rec_delete_icon,
                if (armed) R.drawable.ic_widget_delete_armed else R.drawable.ic_widget_delete,
            )
            v.setContentDescription(
                R.id.rec_delete,
                context.getString(
                    if (armed) R.string.widget_registra_conferma_descrizione else R.string.widget_registra_elimina_descrizione,
                ),
            )
            return v
        }
    }
}
