package io.github.simomagnus.universitynotes

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.github.simomagnus.universitynotes.widgets.WidgetSupport

/**
 * Attività di Flutter con il canale dei widget della schermata Home:
 * - `update`: ridisegna i widget con i dati appena scritti dall'app;
 * - `takeRoute`: schermata chiesta dal widget che ha aperto l'app
 *   (es. `registra`, `prova:12`), una sola volta;
 * - verso Flutter, `route`: tocco su un widget con l'app già aperta.
 *
 * Secondo canale: Non disturbare del telefono durante le sessioni Focus
 * (FocusDnd.kt): `dndAccess`, `openDndSettings`, `setDnd`, `dndActive`.
 *
 * Terzo canale: trascrizione istantanea delle lezioni con il riconoscimento
 * vocale del sistema (LiveSpeech.kt).
 *
 * Quarto canale: file arrivati con «Condividi → UniNotes» (IncomingShare.kt):
 * - `take`: file in attesa, una volta sola;
 * - verso Flutter, `available`: sono arrivati file con l'app aperta.
 *
 * Quinto canale: notifica della registrazione con i pulsanti sempre
 * visibili (RecordingNotification.kt): `show`; verso Flutter, `command`.
 *
 * Sesto canale: prove nel calendario del telefono (UniNotesCalendar.kt).
 *
 * Settimo canale: sincronizzazione con OneDrive e Google Drive in background
 * (BackgroundSync.kt, JobScheduler del sistema).
 *
 * Ottavo canale: «Apri con…» con la scelta dell'app (OpenWith.kt):
 * `openWith` {path}.
 *
 * L'app non ha un tasto per disinstallarsi: lo fa il sistema.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var focusChannel: MethodChannel? = null
    private var incomingChannel: MethodChannel? = null
    private var recordingChannel: MethodChannel? = null
    private var liveSpeech: LiveSpeech? = null
    private var calendar: UniNotesCalendar? = null
    private var calendarChannel: MethodChannel? = null
    private var openWithChannel: MethodChannel? = null
    private var pendingRoute: String? = null

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        calendar?.onPermissionResult(requestCode)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingRoute = WidgetSupport.routeOf(intent)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WidgetSupport.CHANNEL,
        )
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    WidgetSupport.refreshAll(applicationContext)
                    result.success(null)
                }
                "takeRoute" -> {
                    result.success(pendingRoute)
                    pendingRoute = null
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
        // Non disturbare durante le sessioni Focus (vedi FocusDnd.kt).
        focusChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FocusDnd.CHANNEL,
        ).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "dndAccess" -> result.success(FocusDnd.hasAccess(applicationContext))
                    "dndActive" -> result.success(FocusDnd.isActive(applicationContext))
                    "openDndSettings" -> {
                        FocusDnd.openSettings(this)
                        result.success(null)
                    }
                    "setDnd" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        if (on) {
                            val until = call.argument<Number>("untilMs")?.toLong()
                                ?: (System.currentTimeMillis() + 60 * 60_000L)
                            FocusDnd.enable(applicationContext, until) { ok ->
                                result.success(ok)
                            }
                        } else {
                            FocusDnd.disable(applicationContext)
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // Trascrizione istantanea (vedi LiveSpeech.kt).
        registerLiveSpeech(flutterEngine)
        // File condivisi con l'app (vedi IncomingShare.kt).
        incomingChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            IncomingShare.CHANNEL,
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                if (call.method == "take") result.success(IncomingShare.take())
                else result.notImplemented()
            }
            IncomingShare.onAvailable = { ch.invokeMethod("available", null) }
        }
        // Notifica della registrazione (vedi RecordingNotification.kt).
        recordingChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            RecordingNotification.CHANNEL,
        ).also { ch ->
            ch.setMethodCallHandler { call, result ->
                RecordingNotification.handle(applicationContext, call, result)
            }
            RecordingNotification.onCommand = { ch.invokeMethod("command", it) }
        }
        // Prove nel calendario del telefono (vedi UniNotesCalendar.kt).
        val cal = UniNotesCalendar(applicationContext)
        calendar = cal
        calendarChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UniNotesCalendar.CHANNEL,
        ).also {
            it.setMethodCallHandler { call, result -> cal.handle(this, call, result) }
        }
        // Sincronizzazione con OneDrive e Google Drive anche con l'app in
        // background (vedi BackgroundSync.kt).
        BackgroundSync.attach(applicationContext, flutterEngine)
        // «Apri con…»: scelta dell'app (vedi OpenWith.kt).
        openWithChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            OpenWith.CHANNEL,
        ).also {
            it.setMethodCallHandler { call, result ->
                val path = call.argument<String>("path")
                if (call.method == "openWith" && path != null) {
                    result.success(OpenWith.open(this, path))
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    private fun registerLiveSpeech(flutterEngine: FlutterEngine) {
        val ch = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LiveSpeech.CHANNEL,
        )
        val speech = LiveSpeech(applicationContext, ch)
        ch.setMethodCallHandler { call, result -> speech.handle(call, result) }
        liveSpeech = speech
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val route = WidgetSupport.routeOf(intent) ?: return
        val ch = channel
        if (ch != null) {
            ch.invokeMethod("route", route)
        } else {
            pendingRoute = route
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        focusChannel?.setMethodCallHandler(null)
        focusChannel = null
        incomingChannel?.setMethodCallHandler(null)
        incomingChannel = null
        IncomingShare.onAvailable = null
        recordingChannel?.setMethodCallHandler(null)
        recordingChannel = null
        RecordingNotification.onCommand = null
        liveSpeech?.dispose()
        liveSpeech = null
        calendarChannel?.setMethodCallHandler(null)
        calendarChannel = null
        calendar = null
        openWithChannel?.setMethodCallHandler(null)
        openWithChannel = null
        BackgroundSync.detach(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
