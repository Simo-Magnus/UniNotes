package io.github.simomagnus.universitynotes

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.simomagnus.universitynotes.widgets.RecordWidget
import io.github.simomagnus.universitynotes.widgets.WidgetSupport

/**
 * Notifica «Registrazione in corso» con i pulsanti sempre visibili (canale
 * `io.github.simomagnus.universitynotes/registrazione`, vedi
 * lib/features/notes/recorder/background_controls.dart).
 *
 * Il servizio in primo piano è di flutter_foreground_task, ma la sua
 * notifica usa il modello standard di Android: i pulsanti («azioni») si
 * vedono solo espandendo la notifica, e con il canale a importanza bassa
 * (il predefinito del pacchetto) la notifica finiva fra quelle silenziose,
 * sempre compressa e nascosta nella schermata di blocco. Qui la notifica
 * dello stesso servizio (stesso id) viene sostituita da una con un layout
 * proprio (layout/notifica_registrazione.xml): titolo, corso, cronometro
 * del sistema (niente aggiornamenti ogni secondo) e i pulsanti «Pausa» o
 * «Riprendi» e «Salva» già nella vista compressa, anche a schermo bloccato.
 *
 * - `show {id, title, course, elapsedMs, paused, primary, primaryId, save}`:
 *   mostra o aggiorna la notifica;
 * - `stopped`: registrazione finita (il widget torna fermo);
 * - verso Flutter, `command` con l'id del pulsante premuto (`pausa`,
 *   `riprendi`, `salva`, `elimina` dal widget dopo la conferma) o
 *   `nascosta` se l'utente l'ha tolta dalla tendina (Android 14+ lo
 *   permette anche ai servizi in primo piano: l'app la rimette finché
 *   registra).
 * Ogni `show` passa lo stesso stato al widget «Registra lezione»
 * (widgets/RecordWidget.kt).
 * Il tocco sul corpo apre l'app nel registratore (percorso `registra`,
 * come il widget).
 */
object RecordingNotification {
    const val CHANNEL = "io.github.simomagnus.universitynotes/registrazione"

    /** Canale delle notifiche: importanza predefinita ma senza suono né
     *  vibrazione (con «bassa» Android la nasconde a schermo bloccato). */
    const val NOTIFICATION_CHANNEL = "registrazione_in_corso"

    /** Canale delle versioni precedenti (importanza bassa): si elimina. */
    private const val OLD_NOTIFICATION_CHANNEL = "registrazione_lezione"

    private const val ACTION = "io.github.simomagnus.universitynotes.REGISTRAZIONE"
    const val EXTRA_COMMAND = "comando"
    private const val ROUTE = "registra"

    // codici delle PendingIntent (diversi da quelli dei widget)
    private const val REQ_PRIMARY = 7101
    private const val REQ_SAVE = 7102
    private const val REQ_DISMISS = 7103
    private const val REQ_OPEN = 7104

    /** Comandi verso Flutter (null se l'app non ha un motore attivo). */
    var onCommand: ((String) -> Unit)? = null

    /** Comandi validi verso Flutter (pulsanti di notifica e widget). */
    val COMMANDS = setOf("pausa", "riprendi", "salva", "nascosta")

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "show" -> result.success(
                try {
                    // stesso stato al widget «Registra lezione» (un'unica
                    // fonte: la notifica), anche se la notifica non si può
                    // mostrare e resta quella di riserva
                    try {
                        RecordWidget.setLive(
                            context,
                            RecordWidget.Live(
                                paused = call.argument<Boolean>("paused") ?: false,
                                elapsedMs = maxOf(0L, call.argument<Number>("elapsedMs")?.toLong() ?: 0L),
                                at = SystemClock.elapsedRealtime(),
                                course = call.argument<String>("course") ?: "",
                            ),
                        )
                    } catch (e: Exception) {
                    }
                    show(
                        context,
                        // Number: un int di Dart arriva come Int o Long
                        id = call.argument<Number>("id")?.toInt() ?: 0,
                        title = call.argument<String>("title") ?: "",
                        course = call.argument<String>("course") ?: "",
                        elapsedMs = call.argument<Number>("elapsedMs")?.toLong() ?: 0L,
                        paused = call.argument<Boolean>("paused") ?: false,
                        primary = call.argument<String>("primary") ?: "",
                        primaryId = call.argument<String>("primaryId") ?: "",
                        save = call.argument<String>("save") ?: "",
                    )
                    true
                } catch (e: Exception) {
                    false
                },
            )
            // registrazione finita (salvata, eliminata, non partita): il
            // widget torna fermo
            "stopped" -> {
                try {
                    RecordWidget.setLive(context, null)
                } catch (e: Exception) {
                }
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(NOTIFICATION_CHANNEL) == null) {
            val ch = NotificationChannel(
                NOTIFICATION_CHANNEL,
                "Registrazione lezione",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "Notifica mostrata mentre registri una lezione, con il " +
                    "tempo e i pulsanti Pausa e Salva."
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm.createNotificationChannel(ch)
        }
        // il canale vecchio (importanza bassa) non serve più; se un servizio
        // lo sta ancora usando il sistema rifiuta: si riprova la volta dopo
        if (nm.getNotificationChannel(OLD_NOTIFICATION_CHANNEL) != null) {
            try {
                nm.deleteNotificationChannel(OLD_NOTIFICATION_CHANNEL)
            } catch (e: Exception) {
            }
        }
    }

    private fun broadcast(context: Context, command: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, RecordingCommandReceiver::class.java).apply {
            action = ACTION
            putExtra(EXTRA_COMMAND, command)
        }
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun show(
        context: Context,
        id: Int,
        title: String,
        course: String,
        elapsedMs: Long,
        paused: Boolean,
        primary: String,
        primaryId: String,
        save: String,
    ) {
        ensureChannel(context)
        val views = RemoteViews(context.packageName, R.layout.notifica_registrazione).apply {
            setTextViewText(R.id.notifica_titolo, title)
            setTextViewText(R.id.notifica_corso, course)
            setViewVisibility(R.id.notifica_corso, if (course.isEmpty()) View.GONE else View.VISIBLE)
            setViewVisibility(R.id.notifica_separatore, if (course.isEmpty()) View.GONE else View.VISIBLE)
            // cronometro del sistema: parte da [elapsedMs] e scorre da solo,
            // fermo (con il tempo raggiunto) in pausa
            setChronometer(
                R.id.notifica_tempo,
                SystemClock.elapsedRealtime() - elapsedMs,
                null,
                !paused,
            )
            setTextViewText(R.id.notifica_principale, primary)
            setContentDescription(R.id.notifica_principale, primary)
            setOnClickPendingIntent(R.id.notifica_principale, broadcast(context, primaryId, REQ_PRIMARY))
            setTextViewText(R.id.notifica_salva, save)
            setContentDescription(R.id.notifica_salva, save)
            setOnClickPendingIntent(R.id.notifica_salva, broadcast(context, "salva", REQ_SAVE))
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(Notification.PRIORITY_DEFAULT)
                .setSound(null).setVibrate(longArrayOf(0L))
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_uninotes)
            .setColor(Color.rgb(0x0F, 0x72, 0xF2))
            .setContentTitle(title)
            .setContentText(course)
            .setCustomContentView(views)
            .setStyle(Notification.DecoratedCustomViewStyle())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(WidgetSupport.openApp(context, ROUTE, REQ_OPEN))
            .setDeleteIntent(broadcast(context, "nascosta", REQ_DISMISS))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(id, builder.build())
    }
}

/**
 * Pulsanti e chiusura della notifica della registrazione e comandi del
 * widget «Registra lezione» (RecordWidget.kt). Non esportato: lo
 * raggiungono solo le PendingIntent immutabili dell'app. I comandi sono
 * validati: gli altri si ignorano.
 */
class RecordingCommandReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val command = try {
            intent.getStringExtra(RecordingNotification.EXTRA_COMMAND)
        } catch (e: Exception) {
            null
        } ?: return
        when (command) {
            RecordWidget.CMD_DELETE -> RecordWidget.onDeleteTap(context)
            RecordWidget.CMD_VERIFY -> RecordWidget.verify(context)
            in RecordingNotification.COMMANDS -> {
                val forward = RecordingNotification.onCommand
                if (forward == null) {
                    // l'app non c'è più (chiusa dal sistema): niente da
                    // comandare, il widget torna fermo
                    RecordWidget.stale(context)
                    return
                }
                forward(command)
            }
        }
    }
}
