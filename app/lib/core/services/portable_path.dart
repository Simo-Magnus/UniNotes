import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Cartella di supporto dell'app, letta una volta all'avvio
/// ([initPortableBase]; nei test si imposta a mano). Null = non nota: i
/// percorsi restano quelli del dispositivo.
String? portableBase;

/// Legge la cartella di supporto per [portablePath] (avvio dell'app e del
/// motore in background). Errori ignorati.
Future<void> initPortableBase() async {
  try {
    portableBase = p.normalize((await getApplicationSupportDirectory()).path);
  } catch (_) {}
}

/// Percorso di un file dell'app uguale su tutti i dispositivi, per le chiavi
/// che si sincronizzano (posizione del lettore, evidenziazioni): per i file
/// dentro la cartella dell'app (libri, materiali, allegati) il percorso
/// relativo con «/» (`app:libri/Analisi.pdf`), per gli altri il percorso
/// normalizzato del dispositivo (che resta lì).
String portablePath(String path) {
  final norm = p.normalize(path);
  final base = portableBase;
  if (base != null && base.isNotEmpty && p.isWithin(base, norm)) {
    return 'app:${p.split(p.relative(norm, from: base)).join('/')}';
  }
  return norm;
}
