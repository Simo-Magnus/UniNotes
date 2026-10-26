import 'dart:io';

import 'package:media_kit/media_kit.dart';

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
///
/// Seconda difesa, nel lettore stesso ([newPlayer]): mpv non segue i
/// riferimenti dei file (scalette comprese) e FFmpeg apre solo file locali.
abstract final class MediaGuard {
  /// Byte letti dall'inizio del file.
  static const sniffBytes = 1024;

  /// Messaggio mostrato al posto del lettore.
  static const notMediaMessage =
      'Questo file non è un audio o un video: è un testo (per esempio una '
      'scaletta con indirizzi web), che il lettore di UniNotes non apre.';

  /// Vero se [head] (inizio del file) sembra testo: nessun byte di
  /// controllo tranne tabulazione, a capo e ritorno a capo. Anche il testo
  /// in UTF-16 o UTF-32 con il BOM (mpv può convertirlo e leggerlo come
  /// scaletta), dove ogni carattere ASCII ha byte zero accanto.
  static bool looksLikeText(List<int> head) {
    if (head.isEmpty) return false;
    if (_starts(head, const [0xFF, 0xFE, 0x00, 0x00])) {
      return _unitsAreText(head, 4, 4, little: true);
    }
    if (_starts(head, const [0x00, 0x00, 0xFE, 0xFF])) {
      return _unitsAreText(head, 4, 4, little: false);
    }
    if (_starts(head, const [0xFF, 0xFE])) {
      return _unitsAreText(head, 2, 2, little: true);
    }
    if (_starts(head, const [0xFE, 0xFF])) {
      return _unitsAreText(head, 2, 2, little: false);
    }
    for (final b in head) {
      if (!_textUnit(b)) return false;
    }
    return true;
  }

  static bool _textUnit(int u) =>
      !(u < 0x09 || (u > 0x0D && u < 0x20) || u == 0x7F);

  static bool _starts(List<int> head, List<int> prefix) {
    if (head.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (head[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Unità di [size] byte dopo il BOM ([from]) tutte di testo (l'ultima,
  /// tagliata dalla lettura, non conta).
  static bool _unitsAreText(
    List<int> head,
    int from,
    int size, {
    required bool little,
  }) {
    for (var i = from; i + size <= head.length; i += size) {
      var u = 0;
      for (var k = 0; k < size; k++) {
        final b = head[little ? i + size - 1 - k : i + k];
        u = (u << 8) | b;
      }
      if (!_textUnit(u)) return false;
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

  /// Protocolli di FFmpeg ammessi (`protocol_whitelist` di media_kit): le
  /// registrazioni e i file del lettore sono sempre locali. Il file aperto
  /// lo legge mpv; FFmpeg apre da sé solo i file indicati dentro un altro
  /// (scalette HLS o DASH, riferimenti dei MOV), che così non vanno in rete.
  static const localProtocols = ['file'];

  /// Opzioni di mpv per i file locali: nessun riferimento seguito
  /// (`access-references`, le voci di una scaletta comprese) e nessuna
  /// scaletta «non sicura» (è già il valore predefinito, qui fissato).
  static const mpvOptions = {
    'access-references': 'no',
    'load-unsafe-playlists': 'no',
  };

  /// Configurazione del lettore per i file locali.
  static const configuration = PlayerConfiguration(
    protocolWhitelist: localProtocols,
  );

  /// Applica [mpvOptions] con [set] (proprietà di mpv).
  static Future<void> applyOptions(
    Future<void> Function(String name, String value) set,
  ) async {
    for (final e in mpvOptions.entries) {
      await set(e.key, e.value);
    }
  }

  /// Lettore per un file locale, con [configuration] e [mpvOptions]
  /// (prima di `open`).
  static Future<Player> newPlayer() async {
    final player = Player(configuration: configuration);
    final native = player.platform;
    if (native is NativePlayer) {
      await applyOptions((k, v) => native.setProperty(k, v));
    }
    return player;
  }
}
