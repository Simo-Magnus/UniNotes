package io.github.simomagnus.universitynotes

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
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
 *   e alle regole di prima. Risponde true solo se il sistema ha davvero
 *   attivato il Non disturbare (letto subito dopo e di nuovo poco più
 *   tardi): altrimenti rimette tutto come prima e risponde false;
 * - `dndActive`: il Non disturbare della sessione è ancora attivo (l'utente
 *   può averlo spento a mano dalla tendina).
 *
 * Filtro e regole di prima restano salvati e un allarme del sistema li
 * ripristina alla fine prevista della sessione anche se l'app nel frattempo
 * è stata chiusa: il telefono non resta mai silenziato per sbaglio.
 * Da Android 15 (l'app ha targetSdk 36) il sistema applica filtro e regole a
 * una modalità propria dell'app («UniNotes» in Impostazioni → Modalità),
 * separata dal Non disturbare dell'utente: alla fine si spegne solo quella
 * (mai il Non disturbare che l'utente aveva già acceso), e se l'utente ha
 * disattivato la modalità dell'app la sessione lo dice invece di fingere.
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

    /**
     * Android 15+ con targetSdk 35+: `setInterruptionFilter` accende e spegne
     * la modalità implicita dell'app, non il Non disturbare globale.
     */
    private fun appMode(ctx: Context): Boolean =
        Build.VERSION.SDK_INT >= 35 && ctx.applicationInfo.targetSdkVersion >= 35

    /** Il telefono è in Non disturbare (qualsiasi filtro tranne «Tutte»). */
    private fun quiet(nm: NotificationManager): Boolean {
        val f = nm.currentInterruptionFilter
        return f != NotificationManager.INTERRUPTION_FILTER_ALL &&
            f != NotificationManager.INTERRUPTION_FILTER_UNKNOWN
    }

    /** Il Non disturbare attivato dall'app per la sessione è ancora acceso. */
    fun isActive(ctx: Context): Boolean {
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_ACTIVE, false) && hasAccess(ctx) &&
            quiet(manager(ctx))
    }

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

    /**
     * Attiva il Non disturbare fino a [untilMs] e passa a [done] se è
     * davvero attivo: false senza permesso, se il sistema rifiuta o se la
     * modalità dell'app è disattivata (Android 15+); in quei casi tutto
     * torna come prima.
     */
    fun enable(ctx: Context, untilMs: Long, done: (Boolean) -> Unit) {
        if (!hasAccess(ctx)) {
            done(false)
            return
        }
        val nm = manager(ctx)
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_ACTIVE, false)) {
            prefs.edit()
                .putBoolean(KEY_ACTIVE, true)
                .putInt(KEY_PREVIOUS, nm.currentInterruptionFilter)
                .putString(KEY_POLICY, encode(nm.notificationPolicy))
                .apply()
        }
        try {
            // regole della sessione; se il sistema le rifiuta resta il
            // filtro «Solo priorità» con le regole dell'utente
            try {
                nm.notificationPolicy = focusPolicy()
            } catch (e: Exception) {
            }
            nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_PRIORITY)
            allowFocusAlerts(nm)
            scheduleRestore(ctx, untilMs)
        } catch (e: SecurityException) {
            disable(ctx)
            done(false)
            return
        }
        if (quiet(nm)) {
            done(true)
            return
        }
        // il sistema può applicare la modalità un attimo dopo: si rilegge
        Handler(Looper.getMainLooper()).postDelayed({
            if (quiet(manager(ctx))) {
                done(true)
            } else {
                disable(ctx)
                done(false)
            }
        }, 400)
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

    /**
     * Torna al filtro di prima (se è stata l'app a cambiarlo). Da Android 15
     * si spegne la modalità dell'app («Tutte»): il Non disturbare che
     * l'utente aveva già acceso è separato e resta com'è.
     */
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
        val appMode = appMode(ctx)
        // Android 15+: le regole salvate sono quelle della modalità dell'app,
        // che restano pronte per la prossima sessione
        if (policy != null && !appMode) {
            try {
                manager(ctx).notificationPolicy = policy
            } catch (e: Exception) {
            }
        }
        try {
            manager(ctx).setInterruptionFilter(
                if (appMode ||
                    previous == NotificationManager.INTERRUPTION_FILTER_UNKNOWN
                ) {
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
