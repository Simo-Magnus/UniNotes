package io.github.simomagnus.universitynotes

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings

/**
 * «Non disturbare» del telefono durante una sessione Focus (canale
 * `io.github.simomagnus.universitynotes/focus`, vedi
 * lib/features/study/focus/focus_system.dart):
 * - `dndAccess`: l'utente ha dato a UniNotes l'«Accesso a Non disturbare»
 *   (ACCESS_NOTIFICATION_POLICY);
 * - `openDndSettings`: apre la pagina del sistema dove darlo;
 * - `setDnd {on, untilMs}`: attiva il filtro «Solo priorità» con le regole
 *   della modalità Focus (vedi [focusPolicy]: passano solo sveglie, audio
 *   dei contenuti, chiamate ripetute e chiamate dai contatti preferiti;
 *   tutte le altre notifiche e i loro suoni sono bloccati) o torna al filtro
 *   e alle regole di prima.
 *
 * Filtro e regole di prima restano salvati e un allarme del sistema li
 * ripristina alla fine prevista della sessione anche se l'app nel frattempo
 * è stata chiusa: il telefono non resta mai silenziato per sbaglio.
 * Da Android 15 (app con targetSdk 35) il sistema applica filtro e regole a
 * una regola «automatica» propria dell'app, senza toccare il Non disturbare
 * dell'utente: il comportamento per chi usa il telefono è lo stesso.
 */
object FocusDnd {
    const val CHANNEL = "io.github.simomagnus.universitynotes/focus"
    private const val PREFS = "uninotes_focus_dnd"
    private const val KEY_ACTIVE = "attivo"
    private const val KEY_PREVIOUS = "filtro_precedente"
    private const val KEY_POLICY = "regole_precedenti"
    private const val REQUEST = 4207

    /** Canale degli avvisi Focus (lib/core/reminders/notification_plan.dart). */
    private const val FOCUS_ALERTS_CHANNEL = "focus_avvisi"

    private fun manager(ctx: Context) =
        ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    fun hasAccess(ctx: Context): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            manager(ctx).isNotificationPolicyAccessGranted

    fun openSettings(ctx: Context) {
        val intent = Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            ctx.startActivity(intent)
        } catch (e: Exception) {
            ctx.startActivity(
                Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /** Attiva il Non disturbare fino a [untilMs]; false senza permesso. */
    fun enable(ctx: Context, untilMs: Long): Boolean {
        if (!hasAccess(ctx)) return false
        val nm = manager(ctx)
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_ACTIVE, false)) {
            prefs.edit()
                .putBoolean(KEY_ACTIVE, true)
                .putInt(KEY_PREVIOUS, nm.currentInterruptionFilter)
                .putString(KEY_POLICY, encode(nm.notificationPolicy))
                .apply()
        }
        return try {
            // regole della sessione; se il sistema le rifiuta resta il
            // filtro «Solo priorità» con le regole dell'utente
            try {
                nm.notificationPolicy = focusPolicy()
            } catch (e: Exception) {
            }
            nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_PRIORITY)
            allowFocusAlerts(nm)
            scheduleRestore(ctx, untilMs)
            true
        } catch (e: SecurityException) {
            prefs.edit().clear().apply()
            false
        }
    }

    /**
     * Canale `focus_avvisi` (inizio e fine pausa, fine sessione): deve
     * superare il Non disturbare. Il plugin delle notifiche lo crea con
     * `bypassDnd` solo se l'accesso c'era già; se l'accesso è arrivato dopo,
     * si aggiorna qui (il sistema lo accetta finché l'utente non ha cambiato
     * a mano le impostazioni del canale).
     */
    private fun allowFocusAlerts(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val ch = nm.getNotificationChannel(FOCUS_ALERTS_CHANNEL) ?: return
            if (ch.canBypassDnd()) return
            ch.setBypassDnd(true)
            nm.createNotificationChannel(ch)
        } catch (e: Exception) {
        }
    }

    /** Torna al filtro di prima (se è stata l'app a cambiarlo). */
    fun disable(ctx: Context) {
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        cancelRestore(ctx)
        if (!prefs.getBoolean(KEY_ACTIVE, false)) return
        val previous = prefs.getInt(
            KEY_PREVIOUS,
            NotificationManager.INTERRUPTION_FILTER_ALL,
        )
        val policy = decode(prefs.getString(KEY_POLICY, null))
        prefs.edit().clear().apply()
        if (!hasAccess(ctx)) return
        if (policy != null) {
            try {
                manager(ctx).notificationPolicy = policy
            } catch (e: Exception) {
            }
        }
        try {
            manager(ctx).setInterruptionFilter(
                if (previous == NotificationManager.INTERRUPTION_FILTER_UNKNOWN) {
                    NotificationManager.INTERRUPTION_FILTER_ALL
                } else {
                    previous
                },
            )
        } catch (e: SecurityException) {
        }
    }

    /**
     * Regole della modalità Focus, come un «Non disturbare» rigido: passano
     * solo le cose vitali (sveglie, chiamate ripetute della stessa persona
     * entro 15 minuti, chiamate dai contatti preferiti) e l'audio dei
     * contenuti che l'utente avvia (video, musica, una lezione registrata).
     * Messaggi, conversazioni, promemoria ed eventi delle altre app restano
     * fermi: niente suono, niente vibrazione, niente comparsa sullo schermo;
     * restano nella tendina per dopo.
     */
    private fun focusPolicy(): NotificationManager.Policy {
        var categories = NotificationManager.Policy.PRIORITY_CATEGORY_CALLS or
            NotificationManager.Policy.PRIORITY_CATEGORY_REPEAT_CALLERS
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            categories = categories or
                NotificationManager.Policy.PRIORITY_CATEGORY_ALARMS or
                NotificationManager.Policy.PRIORITY_CATEGORY_MEDIA
            val visual = NotificationManager.Policy.SUPPRESSED_EFFECT_PEEK or
                NotificationManager.Policy.SUPPRESSED_EFFECT_FULL_SCREEN_INTENT or
                NotificationManager.Policy.SUPPRESSED_EFFECT_LIGHTS or
                NotificationManager.Policy.SUPPRESSED_EFFECT_AMBIENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                return NotificationManager.Policy(
                    categories,
                    NotificationManager.Policy.PRIORITY_SENDERS_STARRED,
                    NotificationManager.Policy.PRIORITY_SENDERS_STARRED,
                    visual,
                    NotificationManager.Policy.CONVERSATION_SENDERS_NONE,
                )
            }
            return NotificationManager.Policy(
                categories,
                NotificationManager.Policy.PRIORITY_SENDERS_STARRED,
                NotificationManager.Policy.PRIORITY_SENDERS_STARRED,
                visual,
            )
        }
        // Android 7–8: le sveglie passano sempre con «Solo priorità»
        return NotificationManager.Policy(
            categories,
            NotificationManager.Policy.PRIORITY_SENDERS_STARRED,
            NotificationManager.Policy.PRIORITY_SENDERS_STARRED,
        )
    }

    /** Regole come testo "categorie;chiamate;messaggi;effetti;conversazioni". */
    private fun encode(p: NotificationManager.Policy?): String? {
        if (p == null) return null
        val effects = p.suppressedVisualEffects
        val conversations = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            p.priorityConversationSenders
        } else {
            -1
        }
        return listOf(
            p.priorityCategories,
            p.priorityCallSenders,
            p.priorityMessageSenders,
            effects,
            conversations,
        ).joinToString(";")
    }

    private fun decode(v: String?): NotificationManager.Policy? {
        val n = v?.split(";")?.mapNotNull { it.toIntOrNull() } ?: return null
        if (n.size < 5) return null
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && n[4] >= 0 ->
                NotificationManager.Policy(n[0], n[1], n[2], n[3], n[4])
            else -> NotificationManager.Policy(n[0], n[1], n[2], n[3])
        }
    }

    private fun restoreIntent(ctx: Context): PendingIntent =
        PendingIntent.getBroadcast(
            ctx,
            REQUEST,
            Intent(ctx, FocusDndReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /**
     * Allarme inesatto (niente SCHEDULE_EXACT_ALARM): qualche minuto di
     * ritardo nel ripristino va bene.
     */
    private fun scheduleRestore(ctx: Context, untilMs: Long) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val at = maxOf(untilMs, System.currentTimeMillis() + 60_000L)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, restoreIntent(ctx))
        } else {
            am.set(AlarmManager.RTC_WAKEUP, at, restoreIntent(ctx))
        }
    }

    private fun cancelRestore(ctx: Context) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.cancel(restoreIntent(ctx))
    }
}

/** Fine prevista della sessione: il Non disturbare torna come prima. */
class FocusDndReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        FocusDnd.disable(context.applicationContext)
    }
}
