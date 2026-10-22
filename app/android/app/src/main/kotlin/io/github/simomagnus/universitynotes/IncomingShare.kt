package io.github.simomagnus.universitynotes

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * File condivisi con UniNotes da altre app («Condividi → UniNotes»,
 * ACTION_SEND e ACTION_SEND_MULTIPLE, e «Apri con → UniNotes»,
 * ACTION_VIEW): [ShareReceiverActivity] copia ogni
 * file nella cache dell'app (finché ha il permesso di leggerlo), li mette in
 * attesa qui e apre l'app; Flutter li prende con `take` sul canale
 * [CHANNEL] (lib/features/cloud/incoming_files.dart) e chiede in quale
 * insegnamento salvarli.
 */
object IncomingShare {
    const val CHANNEL = "io.github.simomagnus.universitynotes/incoming"

    private val pending = mutableListOf<Map<String, Any>>()

    /** Avviso a Flutter (impostato da MainActivity quando il motore c'è). */
    var onAvailable: (() -> Unit)? = null

    @Synchronized
    fun add(items: List<Map<String, Any>>) {
        pending.addAll(items)
    }

    /** File in attesa, una volta sola. */
    @Synchronized
    fun take(): List<Map<String, Any>> {
        val out = pending.toList()
        pending.clear()
        return out
    }

    /**
     * Uri condivisi dall'intent (EXTRA_STREAM, poi ClipData). Le versioni
     * con il tipo di getParcelableExtra solo da Android 14: su Android 13
     * possono lanciare un'eccezione con certi extra (difetto del sistema,
     * evitato anche da IntentCompat di AndroidX) e la condivisione andrebbe
     * persa.
     */
    private fun urisOf(intent: Intent): List<Uri> {
        val out = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri: Uri? = if (Build.VERSION.SDK_INT >= 34) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                if (uri != null) out.add(uri)
            }
            // «Apri con → UniNotes» da un file manager o da un'altra app
            Intent.ACTION_VIEW -> intent.data?.let(out::add)
            Intent.ACTION_SEND_MULTIPLE -> {
                val list: List<Uri>? = if (Build.VERSION.SDK_INT >= 34) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                if (list != null) out.addAll(list)
            }
        }
        if (out.isEmpty()) {
            val clip = intent.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(out::add)
            }
        }
        return out.distinct()
    }

    /** Nome leggibile del file (DISPLAY_NAME, con estensione dal tipo). */
    private fun nameOf(context: Context, uri: Uri, index: Int): String {
        var name: String? = null
        try {
            context.contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) name = c.getString(0)
            }
        } catch (e: Exception) {
            name = null
        }
        var n = (name ?: uri.lastPathSegment ?: "File condiviso ${index + 1}")
            .substringAfterLast('/')
            .replace(Regex("[\\\\:*?\"<>|\\u0000-\\u001f]"), "_")
            .trim()
        if (n.isEmpty() || n == "." || n == "..") n = "File condiviso ${index + 1}"
        if (!n.contains('.')) {
            val ext = context.contentResolver.getType(uri)
                ?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
            if (ext != null) n = "$n.$ext"
        }
        return n
    }

    /**
     * Copia nella cache i file condivisi da [intent]. Solo `content://` di
     * altre app: niente `file://` né i provider di questa app (un'altra app
     * non deve poter far copiare all'app i suoi stessi file privati).
     */
    fun collect(context: Context, intent: Intent): List<Map<String, Any>> {
        val dir = File(context.cacheDir, "condivisi").apply { mkdirs() }
        val out = mutableListOf<Map<String, Any>>()
        val stamp = System.currentTimeMillis()
        for ((i, uri) in urisOf(intent).withIndex()) {
            if (uri.scheme != "content") continue
            if (uri.authority?.startsWith(context.packageName) == true) continue
            val name = nameOf(context, uri, i)
            val target = File(dir, "${stamp}_${i}_$name")
            try {
                val input = context.contentResolver.openInputStream(uri) ?: continue
                input.use { src -> target.outputStream().use { src.copyTo(it) } }
                out.add(mapOf("path" to target.path, "name" to name, "temporary" to true))
            } catch (e: Exception) {
                target.delete()
            }
        }
        // Solo testo (es. un appunto o un link condiviso): file .txt.
        if (out.isEmpty() && intent.action == Intent.ACTION_SEND) {
            val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            if (!text.isNullOrBlank()) {
                val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
                    ?.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]"), "_")
                    ?.trim()?.take(80)
                val day = SimpleDateFormat("yyyy-MM-dd HH.mm", Locale.ITALY).format(Date())
                val name = if (subject.isNullOrEmpty()) "Testo condiviso $day.txt" else "$subject.txt"
                val target = File(dir, "${stamp}_t_$name")
                target.writeText(text)
                out.add(mapOf("path" to target.path, "name" to name, "temporary" to true))
            }
        }
        return out
    }
}

/**
 * Riceve «Condividi → UniNotes»: copia i file (in un thread, l'attività è
 * trasparente), apre UniNotes come dall'icona e si chiude.
 */
class ShareReceiverActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val received = intent
        Thread {
            val items = try {
                IncomingShare.collect(applicationContext, received)
            } catch (e: Exception) {
                emptyList()
            }
            Handler(Looper.getMainLooper()).post {
                if (items.isNotEmpty()) IncomingShare.add(items)
                packageManager.getLaunchIntentForPackage(packageName)?.let {
                    it.addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED,
                    )
                    try {
                        startActivity(it)
                    } catch (e: Exception) {
                        // nessuna attività avviabile: i file restano in attesa
                    }
                }
                if (items.isNotEmpty()) IncomingShare.onAvailable?.invoke()
                finish()
            }
        }.start()
    }
}
