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

/**
 * Sincronizzazione con OneDrive e Google Drive anche con l'app in
 * background, con il JobScheduler del sistema (nessuna libreria in più):
 * un lavoro periodico (al massimo ogni 15 minuti, solo con la rete) che il
 * sistema esegue anche ad app chiusa e dopo il riavvio.
 *
 * Canale `io.github.simomagnus.universitynotes/sincronizzazione`:
 * - da Flutter `schedule` {minutes} pianifica il lavoro, `cancel` lo toglie
 *   (nessun servizio collegato);
 * - verso Flutter `run`: sincronizza ora e risponde a fine lavoro.
 *
 * Se l'app è aperta (anche in secondo piano) il lavoro chiede la
 * sincronizzazione al suo motore Flutter; altrimenti avvia un motore senza
 * interfaccia sulla funzione Dart `backgroundSyncMain` (lib/main.dart), che
 * sincronizza, aggiorna calendario e notifiche e chiama `done`.
 */
object BackgroundSync {
    const val CHANNEL = "io.github.simomagnus.universitynotes/sincronizzazione"
    const val JOB_ID = 7341

    /** Canale del motore dell'app aperta (null = app chiusa). */
    var appChannel: MethodChannel? = null
    private var appEngine: FlutterEngine? = null

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
        return js.schedule(job) == JobScheduler.RESULT_SUCCESS
    }

    fun cancel(context: Context) {
        context.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
    }
}

/** Lavoro periodico della sincronizzazione (vedi [BackgroundSync]). */
class SyncJobService : JobService() {
    private var headless: FlutterEngine? = null
    private val main = Handler(Looper.getMainLooper())
    private var finished = false

    override fun onStartJob(params: JobParameters): Boolean {
        finished = false
        // al massimo 9 minuti (il sistema ne concede circa 10)
        main.postDelayed({ finish(params, false) }, 9 * 60_000L)
        val app = BackgroundSync.appChannel
        if (app != null) {
            app.invokeMethod("run", null, object : MethodChannel.Result {
                override fun success(result: Any?) = finish(params, false)
                override fun error(code: String, message: String?, details: Any?) =
                    finish(params, false)
                override fun notImplemented() = finish(params, false)
            })
            return true
        }
        return try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            val engine = FlutterEngine(applicationContext)
            headless = engine
            MethodChannel(engine.dartExecutor.binaryMessenger, BackgroundSync.CHANNEL)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "done" -> {
                            result.success(null)
                            finish(params, false)
                        }
                        // dal motore senza interfaccia la pianificazione
                        // si aggiorna come dall'app
                        "schedule" -> {
                            val minutes = call.argument<Number>("minutes")?.toLong() ?: 15L
                            result.success(BackgroundSync.schedule(applicationContext, minutes))
                        }
                        "cancel" -> {
                            BackgroundSync.cancel(applicationContext)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundSyncMain"),
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun finish(params: JobParameters, reschedule: Boolean) {
        main.post {
            if (finished) return@post
            finished = true
            main.removeCallbacksAndMessages(null)
            headless?.destroy()
            headless = null
            jobFinished(params, reschedule)
        }
    }

    override fun onStopJob(params: JobParameters): Boolean {
        finished = true
        main.removeCallbacksAndMessages(null)
        headless?.destroy()
        headless = null
        return true
    }
}
