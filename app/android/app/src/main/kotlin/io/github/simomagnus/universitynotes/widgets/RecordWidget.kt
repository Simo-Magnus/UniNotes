package io.github.simomagnus.universitynotes.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import io.github.simomagnus.universitynotes.R

/**
 * Widget «Registra lezione» (1×1): apre l'app direttamente nel
 * registratore delle lezioni.
 */
class RecordWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) render(context, appWidgetManager, id)
    }

    companion object {
        fun render(context: Context, manager: AppWidgetManager, widgetId: Int) {
            val views = RemoteViews(context.packageName, R.layout.widget_registra)
            views.setOnClickPendingIntent(
                R.id.widget_record_root,
                WidgetSupport.openApp(context, "registra", 1_000_000 + widgetId),
            )
            manager.updateAppWidget(widgetId, views)
        }
    }
}
