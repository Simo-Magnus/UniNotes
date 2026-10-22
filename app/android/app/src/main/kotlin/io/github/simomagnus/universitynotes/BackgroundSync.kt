package io.github.simomagnus.universitynotes

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.github.simomagnus.universitynotes.widgets.WidgetSupport

/**
 * Sincronizzazione con OneDrive e Google Drive anche con l'app in
 * background, con il JobScheduler del sistema (nessuna libreria in più):
 * un lavoro periodico (al massimo ogni 15 minuti, solo con la rete) che il
 * sistema esegue anche ad app chiusa e dopo il riavvio.
 *
 * Canale `io.github.simomagnus.universitynotes/sincronizzazione`:
 * - da Flutter `schedule` {minutes} pianifica il lavoro, `cancel` lo toglie
 *   (nessun servizio collegato), `busy` → true se il motore senza
 *   interfaccia sta ancora sincronizzando (l'app aperta nel frattempo
 *   aspetta, così i due non lavorano insieme sugli stessi file);
 * - verso Flutter `run`: sincronizza ora e risponde a fine lavoro.
 *
 * Se l'app è aperta (anche in secondo piano) il lavoro chiede la
 * sincronizzazione al suo motore Flutter; altrimenti avvia un motore senza
 * interfaccia sulla funzione Dart `backgroundSyncMain` (lib/main.dart), che
 * sincronizza, aggiorna calendario e notifiche e chiama `done`. Il motore
 * senza interfaccia ha anche i canali del calendario e dei widget (quelli di
 * MainActivity non ci sono): senza, il calendario risulterebbe «senza
 * permesso» dopo ogni giro in background.
 *
 * Il motore senza interfaccia si chiude solo quando Dart ha finito
 * (`done`), non quando il sistema ferma il lavoro (rete persa, tempo
 * scaduto): chiuderlo a metà di una transazione del database lascerebbe la
 * connessione condivisa con l'app bloccata. Se `done` non arriva mai (Dart
 * fermo) si chiude dopo [HARD_LIMIT_MS].
 */
object BackgroundSync {
    const val CHANNEL = "io.github.simomagnus.universitynotes/sincronizzazione"
    const val JOB_ID = 7341

    /** Limite oltre il quale il motore senza interfaccia si chiude comunque. */
    const val HARD_LIMIT_MS = 30 * 60_000L

    /** Canale del motore dell'app aperta (null = app chiusa). */
    var appChannel: MethodChannel? = null
    private var appEngine: FlutterEngine? = null

    /** Motore senza interfaccia al lavoro (null = nessuno). */
    var headless: FlutterEngine? = null

    private val main = Handler(Looper.getMainLooper())
    private var hardLimit: Runnable? = null

    fun attach(context: Context, engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "schedule" -> {
                    val minutes = call.argument<Number>("minutes")?.toLong() ?: 15L
                    result.success(schedule(context, minutes))
                }
                "cancel" -> {
                    cancel(context)
                    result.success(null)
                }
                "busy" -> result.success(headless != null)
                else -> result.notImplemented()
            }
        }
        appChannel = ch
        appEngine = engine
    }

    fun detach(engine: FlutterEngine) {
        if (appEngine === engine) {
            appChannel?.setMethodCallHandler(null)
            appChannel = null
            appEngine = null
        }
    }

    fun schedule(context: Context, minutes: Long): Boolean {
        val js = context.getSystemService(JobScheduler::class.java) ?: return false
        val period = maxOf(minutes, 15L) * 60_000L
        val existing = js.getPendingJob(JOB_ID)
        if (existing != null && existing.intervalMillis == period) return true
        val job = JobInfo.Builder(JOB_ID, ComponentName(context, SyncJobService::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPeriodic(period)
            .setPersisted(true)
            .build()
        return try {
            js.schedule(job) == JobScheduler.RESULT_SUCCESS
        } catch (e: Exception) {
            // es. limite di lavori del sistema raggiunto: si riprova al
            // prossimo avvio dell'app
            false
        }
    }

    fun cancel(context: Context) {
        try {
            context.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
        } catch (e: Exception) {
        }
    }

    /**
     * Avvia il motore senza interfaccia; [onDone] quando Dart ha finito (o
     * non è partito). false se non è stato possibile avviarlo.
     */
    fun startHeadless(context: Context, onDone: () -> Unit): Boolean {
        if (headless != null) return false
        val app = context.applicationContext
        var started: FlutterEngine? = null
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(app)
            loader.ensureInitializationComplete(app, null)
            val engine = FlutterEngine(app)
            started = engine
            headless = engine
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "done" -> {
                            result.success(null)
                            stopHeadless(engine)
                            onDone()
                        }
                        // dal motore senza interfaccia la pianificazione
                        // si aggiorna come dall'app
                        "schedule" -> {
                            val minutes = call.argument<Number>("minutes")?.toLong() ?: 15L
                            result.success(schedule(app, minutes))
                        }
                        "cancel" -> {
                            cancel(app)
                            result.success(null)
                        }
                        "busy" -> result.success(false)
                        else -> result.notImplemented()
                    }
                }
            // calendario del telefono e widget anche qui (vedi sopra)
            val calendar = UniNotesCalendar(app)
            MethodChannel(engine.dartExecutor.binaryMessenger, UniNotesCalendar.CHANNEL)
                .setMethodCallHandler { call, result -> calendar.handle(null, call, result) }
            MethodChannel(engine.dartExecutor.binaryMessenger, WidgetSupport.CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "update" -> {
                            try {
                                WidgetSupport.refreshAll(app)
                            } catch (e: Exception) {
                            }
                            result.success(null)
                        }
                        "takeRoute" -> result.success(null)
                        else -> result.notImplemented()
                    }
                }
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundSyncMain"),
            )
        } catch (e: Exception) {
            started?.let { stopHeadless(it) }
            return false
        }
        val engine = started ?: return false
        val limit = Runnable {
            stopHeadless(engine)
            onDone()
        }
        hardLimit = limit
        main.postDelayed(limit, HARD_LIMIT_MS)
        return true
    }

    private fun stopHeadless(engine: FlutterEngine) {
        main.post {
            if (headless !== engine) return@post
            headless = null
            hardLimit?.let { main.removeCallbacks(it) }
            hardLimit = null
            try {
                engine.destroy()
            } catch (e: Exception) {
            }
        }
    }
}

/** Lavoro periodico della sincronizzazione (vedi [BackgroundSync]). */
class SyncJobService : JobService() {
    private val main = Handler(Looper.getMainLooper())
    private var finished = false

    override fun onStartJob(params: JobParameters): Boolean {
        finished = false
        // il sistema concede circa 10 minuti: il lavoro finisce prima (il
        // motore senza interfaccia può continuare, vedi BackgroundSync)
        main.postDelayed({ finish(params) }, 9 * 60_000L)
        val app = BackgroundSync.appChannel
        if (app != null) {
            try {
                app.invokeMethod("run", null, object : MethodChannel.Result {
                    override fun success(result: Any?) = finish(params)
                    override fun error(code: String, message: String?, details: Any?) =
                        finish(params)
                    override fun notImplemented() = finish(params)
                })
            } catch (e: Exception) {
                main.removeCallbacksAndMessages(null)
                return false
            }
            return true
        }
        // il giro precedente sta ancora lavorando: niente da fare
        if (BackgroundSync.headless != null) {
            main.removeCallbacksAndMessages(null)
            return false
        }
        val started = BackgroundSync.startHeadless(applicationContext) { finish(params) }
        if (!started) main.removeCallbacksAndMessages(null)
        return started
    }

    private fun finish(params: JobParameters) {
        main.post {
            if (finished) return@post
            finished = true
            main.removeCallbacksAndMessages(null)
            try {
                jobFinished(params, false)
            } catch (e: Exception) {
            }
        }
    }

    override fun onStopJob(params: JobParameters): Boolean {
        // rete persa o tempo scaduto: il sistema ferma il lavoro; il motore
        // senza interfaccia finisce da solo (vedi BackgroundSync)
        finished = true
        main.removeCallbacksAndMessages(null)
        return true
    }
}
