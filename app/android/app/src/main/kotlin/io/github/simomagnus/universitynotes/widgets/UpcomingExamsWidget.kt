package io.github.simomagnus.universitynotes.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import android.util.SizeF
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import io.github.simomagnus.universitynotes.R
import org.json.JSONObject

/**
 * Widget «Prossime prove»: le prossime prove con i giorni mancanti
 * (ricalcolati a ogni disegno: a mezzanotte, ogni 12 ore e a ogni modifica
 * nell'app). Quante e come dipende dalla misura vera ([WidgetPlan.exams]):
 * 2×2 una prova grande, 4×1 una riga, 4×2 tre righe con la data, più in
 * alto fino a sei. Layout per misura (Android 12+, RemoteViews con la mappa
 * delle misure) o per la misura più piccola (Android 8-11).
 *
 * Tocco su una prova → l'app apre la sua scheda; tocco altrove → pagina
 * Esami.
 */
class UpcomingExamsWidget : AppWidgetProvider() {
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

    override fun onDisabled(context: Context) {
        // ultimo widget tolto: niente più allarme di mezzanotte
        WidgetSupport.scheduleMidnightRefresh(context)
    }

    private data class Row(
        val row: Int,
        val title: Int,
        val whenText: Int,
        val days: Int,
        val urgent: Int,
    )

    /** Una prova del JSON scritto dall'app (home_widgets.dart). */
    private data class Exam(
        val title: String,
        val whenText: String,
        val days: Int,
        val route: String,
    )

    companion object {
        private val rows = arrayOf(
            Row(R.id.exam_row_1, R.id.exam_title_1, R.id.exam_when_1, R.id.exam_days_1, R.id.exam_urgent_1),
            Row(R.id.exam_row_2, R.id.exam_title_2, R.id.exam_when_2, R.id.exam_days_2, R.id.exam_urgent_2),
            Row(R.id.exam_row_3, R.id.exam_title_3, R.id.exam_when_3, R.id.exam_days_3, R.id.exam_urgent_3),
            Row(R.id.exam_row_4, R.id.exam_title_4, R.id.exam_when_4, R.id.exam_days_4, R.id.exam_urgent_4),
            Row(R.id.exam_row_5, R.id.exam_title_5, R.id.exam_when_5, R.id.exam_days_5, R.id.exam_urgent_5),
            Row(R.id.exam_row_6, R.id.exam_title_6, R.id.exam_when_6, R.id.exam_days_6, R.id.exam_urgent_6),
        )

        /** Misure tipiche (dp) per Android 12+ quando il launcher non le dà:
         *  2×2, 4×1, 4×2 orizzontale e verticale, 4×3, 4×4. */
        private val breakpoints = listOf(
            SizeF(110f, 40f),
            SizeF(110f, 100f),
            SizeF(110f, 200f),
            SizeF(200f, 40f),
            SizeF(200f, 100f),
            SizeF(200f, 130f),
            SizeF(200f, 180f),
            SizeF(200f, 230f),
            SizeF(200f, 290f),
            SizeF(200f, 350f),
        )

        /** Misura predefinita (4×2) se il launcher non dice nulla. */
        private val fallback = SizeF(250f, 110f)

        /** Entro questi giorni l'etichetta è rossa (come nell'app). */
        private const val URGENT_DAYS = 7

        fun render(context: Context, manager: AppWidgetManager, widgetId: Int) {
            val data = WidgetSupport.data(context)
            val listRoute = data?.optString("route")?.takeIf { it.isNotEmpty() }
                ?: "sezione:Esami"
            val all = data?.optJSONArray("exams")
            val exams = mutableListOf<Exam>()
            var past = 0
            for (i in 0 until minOf(all?.length() ?: 0, WidgetPlan.MAX_EXAMS)) {
                val e = all?.optJSONObject(i) ?: continue
                val exam = parse(e, listRoute)
                // prova già passata (dati non ancora riscritti dall'app)
                if (exam == null) past++ else exams.add(exam)
            }
            // prove in programma oltre quelle nel JSON («+2» nell'intestazione)
            val beyond = maxOf(0, (data?.optInt("total", 0) ?: 0) - past - exams.size)
            val emptyText = data?.optString("emptyText")?.takeIf { it.isNotEmpty() }
                ?: context.getString(R.string.widget_prossime_prove_vuoto)
            val fontScale = context.resources.configuration.fontScale
            val views = WidgetSupport.responsive(
                WidgetSupport.sizes(manager, widgetId),
                breakpoints,
                fallback,
            ) { size ->
                val plan = WidgetPlan.exams(size.width, size.height, exams.size, fontScale)
                if (plan.mode == WidgetPlan.ExamsMode.SINGLE) {
                    single(context, widgetId, exams, listRoute, emptyText)
                } else {
                    list(context, widgetId, plan, exams, beyond, listRoute, emptyText)
                }
            }
            try {
                manager.updateAppWidget(widgetId, views)
            } catch (e: Exception) {
                // widget tolto nel frattempo, launcher non raggiungibile
            }
            WidgetSupport.scheduleMidnightRefresh(context)
        }

        private fun parse(e: JSONObject, listRoute: String): Exam? {
            val days = WidgetSupport.daysUntil(e.optString("isoDate"))
                ?: e.optInt("days", 0)
            if (days < 0) return null
            // testi limitati: RemoteViews passa per il Binder (oltre ~1 MB
            // TransactionTooLargeException) e il widget ne mostra una riga
            val title = e.optString("title").take(200)
            val time: String? = if (e.isNull("time")) {
                null
            } else {
                e.optString("time").takeIf { it.isNotEmpty() }
            }
            val whenText = listOfNotNull(
                e.optString("kind").takeIf { it.isNotEmpty() },
                e.optString("date").takeIf { it.isNotEmpty() }
                    ?.let { d -> d + (time?.let { " alle $it" } ?: "") },
            ).joinToString(" · ").take(200)
            val route = e.optString("route").takeIf { it.isNotEmpty() } ?: listRoute
            return Exam(title, whenText, days, route)
        }

        /** Etichetta dei giorni: azzurra o rossa (due viste nel layout, così
         *  i colori seguono il tema del sistema anche su Android 8-11). */
        private fun chip(v: RemoteViews, row: Row, days: Int, short: Boolean) {
            val urgent = days <= URGENT_DAYS
            val label = WidgetSupport.daysLabel(days, short)
            v.setViewVisibility(row.days, if (urgent) View.GONE else View.VISIBLE)
            v.setViewVisibility(row.urgent, if (urgent) View.VISIBLE else View.GONE)
            v.setTextViewText(if (urgent) row.urgent else row.days, label)
        }

        private fun list(
            context: Context,
            widgetId: Int,
            plan: WidgetPlan.Exams,
            exams: List<Exam>,
            beyond: Int,
            listRoute: String,
            emptyText: String,
        ): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_prossime_prove)
            v.setOnClickPendingIntent(
                android.R.id.background,
                WidgetSupport.openApp(context, listRoute, widgetId * 10),
            )
            v.setViewVisibility(R.id.exam_header, if (plan.header) View.VISIBLE else View.GONE)
            val shown = minOf(plan.rows, exams.size)
            val pad = WidgetSupport.px(context, if (plan.rich) 7 else 4)
            for ((i, row) in rows.withIndex()) {
                if (i >= shown) {
                    v.setViewVisibility(row.row, View.GONE)
                    continue
                }
                val e = exams[i]
                v.setViewVisibility(row.row, View.VISIBLE)
                v.setViewPadding(
                    row.row,
                    WidgetSupport.px(context, 10),
                    pad,
                    WidgetSupport.px(context, 8),
                    pad,
                )
                v.setTextViewText(row.title, e.title)
                v.setViewVisibility(
                    row.whenText,
                    if (plan.rich && e.whenText.isNotEmpty()) View.VISIBLE else View.GONE,
                )
                v.setTextViewText(row.whenText, e.whenText)
                chip(v, row, e.days, plan.narrow)
                v.setContentDescription(
                    row.row,
                    listOf(e.title, e.whenText, WidgetSupport.daysLabel(e.days))
                        .filter { it.isNotEmpty() }.joinToString(", "),
                )
                v.setOnClickPendingIntent(
                    row.row,
                    WidgetSupport.openApp(context, e.route, widgetId * 10 + i + 1),
                )
            }
            val more = beyond + (exams.size - shown)
            if (plan.header && more > 0) {
                v.setViewVisibility(R.id.exam_more, View.VISIBLE)
                v.setTextViewText(R.id.exam_more, "+$more")
                v.setContentDescription(
                    R.id.exam_more,
                    if (more == 1) "Un'altra prova" else "Altre $more prove",
                )
            } else {
                v.setViewVisibility(R.id.exam_more, View.GONE)
            }
            v.setViewVisibility(R.id.exam_empty, if (exams.isEmpty()) View.VISIBLE else View.GONE)
            if (exams.isEmpty()) v.setTextViewText(R.id.exam_empty, emptyText)
            return v
        }

        private fun single(
            context: Context,
            widgetId: Int,
            exams: List<Exam>,
            listRoute: String,
            emptyText: String,
        ): RemoteViews {
            val v = RemoteViews(context.packageName, R.layout.widget_prossime_prove_uno)
            val e = exams.firstOrNull()
            v.setOnClickPendingIntent(
                android.R.id.background,
                WidgetSupport.openApp(
                    context,
                    e?.route ?: listRoute,
                    widgetId * 10 + (if (e == null) 0 else 1),
                ),
            )
            if (e == null) {
                v.setViewVisibility(R.id.exam_row_1, View.GONE)
                v.setViewVisibility(R.id.exam_empty, View.VISIBLE)
                v.setTextViewText(R.id.exam_empty, emptyText)
                return v
            }
            v.setViewVisibility(R.id.exam_empty, View.GONE)
            v.setViewVisibility(R.id.exam_row_1, View.VISIBLE)
            v.setTextViewText(R.id.exam_title_1, e.title)
            v.setTextViewText(R.id.exam_when_1, e.whenText)
            v.setViewVisibility(
                R.id.exam_when_1,
                if (e.whenText.isEmpty()) View.GONE else View.VISIBLE,
            )
            chip(v, rows[0], e.days, short = false)
            v.setContentDescription(
                android.R.id.background,
                listOf(e.title, e.whenText, WidgetSupport.daysLabel(e.days))
                    .filter { it.isNotEmpty() }.joinToString(", "),
            )
            // titolo un po' più piccolo se lungo (due righe al massimo)
            v.setTextViewTextSize(
                R.id.exam_title_1,
                TypedValue.COMPLEX_UNIT_SP,
                if (e.title.length > 28) 15f else 17f,
            )
            return v
        }
    }
}
