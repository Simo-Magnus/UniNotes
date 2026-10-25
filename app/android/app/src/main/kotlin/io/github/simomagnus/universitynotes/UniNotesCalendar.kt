package io.github.simomagnus.universitynotes

import android.Manifest
import android.accounts.Account
import android.app.Activity
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.CalendarContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

/**
 * Calendario del telefono per le prove dell'app (Calendar Provider), canale
 * `io.github.simomagnus.universitynotes/calendario` (stesso protocollo di
 * EventKit su iPhone e Mac, vedi lib/core/reminders/native_calendar_backend.dart):
 * - `access` → concesso | da_chiedere | negato; `request` → true se concesso;
 * - `calendars` → calendari con id, nome, account, tipo, colore, principale,
 *   sincronizzato (SYNC_EVENTS=1 di un account vero, non locale), scrivibile
 *   e `legacy` (calendario locale «UniNotes» delle versioni precedenti);
 * - `health` {calendarId} → esiste, scrivibile, sincronizzato e
 *   sincronizzazione automatica dell'account (ContentResolver);
 * - `events` {calendarId, startMs, endMs} → eventi dell'app ({id, notes});
 * - `write` {calendarId, eventId?, title, notes, location?, startMs, endMs,
 *   allDay, alarms} → id (promemoria METHOD_ALERT);
 * - `delete` {eventId}; `deleteCalendarIfEmpty` {calendarId, name}: solo il
 *   calendario locale dell'app, vuoto.
 * Le chiamate girano su un thread a parte (il Calendar Provider può essere
 * lento), le risposte tornano sul thread principale.
 */
class UniNotesCalendar(private val context: Context) {
    companion object {
        const val CHANNEL = "io.github.simomagnus.universitynotes/calendario"
        const val REQUEST_CODE = 4711
        private const val MARKER = "Rif. UniNotes: "
    }

    private var pendingRequest: MethodChannel.Result? = null

    private fun granted(): Boolean =
        context.checkSelfPermission(Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED &&
            context.checkSelfPermission(Manifest.permission.WRITE_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    fun handle(activity: Activity?, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "access" -> {
                result.success(if (granted()) "concesso" else "da_chiedere")
                return
            }
            "request" -> {
                if (granted()) {
                    result.success(true)
                    return
                }
                if (activity == null) {
                    result.success(false)
                    return
                }
                pendingRequest?.success(false)
                pendingRequest = result
                activity.requestPermissions(
                    arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR),
                    REQUEST_CODE,
                )
                return
            }
        }
        if (!granted()) {
            result.error("permesso", "Permesso del calendario negato.", null)
            return
        }
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        Thread {
            try {
                val value: Any? = when (call.method) {
                    "calendars" -> calendars()
                    "health" -> health(call.argument<String>("calendarId") ?: "")
                    "events" -> events(
                        call.argument<String>("calendarId") ?: "",
                        (call.argument<Number>("startMs") ?: 0).toLong(),
                        (call.argument<Number>("endMs") ?: 0).toLong(),
                    )
                    "write" -> write(call)
                    "delete" -> {
                        delete(call.argument<String>("eventId"))
                        null
                    }
                    "deleteCalendarIfEmpty" -> deleteCalendarIfEmpty(
                        call.argument<String>("calendarId") ?: "",
                        call.argument<String>("name") ?: "UniNotes",
                    )
                    else -> {
                        main.post { result.notImplemented() }
                        return@Thread
                    }
                }
                main.post { result.success(value) }
            } catch (e: NotFound) {
                main.post { result.error("non_trovato", "Evento non trovato.", null) }
            } catch (e: SecurityException) {
                main.post { result.error("permesso", "Permesso del calendario negato.", null) }
            } catch (e: Exception) {
                main.post { result.error("errore", e.message ?: e.toString(), null) }
            }
        }.start()
    }

    /** Esito della richiesta del permesso (da MainActivity). */
    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_CODE) return false
        pendingRequest?.success(granted())
        pendingRequest = null
        return true
    }

    /**
     * Motore staccato dall'attività (attività ricreata o chiusa con la
     * richiesta del permesso aperta): l'esito non arriverebbe più a questo
     * oggetto e Dart resterebbe in attesa per sempre. Risponde con lo stato
     * attuale.
     */
    fun dispose() {
        val pending = pendingRequest ?: return
        pendingRequest = null
        try {
            pending.success(granted())
        } catch (e: Exception) {
            // motore già chiuso
        }
    }

    private class NotFound : Exception()

    private val resolver: ContentResolver get() = context.contentResolver

    private fun calendars(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val cols = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.ACCOUNT_TYPE,
            CalendarContract.Calendars.OWNER_ACCOUNT,
            CalendarContract.Calendars.CALENDAR_COLOR,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
            CalendarContract.Calendars.SYNC_EVENTS,
            CalendarContract.Calendars.IS_PRIMARY,
        )
        resolver.query(CalendarContract.Calendars.CONTENT_URI, cols, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(1) ?: "Calendario"
                val account = c.getString(2) ?: ""
                val type = c.getString(3) ?: ""
                val owner = c.getString(4) ?: ""
                val access = c.getInt(6)
                val sync = c.getInt(7) == 1
                val local = type == CalendarContract.ACCOUNT_TYPE_LOCAL
                val primary = (!c.isNull(8) && c.getInt(8) == 1) ||
                    (owner.isNotEmpty() && owner.equals(account, ignoreCase = true))
                out.add(
                    mapOf(
                        "id" to c.getLong(0).toString(),
                        "name" to name,
                        "account" to account,
                        "accountType" to type,
                        "color" to c.getInt(5),
                        "primary" to primary,
                        "synced" to (sync && !local),
                        "writable" to (access >= CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR),
                        "legacy" to (local && name == "UniNotes"),
                    ),
                )
            }
        }
        return out
    }

    private fun health(id: String): Map<String, Any?> {
        val cols = arrayOf(
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.ACCOUNT_TYPE,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
            CalendarContract.Calendars.SYNC_EVENTS,
        )
        val uri = ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, id.toLongOrNull() ?: -1)
        resolver.query(uri, cols, null, null, null)?.use { c ->
            if (!c.moveToFirst()) return mapOf("exists" to false)
            val name = c.getString(0) ?: ""
            val type = c.getString(1) ?: ""
            val local = type == CalendarContract.ACCOUNT_TYPE_LOCAL
            var auto: Boolean? = null
            if (!local && name.isNotEmpty() && type.isNotEmpty()) {
                auto = try {
                    ContentResolver.getSyncAutomatically(Account(name, type), CalendarContract.AUTHORITY)
                } catch (e: Exception) {
                    null
                }
            }
            return mapOf(
                "exists" to true,
                "writable" to (c.getInt(2) >= CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR),
                "synced" to (c.getInt(3) == 1 && !local),
                "autoSync" to auto,
                // serve READ_SYNC_SETTINGS (permesso normale, nel manifest): se
                // manca, il controllo si salta invece di sembrare un permesso
                // del calendario negato
                "masterSync" to try {
                    ContentResolver.getMasterSyncAutomatically()
                } catch (e: Exception) {
                    null
                },
            )
        }
        return mapOf("exists" to false)
    }

    private fun events(calendarId: String, startMs: Long, endMs: Long): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val cols = arrayOf(CalendarContract.Events._ID, CalendarContract.Events.DESCRIPTION)
        val where = "${CalendarContract.Events.CALENDAR_ID} = ? AND " +
            "${CalendarContract.Events.DELETED} = 0 AND " +
            "${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ? AND " +
            "${CalendarContract.Events.DESCRIPTION} LIKE ?"
        val args = arrayOf(calendarId, startMs.toString(), endMs.toString(), "%$MARKER%")
        resolver.query(CalendarContract.Events.CONTENT_URI, cols, where, args, null)?.use { c ->
            while (c.moveToNext()) {
                out.add(mapOf("id" to c.getLong(0).toString(), "notes" to (c.getString(1) ?: "")))
            }
        }
        return out
    }

    private fun write(call: MethodCall): String {
        val calendarId = call.argument<String>("calendarId")?.toLongOrNull()
            ?: throw IllegalArgumentException("Calendario non valido.")
        val allDay = call.argument<Boolean>("allDay") ?: false
        val values = ContentValues().apply {
            put(CalendarContract.Events.CALENDAR_ID, calendarId)
            put(CalendarContract.Events.TITLE, call.argument<String>("title") ?: "")
            put(CalendarContract.Events.DESCRIPTION, call.argument<String>("notes") ?: "")
            put(CalendarContract.Events.EVENT_LOCATION, call.argument<String>("location") ?: "")
            put(CalendarContract.Events.DTSTART, (call.argument<Number>("startMs") ?: 0).toLong())
            put(CalendarContract.Events.DTEND, (call.argument<Number>("endMs") ?: 0).toLong())
            put(CalendarContract.Events.ALL_DAY, if (allDay) 1 else 0)
            put(CalendarContract.Events.EVENT_TIMEZONE, if (allDay) "UTC" else TimeZone.getDefault().id)
            put(CalendarContract.Events.AVAILABILITY, CalendarContract.Events.AVAILABILITY_BUSY)
        }
        val alarms = (call.argument<List<Any?>>("alarms") ?: emptyList())
            .mapNotNull { (it as? Number)?.toInt() }
            .distinct()
        values.put(CalendarContract.Events.HAS_ALARM, if (alarms.isEmpty()) 0 else 1)
        val existing = call.argument<String>("eventId")?.toLongOrNull()
        val eventId: Long
        if (existing != null) {
            val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, existing)
            val alive = resolver.query(
                uri, arrayOf(CalendarContract.Events.DELETED), null, null, null,
            )?.use { c -> c.moveToFirst() && c.getInt(0) == 0 } ?: false
            if (!alive || resolver.update(uri, values, null, null) == 0) throw NotFound()
            eventId = existing
            resolver.delete(
                CalendarContract.Reminders.CONTENT_URI,
                "${CalendarContract.Reminders.EVENT_ID} = ?",
                arrayOf(eventId.toString()),
            )
        } else {
            val uri = resolver.insert(CalendarContract.Events.CONTENT_URI, values)
                ?: throw IllegalStateException("Evento non scritto.")
            eventId = ContentUris.parseId(uri)
        }
        for (m in alarms) {
            resolver.insert(
                CalendarContract.Reminders.CONTENT_URI,
                ContentValues().apply {
                    put(CalendarContract.Reminders.EVENT_ID, eventId)
                    put(CalendarContract.Reminders.MINUTES, m)
                    put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
                },
            )
        }
        requestUpload(calendarId)
        return eventId.toString()
    }

    private fun delete(eventId: String?) {
        val id = eventId?.toLongOrNull() ?: return
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id)
        val calendarId = resolver.query(
            uri, arrayOf(CalendarContract.Events.CALENDAR_ID), null, null, null,
        )?.use { c -> if (c.moveToFirst()) c.getLong(0) else null }
        resolver.delete(uri, null, null)
        if (calendarId != null) requestUpload(calendarId)
    }

    /**
     * Chiede al sistema di caricare subito sul server le modifiche del
     * calendario [calendarId] (account Google, Samsung…): senza, l'evento
     * resta «da sincronizzare» finché l'app del calendario non sincronizza
     * da sola o a mano, e Google Calendar nel frattempo mostra «Sync error».
     * Rispetta la sincronizzazione automatica dell'utente (niente
     * SYNC_EXTRAS_MANUAL); i calendari locali non hanno un server.
     */
    private fun requestUpload(calendarId: Long) {
        try {
            val uri = ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, calendarId)
            resolver.query(
                uri,
                arrayOf(CalendarContract.Calendars.ACCOUNT_NAME, CalendarContract.Calendars.ACCOUNT_TYPE),
                null, null, null,
            )?.use { c ->
                if (!c.moveToFirst()) return
                val name = c.getString(0) ?: return
                val type = c.getString(1) ?: return
                if (type == CalendarContract.ACCOUNT_TYPE_LOCAL) return
                val account = Account(name, type)
                // Non solo «upload»: il fornitore del calendario chiede già un
                // caricamento a ogni modifica, e una richiesta uguale si fonde
                // con la sua, che Android rimanda di continuo (Pixel 9a,
                // 25/10/2026: evento caricato dopo quasi due minuti). Una
                // sincronizzazione completa e urgente, come il tasto «Aggiorna»
                // di Google Calendar, resta separata, carica gli eventi nuovi e
                // parte subito
                val full = android.os.Bundle().apply {
                    putBoolean(ContentResolver.SYNC_EXTRAS_EXPEDITED, true)
                }
                val upload = android.os.Bundle().apply {
                    putBoolean(ContentResolver.SYNC_EXTRAS_UPLOAD, true)
                    putBoolean(ContentResolver.SYNC_EXTRAS_EXPEDITED, true)
                }
                for (extras in listOf(full, upload)) {
                    // Android 12+: come lavoro urgente («expedited job»), che
                    // parte subito anche con l'app appena chiusa
                    if (android.os.Build.VERSION.SDK_INT >= 31) {
                        try {
                            val urgent = android.os.Bundle(extras).apply {
                                // un lavoro urgente non può essere anche «expedited»
                                // (SyncRequest: IllegalArgumentException)
                                remove(ContentResolver.SYNC_EXTRAS_EXPEDITED)
                                putBoolean(ContentResolver.SYNC_EXTRAS_SCHEDULE_AS_EXPEDITED_JOB, true)
                            }
                            ContentResolver.requestSync(account, CalendarContract.AUTHORITY, urgent)
                            continue
                        } catch (e: Exception) {
                            // quota dei lavori urgenti finita o non ammesso: richiesta normale
                        }
                    }
                    try {
                        ContentResolver.requestSync(account, CalendarContract.AUTHORITY, extras)
                    } catch (e: Exception) {
                        // la sincronizzazione arriverà comunque con quella periodica
                    }
                }
            }
        } catch (e: Exception) {
            // la sincronizzazione arriverà comunque con quella periodica
        }
    }

    /**
     * Elimina il calendario locale «UniNotes» creato dalle versioni
     * precedenti (account locale), solo se non ha più eventi. Come sync
     * adapter, così il calendario sparisce davvero (con i suoi eventi
     * segnati come eliminati).
     */
    private fun deleteCalendarIfEmpty(id: String, name: String): Boolean {
        val calId = id.toLongOrNull() ?: return false
        val cols = arrayOf(
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.ACCOUNT_TYPE,
        )
        var account = ""
        val ok = resolver.query(
            ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, calId),
            cols, null, null, null,
        )?.use { c ->
            if (!c.moveToFirst()) return@use false
            account = c.getString(1) ?: ""
            c.getString(0) == name && c.getString(2) == CalendarContract.ACCOUNT_TYPE_LOCAL
        } ?: false
        if (!ok) return false
        val left = resolver.query(
            CalendarContract.Events.CONTENT_URI,
            arrayOf(CalendarContract.Events._ID),
            "${CalendarContract.Events.CALENDAR_ID} = ? AND ${CalendarContract.Events.DELETED} = 0",
            arrayOf(calId.toString()),
            null,
        )?.use { c -> c.count } ?: 0
        if (left > 0) return false
        val uri: Uri = ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, calId)
            .buildUpon()
            .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, account)
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL)
            .build()
        return resolver.delete(uri, null, null) > 0
    }
}
