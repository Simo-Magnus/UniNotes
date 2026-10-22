package io.github.simomagnus.universitynotes

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import java.io.File

/**
 * «Apri con…» (canale [CHANNEL], vedi lib/core/services/external_launcher.dart):
 * la scelta dell'app di Android (Intent.createChooser) anche quando per quel
 * tipo di file c'è già un'app predefinita.
 *
 * Il file passa all'altra app come `content://` del FileProvider di
 * open_filex (autorità `<pacchetto>.fileProvider.com.crazecoder.openfile`,
 * percorsi `root-path`), con il permesso di sola lettura.
 * `open` risponde "ok", "nessuna_app" o "errore".
 */
object OpenWith {
    const val CHANNEL = "io.github.simomagnus.universitynotes/apri_con"

    fun open(activity: Activity, path: String): String {
        val file = File(path)
        if (!file.isFile) return "errore"
        val uri = Uri.Builder()
            .scheme("content")
            .authority("${activity.packageName}.fileProvider.com.crazecoder.openfile")
            .encodedPath("/root" + Uri.encode(file.absolutePath, "/"))
            .build()
        val ext = file.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
        val view = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val chooser = Intent.createChooser(view, "Apri con")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            activity.startActivity(chooser)
            "ok"
        } catch (e: ActivityNotFoundException) {
            "nessuna_app"
        } catch (e: Exception) {
            "errore"
        }
    }
}
