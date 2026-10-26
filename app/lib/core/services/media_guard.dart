import 'dart:io';

/// Controllo dei file prima di darli al lettore multimediale (media_kit,
/// cioè mpv e FFmpeg).
///
/// mpv riconosce il formato dal contenuto, non dal nome: un file
/// «lezione.m4a» che in realtà è una scaletta di testo (M3U/M3U8, PLS, CUE,
/// EDL di mpv, ASX, XSPF, DASH, elenco di FFmpeg) verrebbe aperto come
/// elenco, e mpv segue gli indirizzi web che contiene (li considera sicuri
/// anche da un file locale): aprendo un allegato o una registrazione arrivati
/// da un altro dispositivo o da altri, l'app si collegherebbe a un server
/// scelto da chi ha scritto il file. Tutte queste scalette sono testo, mentre
/// un file audio o video vero ha byte di controllo già nelle prime centinaia
/// di byte (intestazioni RIFF, ID3, ftyp, OggS, fLaC, EBML, fotogrammi MP3).
abstract final class MediaGuard {
  /// Byte letti dall'inizio del file.
  static const sniffBytes = 1024;

  /// Messaggio mostrato al posto del lettore.
  static const notMediaMessage =
      'Questo file non è un audio o un video: è un testo (per esempio una '
      'scaletta con indirizzi web), che il lettore di UniNotes non apre.';

  /// Vero se [head] (inizio del file) sembra testo: nessun byte di
  /// controllo tranne tabulazione, a capo e ritorno a capo.
  static bool looksLikeText(List<int> head) {
    if (head.isEmpty) return false;
    for (final b in head) {
      if (b < 0x09 || (b > 0x0D && b < 0x20) || b == 0x7F) return false;
    }
    return true;
  }

  /// Motivo per non aprire [path] nel lettore, o null se si può aprire. Un
  /// file illeggibile si lascia al lettore, che mostra il suo errore.
  static Future<String?> unsafeReason(String path) async {
    RandomAccessFile? f;
    try {
      f = await File(path).open();
      final head = await f.read(sniffBytes);
      return looksLikeText(head) ? notMediaMessage : null;
    } catch (_) {
      return null;
    } finally {
      try {
        await f?.close();
      } catch (_) {}
    }
  }
}
