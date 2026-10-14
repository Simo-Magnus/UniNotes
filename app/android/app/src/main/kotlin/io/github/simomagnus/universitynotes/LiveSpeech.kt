package io.github.simomagnus.universitynotes

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.OutputStream
import java.util.ArrayDeque
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Trascrizione istantanea durante la registrazione delle lezioni (canale
 * "io.github.simomagnus.universitynotes/speech", vedi
 * lib/features/notes/recorder/system_speech.dart), come la digitazione
 * vocale di Google: SpeechRecognizer del sistema con i risultati parziali
 * (il testo si aggiorna mentre si parla) e, dove c'è, il riconoscimento sul
 * dispositivo (createOnDeviceSpeechRecognizer, Android 12+).
 *
 * Il riconoscitore NON apre il microfono, che resta alla registrazione: da
 * Android 13 (API 33) riceve l'audio con EXTRA_AUDIO_SOURCE, una pipe in cui
 * l'app scrive il PCM 16 bit mono a 16 kHz che sta già registrando
 * ("feed"). Prima di Android 13 non c'è modo di passargli l'audio: il
 * riconoscitore aprirebbe il microfono in concorrenza con la registrazione
 * (e su molti telefoni la zittirebbe), quindi "support" risponde «non
 * disponibile» e l'app usa Whisper a pezzi.
 *
 * Con la sessione segmentata (EXTRA_SEGMENTED_SESSION) il riconoscitore
 * manda i segmenti finali finché la pipe resta aperta; dove non è
 * supportata, a ogni fine frase si apre una nuova sessione (l'audio che
 * arriva intanto aspetta in coda, niente si perde). Errori ripetuti →
 * "error" con fatal = true e l'app passa a Whisper; la registrazione non si
 * ferma mai.
 *
 * Verso Flutter (con "session"): "partial" {text}, "result" {text},
 * "error" {message, fatal}, "ended".
 */
class LiveSpeech(private val context: Context, private val channel: MethodChannel) {
    companion object {
        const val CHANNEL = "io.github.simomagnus.universitynotes/speech"

        /** Audio tenuto in coda fra una sessione e l'altra (~8 s a 16 kHz). */
        private const val MAX_PENDING_BYTES = 16000 * 2 * 8
    }

    private val main = Handler(Looper.getMainLooper())
    private val io: ExecutorService = Executors.newSingleThreadExecutor()
    private val lock = Any()

    private var recognizer: SpeechRecognizer? = null
    private var onDevice = false
    private var session = 0
    private var locale = "it-IT"
    private var sampleRate = 16000
    private var running = false
    private var stopping = false
    private var lastPartial = ""
    private var errors = 0
    private var lastErrorAt = 0L

    /** Lato di lettura della pipe della sessione in corso (al riconoscitore). */
    private var readEnd: ParcelFileDescriptor? = null

    // usati solo nel thread [io]
    private var out: OutputStream? = null
    private val pending = ArrayDeque<ByteArray>()
    private var pendingBytes = 0

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "support" -> result.success(support())
            "start" -> {
                val loc = call.argument<String>("locale") ?: "it-IT"
                val rate = call.argument<Number>("sampleRate")?.toInt() ?: 16000
                val ses = call.argument<Number>("session")?.toInt() ?: (session + 1)
                result.success(start(loc, rate, ses))
            }
            "feed" -> {
                val bytes = call.arguments as? ByteArray
                if (bytes != null) feed(bytes)
                result.success(null)
            }
            // l'audio in pausa semplicemente non arriva
            "pause", "resume" -> result.success(null)
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun support(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return mapOf("available" to false, "reason" to "android<13")
        }
        val onDev = try {
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        } catch (e: Exception) {
            false
        }
        val any = onDev || try {
            SpeechRecognizer.isRecognitionAvailable(context)
        } catch (e: Exception) {
            false
        }
        return mapOf(
            "available" to any,
            "onDevice" to onDev,
            "feedsAudio" to true,
            "engine" to "android",
            "reason" to if (any) null else "no-service",
        )
    }

    private fun start(loc: String, rate: Int, ses: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        destroyNow()
        session = ses
        locale = loc
        sampleRate = rate
        errors = 0
        onDevice = try {
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        } catch (e: Exception) {
            false
        }
        val r = create(onDevice) ?: (if (onDevice) create(false) else null) ?: return false
        if (recognizer == null) recognizer = r
        running = true
        stopping = false
        startSession()
        return true
    }

    private fun create(onDev: Boolean): SpeechRecognizer? = try {
        val r = if (onDev && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            SpeechRecognizer.createSpeechRecognizer(context)
        }
        r.setRecognitionListener(listener)
        onDevice = onDev
        recognizer = r
        r
    } catch (e: Exception) {
        null
    }

    /** Nuova sessione di riconoscimento con una pipe nuova. */
    private fun startSession() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val r = recognizer ?: return
        val pipe = try {
            ParcelFileDescriptor.createPipe()
        } catch (e: IOException) {
            fail("Pipe audio non disponibile: ${e.message}", fatal = true)
            return
        }
        closeQuietly(readEnd)
        readEnd = pipe[0]
        val write = ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])
        io.execute {
            synchronized(lock) {
                closeQuietly(out)
                out = write
                // l'audio arrivato fra due sessioni
                while (pending.isNotEmpty()) {
                    val b = pending.removeFirst()
                    if (!writeOut(b)) break
                }
                pending.clear()
                pendingBytes = 0
            }
        }
        lastPartial = ""
        try {
            r.startListening(intentFor(pipe[0]))
        } catch (e: Exception) {
            onRecognizerError(SpeechRecognizer.ERROR_CLIENT)
        }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun intentFor(read: ParcelFileDescriptor): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            // punteggiatura e maiuscole, dove il riconoscitore le offre
            putExtra(
                RecognizerIntent.EXTRA_ENABLE_FORMATTING,
                RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY,
            )
            // l'audio arriva dalla registrazione, non dal microfono
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, read)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(
                RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, sampleRate)
            // sessione lunga: segmenti finali finché la pipe resta aperta
            putExtra(
                RecognizerIntent.EXTRA_SEGMENTED_SESSION,
                RecognizerIntent.EXTRA_AUDIO_SOURCE,
            )
        }

    /** Audio della registrazione (PCM 16 bit mono): nella pipe, mai bloccando. */
    private fun feed(bytes: ByteArray) {
        if (!running) return
        io.execute {
            synchronized(lock) {
                if (out == null || !writeOut(bytes)) queue(bytes)
            }
        }
    }

    /** Scrive nella pipe (thread [io]); false se la pipe è chiusa. */
    private fun writeOut(bytes: ByteArray): Boolean {
        val o = out ?: return false
        return try {
            o.write(bytes)
            true
        } catch (e: IOException) {
            // il riconoscitore ha chiuso la sessione: si aspetta la prossima
            closeQuietly(o)
            out = null
            false
        }
    }

    private fun queue(bytes: ByteArray) {
        pending.addLast(bytes)
        pendingBytes += bytes.size
        while (pendingBytes > MAX_PENDING_BYTES && pending.isNotEmpty()) {
            pendingBytes -= pending.removeFirst().size
        }
    }

    /** Fine dell'audio: si chiude la pipe, il riconoscitore manda l'ultimo testo. */
    private fun stop() {
        if (!running && recognizer == null) {
            send("ended", emptyMap())
            return
        }
        running = false
        stopping = true
        io.execute {
            synchronized(lock) {
                closeQuietly(out)
                out = null
                pending.clear()
                pendingBytes = 0
            }
        }
        try {
            recognizer?.stopListening()
        } catch (e: Exception) {
            // si chiude comunque sotto
        }
        val ses = session
        main.postDelayed({ if (stopping && ses == session) finished() }, 2500)
    }

    private fun finished() {
        stopping = false
        destroyNow()
        send("ended", emptyMap())
    }

    private fun destroyNow() {
        running = false
        try {
            recognizer?.destroy()
        } catch (e: Exception) {
            // già chiuso
        }
        recognizer = null
        closeQuietly(readEnd)
        readEnd = null
        io.execute {
            synchronized(lock) {
                closeQuietly(out)
                out = null
            }
        }
    }

    /** Sessione finita (fine frase o fine segmentata): se si registra ancora, un'altra. */
    private fun sessionEnded() {
        if (running) {
            startSession()
        } else if (stopping) {
            finished()
        }
    }

    private fun emitFinal(results: Bundle?) {
        val text = results
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
            ?.trim()
            .orEmpty()
        lastPartial = ""
        if (text.isNotEmpty()) {
            errors = 0
            send("result", mapOf("text" to text))
        }
    }

    private fun onRecognizerError(code: Int) {
        if (!running) {
            if (stopping) finished()
            return
        }
        // testo provvisorio rimasto: diventa definitivo
        if (lastPartial.isNotEmpty()) {
            send("result", mapOf("text" to lastPartial))
            lastPartial = ""
        }
        when (code) {
            // silenzio o niente di riconoscibile: si riascolta
            SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> {
                main.post { if (running) startSession() }
                return
            }
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
                fail("Permesso del microfono mancante per il riconoscimento vocale.", true)
                return
            }
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
            SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> {
                // la lingua può mancare sul dispositivo ma esserci in rete
                if (switchToNetwork()) return
                fail("Il riconoscimento vocale non supporta la lingua $locale.", true)
                return
            }
        }
        val now = SystemClock.elapsedRealtime()
        if (now - lastErrorAt > 60_000) errors = 0
        errors++
        lastErrorAt = now
        if (errors >= 5) {
            if (switchToNetwork()) return
            fail("Il riconoscimento vocale si è fermato (errore $code).", true)
            return
        }
        val delay = if (code == SpeechRecognizer.ERROR_RECOGNIZER_BUSY) 800L else 300L * errors
        main.postDelayed({ if (running) startSession() }, delay)
    }

    /** Dal riconoscitore sul dispositivo a quello normale (una volta). */
    private fun switchToNetwork(): Boolean {
        if (!onDevice) return false
        try {
            recognizer?.destroy()
        } catch (e: Exception) {
            // già chiuso
        }
        recognizer = null
        create(false) ?: return false
        errors = 0
        main.post { if (running) startSession() }
        return true
    }

    private fun fail(message: String, fatal: Boolean) {
        send("error", mapOf("message" to message, "fatal" to fatal))
        if (fatal) destroyNow()
    }

    private fun send(method: String, args: Map<String, Any?>) {
        val ses = session
        main.post {
            try {
                channel.invokeMethod(method, args + ("session" to ses))
            } catch (e: Exception) {
                // motore di Flutter chiuso
            }
        }
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onError(error: Int) = onRecognizerError(error)

        override fun onPartialResults(partialResults: Bundle?) {
            val text = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            if (text.isEmpty() || text == lastPartial) return
            lastPartial = text
            send("partial", mapOf("text" to text))
        }

        override fun onResults(results: Bundle?) {
            emitFinal(results)
            sessionEnded()
        }

        // sessione segmentata (Android 13+)
        override fun onSegmentResults(segmentResults: Bundle) {
            emitFinal(segmentResults)
        }

        override fun onEndOfSegmentedSession() {
            sessionEnded()
        }
    }

    fun dispose() {
        destroyNow()
        io.shutdown()
    }

    private fun closeQuietly(c: java.io.Closeable?) {
        try {
            c?.close()
        } catch (e: IOException) {
            // già chiuso
        }
    }
}
