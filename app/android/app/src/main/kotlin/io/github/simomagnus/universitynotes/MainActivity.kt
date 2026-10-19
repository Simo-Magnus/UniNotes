package io.github.simomagnus.universitynotes

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
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
 * Quarto canale: «Disinstalla UniNotes» (lib/core/services/app_uninstall.dart):
 * - `uninstall`: richiesta di disinstallazione del sistema per questa app
 *   (ACTION_DELETE, serve REQUEST_DELETE_PACKAGES da Android 9);
 * - `appDetails`: pagina «Informazioni app», se la richiesta non parte.
 *
 * Quinto canale: file arrivati con «Condividi → UniNotes» (IncomingShare.kt):
 * - `take`: file in attesa, una volta sola;
 * - verso Flutter, `available`: sono arrivati file con l'app aperta.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var focusChannel: MethodChannel? = null
    private var uninstallChannel: MethodChannel? = null
    private var incomingChannel: MethodChannel? = null
    private var liveSpeech: LiveSpeech? = null
    private var pendingRoute: String? = null

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
        // Disinstallazione dall'app.
        uninstallChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UNINSTALL_CHANNEL,
        ).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "uninstall" -> result.success(
                        startSafely(
                            Intent(Intent.ACTION_DELETE, Uri.parse("package:$packageName")),
                        ),
                    )
                    "appDetails" -> result.success(
                        startSafely(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName"),
                            ),
                        ),
                    )
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** Avvia [intent] in un task nuovo; false se nessuna app lo gestisce. */
    private fun startSafely(intent: Intent): Boolean = try {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        true
    } catch (e: Exception) {
        false
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
        uninstallChannel?.setMethodCallHandler(null)
        uninstallChannel = null
        incomingChannel?.setMethodCallHandler(null)
        incomingChannel = null
        IncomingShare.onAvailable = null
        liveSpeech?.dispose()
        liveSpeech = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

private const val UNINSTALL_CHANNEL = "io.github.simomagnus.universitynotes/disinstalla"
