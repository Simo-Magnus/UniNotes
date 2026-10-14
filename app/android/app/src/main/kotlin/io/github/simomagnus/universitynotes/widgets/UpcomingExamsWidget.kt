package io.github.simomagnus.universitynotes.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import io.github.simomagnus.universitynotes.R

/**
 * Widget «Prossime prove»: le prossime 3 prove con i giorni mancanti
 * (ricalcolati a ogni aggiornamento, almeno due volte al giorno). Tocco su
 * una prova → l'app apre la sua scheda; tocco altrove → pagina Esami.
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

    private data class Row(val row: Int, val title: Int, val whenText: Int, val days: Int)

    companion object {
        private val rows = arrayOf(
            Row(R.id.exam_row_1, R.id.exam_title_1, R.id.exam_when_1, R.id.exam_days_1),
            Row(R.id.exam_row_2, R.id.exam_title_2, R.id.exam_when_2, R.id.exam_days_2),
            Row(R.id.exam_row_3, R.id.exam_title_3, R.id.exam_when_3, R.id.exam_days_3),
        )

        fun render(context: Context, manager: AppWidgetManager, widgetId: Int) {
            val views = RemoteViews(context.packageName, R.layout.widget_prossime_prove)
            val data = WidgetSupport.data(context)
            val exams = data?.optJSONArray("exams")
            val listRoute = data?.optString("route")?.takeIf { it.isNotEmpty() }
                ?: "sezione:Esami"
            views.setOnClickPendingIntent(
                R.id.widget_root,
                WidgetSupport.openApp(context, listRoute, widgetId * 10),
            )
            var shown = 0
            for ((i, row) in rows.withIndex()) {
                val exam = exams?.optJSONObject(i)
                if (exam == null) {
                    views.setViewVisibility(row.row, View.GONE)
                    continue
                }
                // prova già passata (dati non ancora riscritti dall'app)
                val days = WidgetSupport.daysUntil(exam.optString("isoDate"))
                    ?: exam.optInt("days", 0)
                if (days < 0) {
                    views.setViewVisibility(row.row, View.GONE)
                    continue
                }
                shown++
                views.setViewVisibility(row.row, View.VISIBLE)
                views.setTextViewText(row.title, exam.optString("title"))
                val time: String? = if (exam.isNull("time")) {
                    null
                } else {
                    exam.optString("time").takeIf { it.isNotEmpty() }
                }
                val whenText = listOfNotNull(
                    exam.optString("kind").takeIf { it.isNotEmpty() },
                    exam.optString("date") + (time?.let { " alle $it" } ?: ""),
                ).joinToString(" · ")
                views.setTextViewText(row.whenText, whenText)
                views.setTextViewText(row.days, WidgetSupport.daysLabel(days))
                val route = exam.optString("route").takeIf { it.isNotEmpty() }
                    ?: listRoute
                views.setOnClickPendingIntent(
                    row.row,
                    WidgetSupport.openApp(context, route, widgetId * 10 + i + 1),
                )
            }
            views.setViewVisibility(
                R.id.exam_empty,
                if (shown == 0) View.VISIBLE else View.GONE,
            )
            if (shown == 0) {
                views.setTextViewText(
                    R.id.exam_empty,
                    data?.optString("emptyText")?.takeIf { it.isNotEmpty() }
                        ?: context.getString(R.string.widget_prossime_prove_vuoto),
                )
            }
            manager.updateAppWidget(widgetId, views)
        }
    }
}
