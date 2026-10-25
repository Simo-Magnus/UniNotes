package io.github.simomagnus.universitynotes

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
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
     * Uri condivisi dall'intent (EXTRA_STREAM, poi ClipData).
     */
    private fun urisOf(intent: Intent): List<Uri> {
        val out = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> out.addAll(streamsOf(intent))
            // «Apri con → UniNotes» da un file manager o da un'altra app
            Intent.ACTION_VIEW -> intent.data?.let(out::add)
        }
        if (out.isEmpty()) {
            val clip = intent.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(out::add)
            }
        }
        return out.distinct()
    }

    /**
     * EXTRA_STREAM come elenco di Uri. Letto senza tipo e filtrato: alcune
     * app mettono lì un percorso come testo (o un elenco di testi) e con
     * getParcelableExtra la ClassCastException faceva perdere tutta la
     * condivisione, anche il ClipData; le versioni con il tipo (Android 13)
     * possono lanciare un'eccezione con certi extra (difetto del sistema).
     */
    private fun streamsOf(intent: Intent): List<Uri> = try {
        @Suppress("DEPRECATION")
        when (val v = intent.extras?.get(Intent.EXTRA_STREAM)) {
            is Uri -> listOf(v)
            is Collection<*> -> v.filterIsInstance<Uri>()
            is Array<*> -> v.filterIsInstance<Uri>()
            else -> emptyList()
        }
    } catch (e: Exception) {
        // extra illeggibile (BadParcelableException…): resta il ClipData
        emptyList()
    }

    /**
     * Nome entro il limite dei file system (255 byte, con il prefisso
     * aggiunto in [collect]): un DISPLAY_NAME più lungo (lo decide l'altra
     * app) faceva fallire la copia e il file andava perso. Si accorcia il
     * nome tenendo l'estensione.
     */
    fun shortName(name: String, maxBytes: Int = 200): String {
        if (name.toByteArray(Charsets.UTF_8).size <= maxBytes) return name
        val dot = name.lastIndexOf('.')
        val ext = if (dot > 0 && name.length - dot <= 16) name.substring(dot) else ""
        val base = if (ext.isEmpty()) name else name.substring(0, dot)
        val budget = maxBytes - ext.toByteArray(Charsets.UTF_8).size
        val out = StringBuilder()
        var used = 0
        var i = 0
        while (i < base.length) {
            val cp = base.codePointAt(i)
            val piece = String(Character.toChars(cp))
            val bytes = piece.toByteArray(Charsets.UTF_8).size
            if (used + bytes > budget) break
            out.append(piece)
            used += bytes
            i += Character.charCount(cp)
        }
        val cut = out.toString().trim()
        return (if (cut.isEmpty()) "File condiviso" else cut) + ext
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
            // il fornitore dell'altra app può lanciare un'eccezione anche
            // qui (permesso scaduto, Uri sconosciuto): il file si copia lo
            // stesso, senza estensione, invece di perdere la condivisione
            val ext = try {
                context.contentResolver.getType(uri)
                    ?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
            } catch (e: Exception) {
                null
            }
            if (ext != null) n = "$n.$ext"
        }
        return shortName(n)
    }

    /**
     * Autorità senza l'utente davanti: `content://0@autorità/…` (forma
     * multiutente di Android) apre lo stesso fornitore di
     * `content://autorità/…`, perché ContentResolver toglie «0@» prima di
     * cercarlo.
     */
    fun authorityOf(uri: Uri): String? = uri.authority?.substringAfterLast('@')

    /**
     * Uri di un fornitore di questa app (FileProvider di open_filex con
     * `root-path`, share_plus…): mai da copiare, anche scritto con l'utente
     * davanti (`0@…`), che prima superava il controllo sul nome. Oltre al
     * nome si guarda a quale pacchetto appartiene il fornitore.
     */
    fun isOwnProvider(context: Context, uri: Uri): Boolean {
        val authority = authorityOf(uri) ?: return false
        if (authority.startsWith(context.packageName)) return true
        return try {
            context.packageManager.resolveContentProvider(authority, 0)
                ?.packageName == context.packageName
        } catch (e: Exception) {
            false
        }
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
            if (isOwnProvider(context, uri)) continue
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
