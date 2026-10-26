package io.github.simomagnus.universitynotes.widgets

import kotlin.math.floor
import kotlin.math.min

/**
 * Che cosa disegnare in un widget di [w]×[h] dp (calcolo puro, senza
 * Android: lo prova anche un programma a parte sulla JVM).
 *
 * Le misure qui sotto sono quelle dei layout (res/layout/widget_*.xml): se
 * cambia un margine o una dimensione del testo, va cambiata anche qui.
 *
 * Perché prima «Prossime prove» mostrava una sola prova: il layout era
 * unico e fisso (titolo più tre righe da due testi, ~170 dp di contenuto)
 * mentre il widget dichiarava 110 dp di altezza minima; nelle altezze
 * reali del launcher (orizzontale, griglie fitte, caratteri grandi) la
 * seconda e la terza riga finivano fuori dal riquadro e venivano tagliate.
 * Ora il numero di righe e la loro forma dipendono dallo spazio vero.
 */
internal object WidgetPlan {
    /** Prove al massimo nel widget (e nel JSON scritto dall'app). */
    const val MAX_EXAMS = 6

    // ------------------------------------------------ «Prossime prove»

    /** Margine interno del widget, sopra e sotto (dp). */
    const val PAD = 12f

    /** Intestazione «PROSSIME PROVE» con il suo margine (dp; il testo
     *  cresce con la dimensione dei caratteri del sistema). */
    fun headerHeight(fontScale: Float) = 5f + 15f * fontScale

    /** Riga con titolo e data (card interna: margine 5, spazio 7+7, testi
     *  da 14 e 12 sp): dp. */
    fun rowRich(fontScale: Float) = 19f + 35f * fontScale

    /** Riga compatta (solo il titolo e i giorni: margine 5, spazio 4+4,
     *  testo da 14 sp): dp. */
    fun rowDense(fontScale: Float) = 13f + 20f * fontScale

    /** Sotto questa larghezza i giorni si scrivono corti («Tra 5 gg»). */
    const val NARROW = 180f

    /** Altezza minima per l'intestazione. */
    const val HEADER_MIN_H = 80f

    /** Riquadro stretto (2×2, 2×3): una prova sola, grande; da 2×4 in su
     *  l'elenco con i giorni corti. */
    const val SINGLE_MIN_H = 90f
    const val NARROW_LIST_MIN_H = 300f

    enum class ExamsMode { SINGLE, LIST }

    data class Exams(
        val mode: ExamsMode,
        /** Righe da riempire (le altre restano nascoste). */
        val rows: Int,
        /** Righe con la data sotto il titolo. */
        val rich: Boolean,
        val header: Boolean,
        /** Giorni mancanti scritti corti. */
        val narrow: Boolean,
    )

    /** Forma del widget «Prossime prove» con [count] prove da mostrare. */
    fun exams(w: Float, h: Float, count: Int, fontScale: Float = 1f): Exams {
        val fs = fontScale.coerceIn(0.5f, 3f)
        val n = count.coerceIn(0, MAX_EXAMS)
        val narrow = w < NARROW
        if (narrow && h >= SINGLE_MIN_H && h < NARROW_LIST_MIN_H) {
            return Exams(ExamsMode.SINGLE, 1, rich = true, header = true, narrow = true)
        }
        val header = h >= HEADER_MIN_H
        val avail = h - 2 * PAD - (if (header) headerHeight(fs) else 0f)
        val want = maxOf(n, 1)
        val rich = rowsIn(avail, rowRich(fs))
        // righe con la data se ne stanno almeno tre (o tutte le prove);
        // altrimenti righe compatte, così se ne vedono di più
        return if (rich >= min(want, 3)) {
            Exams(ExamsMode.LIST, rich.coerceIn(1, min(want, MAX_EXAMS)), true, header, narrow)
        } else {
            val dense = rowsIn(avail, rowDense(fs))
            Exams(ExamsMode.LIST, dense.coerceIn(1, min(want, MAX_EXAMS)), false, header, narrow)
        }
    }

    private fun rowsIn(avail: Float, row: Float): Int =
        if (avail <= 0f) 0 else floor(avail / row).toInt()

    // ------------------------------------------------ «Registra lezione»

    enum class RecordMode {
        /** Fermo, riquadro stretto: tondo arancione con il microfono. */
        IDLE_ICON,

        /** Fermo: pulsante arancione «Registra lezione». */
        IDLE_PILL,

        /** In registrazione, riquadro basso: tutto su una riga. */
        REC_ROW,

        /** In registrazione: stato e tempo sopra, comandi sotto. */
        REC_COL,
    }

    data class Record(
        val mode: RecordMode,
        /** «Salva» ed «Elimina» oltre a Pausa/Riprendi. */
        val controls: Boolean,
        /** Scritte sotto le icone dei comandi. */
        val labels: Boolean,
        /** Nome del corso accanto allo stato. */
        val course: Boolean,
        /** Tempo grande. */
        val big: Boolean,
        /** Scritta lunga del pulsante («Registra lezione»). */
        val longLabel: Boolean,
    )

    /** Altezza minima della colonna (stato, tempo, comandi): dp. */
    const val REC_COL_MIN_H = 78f

    fun record(w: Float, h: Float, recording: Boolean): Record {
        if (!recording) {
            return if (w < 110f) {
                Record(RecordMode.IDLE_ICON, false, false, false, false, false)
            } else {
                Record(RecordMode.IDLE_PILL, false, false, false, false, w >= 160f)
            }
        }
        if (h < REC_COL_MIN_H) {
            return Record(RecordMode.REC_ROW, w >= 200f, false, false, false, false)
        }
        return Record(
            RecordMode.REC_COL,
            controls = w >= 110f,
            labels = w >= 250f && h >= 110f,
            course = w >= 150f,
            big = h >= 120f && w >= 110f,
            longLabel = false,
        )
    }
}
