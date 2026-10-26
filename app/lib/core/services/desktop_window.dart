import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../features/notes/lecture_recorder.dart';
import '../../features/notes/recorder/overlay_logic.dart';
import '../../features/notes/recorder/recording_overlay.dart';
import '../../features/notes/recorder/recording_save.dart';
import 'app_services.dart';

/// Finestra dell'app sul PC (Windows, macOS, Linux) e registrazioni:
/// - chiudendo la finestra con il registratore attivo l'app si riduce
///   nell'area di notifica (system tray) e continua a registrare, con una
///   notifica che lo dice; dal menu dell'icona si riapre, si mette in pausa,
///   si salva o si esce;
/// - «Esci» con una registrazione in corso chiede Salva / Elimina / Annulla;
/// - se il sistema chiude l'app (spegnimento, disconnessione) la
///   registrazione in corso si salva prima di uscire.
///
/// Windows: la finestra sparisce appena si preme la X (la nasconde il
/// runner, `windows/runner/flutter_window.cpp`), il resto della chiusura
/// (salvataggi, icona dell'area di notifica, database, motore) continua
/// dietro. L'app dice al runner com'è finita ([finestraChannel]):
/// `nascosta` (resta nell'area di notifica) o `uscita` (si chiude: una copia
/// avviata intanto aspetta che finisca invece di passarle gli argomenti).
/// Vedi docs/registratore.md.
class DesktopWindow with WindowListener, TrayListener {
  DesktopWindow(this._s, {bool? windows, MethodChannel? channel})
    : _windows = windows ?? Platform.isWindows,
      _channel = channel ?? const MethodChannel(finestraChannel);
  final AppServices _s;
  final bool _windows;
  final MethodChannel _channel;

  /// Canale della finestra nel runner di Windows.
  static const finestraChannel = 'io.github.simomagnus.universitynotes/finestra';

  static bool get supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  AppLifecycleListener? _lifecycle;
  bool _inTray = false;
  bool _hidden = false;
  bool? _menuPaused;
  bool _quitting = false;

  Future<void> init() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    trayManager.addListener(this);
    _s.recorder.addListener(_recorderChanged);
    _lifecycle = AppLifecycleListener(
      onExitRequested: onExitRequested,
      // tornando in primo piano si disegna subito un frame (niente nero)
      onShow: _redraw,
      onResume: _redraw,
    );
  }

  /// Il motore chiede se uscire. Su Windows arriva da qui la X della
  /// finestra (il motore la intercetta e la rimanda a [onWindowClose] solo
  /// con «exit»): con una registrazione in corso la finestra va nell'area di
  /// notifica e l'app resta aperta, come con [onWindowClose]. Sugli altri
  /// sistemi è l'uscita dall'app (Cmd+Q, spegnimento): la registrazione si
  /// salva prima.
  @visibleForTesting
  Future<AppExitResponse> onExitRequested() async {
    trace('onExitRequested');
    if (_windows && _s.recorder.active && !_quitting) {
      await _toTray();
      return AppExitResponse.cancel;
    }
    await _saveRecording();
    return AppExitResponse.exit;
  }

  /// Avviso al runner di Windows (nessun effetto altrove e nei test).
  Future<void> _tellRunner(String method) async {
    if (!_windows) return;
    try {
      await _channel
          .invokeMethod<void>(method)
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('Finestra: «$method» non arrivato al runner: $e');
    }
  }

  void _redraw() => WidgetsBinding.instance.scheduleForcedFrame();

  /// Traccia dei tempi per le misure (stesso file del runner di Windows,
  /// solo con la variabile d'ambiente UNINOTES_TRACCIA_FINESTRA).
  static void trace(String what) {
    final path = Platform.environment['UNINOTES_TRACCIA_FINESTRA'];
    if (path == null || path.isEmpty) return;
    try {
      final ms = DateTime.now().microsecondsSinceEpoch / 1000;
      File(path).writeAsStringSync(
        '${ms.toStringAsFixed(3)} $pid dart: $what\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  @override
  void onWindowRestore() => _redraw();

  @override
  void onWindowMaximize() => _redraw();

  @override
  void onWindowFocus() => _redraw();

  /// Salvataggio senza domande (uscita decisa dal sistema).
  Future<void> _saveRecording() async {
    if (_s.recorder.active) {
      try {
        await saveRecording(_s);
      } catch (e) {
        // il WAV di lavoro resta: al prossimo avvio si recupera
        debugPrint('Registrazione non salvata in uscita: $e');
      }
    }
  }

  /// Menu dell'icona aggiornato con Pausa/Riprendi.
  void _recorderChanged() {
    if (!_inTray) return;
    final paused = _s.recorder.active ? _s.recorder.paused : null;
    if (paused != _menuPaused) unawaited(_setMenu());
  }

  @override
  Future<void> onWindowClose() async {
    trace('onWindowClose');
    if (_s.recorder.active && !_quitting) {
      await _toTray();
    } else {
      await _quit();
    }
  }

  /// X con una registrazione in corso: finestra nascosta, icona nell'area di
  /// notifica e avviso.
  Future<void> _toTray() async {
    try {
      await _showTray();
    } catch (e) {
      // niente icona (area di notifica non disponibile): senza la finestra
      // non si potrebbe più tornare alla registrazione, quindi resta (su
      // Windows il runner l'ha già nascosta alla X: si rimostra)
      debugPrint('Icona dell\'area di notifica non mostrata: $e');
      await _tellRunner('nascosta');
      await windowManager.show();
      return;
    }
    await windowManager.hide();
    _hidden = true;
    await _tellRunner('nascosta');
    await _s.reminders.recordingNotice(
      'UniNotes continua a registrare',
      'La registrazione di ${_s.recorder.courseName ?? 'questa lezione'} '
          'va avanti: trovi UniNotes nell\'area di notifica.',
    );
  }

  Future<void> _setMenu() async {
    final rec = _s.recorder;
    _menuPaused = rec.active ? rec.paused : null;
    await trayManager.setToolTip(
      rec.active
          ? 'UniNotes · ${rec.paused ? 'registrazione in pausa' : 'registrazione in corso'}'
          : 'UniNotes',
    );
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Apri UniNotes'),
          if (rec.active) ...[
            MenuItem.separator(),
            MenuItem(
              key: 'pause',
              label: rec.paused
                  ? 'Riprendi la registrazione'
                  : 'Metti in pausa',
            ),
            MenuItem(key: 'save', label: 'Salva la registrazione'),
          ],
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Esci da UniNotes'),
        ],
      ),
    );
  }

  Future<void> _showTray() async {
    if (_inTray) {
      await _setMenu();
      return;
    }
    // macOS: sagoma «template» che il sistema colora come le altre icone
    // della barra dei menu (chiara o scura)
    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/tray/app_icon.ico'
          : Platform.isMacOS
          ? 'assets/tray/app_icon_template.png'
          : 'assets/tray/app_icon.png',
      isTemplate: Platform.isMacOS,
    );
    _inTray = true;
    await _setMenu();
  }

  Future<void> _hideTray() async {
    if (!_inTray) return;
    await trayManager.destroy();
    _inTray = false;
  }

  Future<void> _show() async {
    // un'icona che non si toglie (area di notifica bloccata, come in
    // [_quit]) non deve impedire di riaprire la finestra: prima l'errore
    // fermava tutto prima di show(), la finestra restava nascosta con la
    // registrazione in corso e anche «Esci» dal menu non arrivava a
    // chiedere cosa farne
    try {
      await _hideTray();
    } catch (e) {
      debugPrint('Icona dell\'area di notifica non tolta: $e');
    }
    await windowManager.show();
    await windowManager.focus();
    _hidden = false;
  }

  /// «Esci»: con una registrazione in corso si chiede cosa farne.
  Future<void> _askAndQuit() async {
    if (!_s.recorder.active) return _quit();
    final nav = appNavigatorKey.currentContext;
    if (nav == null) return;
    await _show();
    if (!nav.mounted) return;
    final choice = await askSaveRecording(nav);
    switch (choice) {
      case RecordingCloseChoice.save:
        await _quit();
      case RecordingCloseChoice.delete:
        await discardRecording(_s);
        await _quit();
      case RecordingCloseChoice.cancel:
        break;
    }
  }

  /// Uscita definitiva: la registrazione ancora in corso si salva prima.
  /// Su Windows la finestra sparisce subito ([_tellRunner] `uscita`) e il
  /// resto continua dietro.
  Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    trace('_quit');
    await _tellRunner('uscita');
    await _saveRecording();
    // un'icona che non si toglie (area di notifica del sistema bloccata)
    // non deve impedire l'uscita: con la chiusura bloccata la finestra non
    // si chiuderebbe più né con la X né con «Esci»
    try {
      await _hideTray();
    } catch (e) {
      debugPrint('Icona dell\'area di notifica non tolta: $e');
    }
    _s.recorder.removeListener(_recorderChanged);
    _lifecycle?.dispose();
    // scritture del database ancora in corso (sincronizzazione, salvataggi)
    // finite prima di chiudere: le operazioni sulla connessione vanno in
    // fila, quindi una transazione vuota arriva dopo tutte quelle avviate
    try {
      await _s.database.db
          .transaction<void>((_) async {})
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Database non svuotato in uscita: $e');
    }
    trace('_quit: destroy');
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onTrayIconMouseDown() => _show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _show();
      case 'pause':
        _s.recorder.command(RecorderCommand.toggle);
      case 'save':
        // con la finestra nascosta si salva senza aprirla
        if (_hidden) {
          unawaited(
            saveRecording(_s).then(
              (_) {
                if (!_s.recorder.active) {
                  return _s.reminders.recordingNotice(
                    'Registrazione salvata',
                    'La trovi in Registra, nella pagina del corso.',
                  );
                }
              },
              // disco pieno, cartella non scrivibile: prima l'errore restava
              // non gestito e, con la finestra nascosta, non si vedeva niente
              onError: (Object e) {
                debugPrint('Registrazione non salvata dall\'icona: $e');
                return _s.reminders.recordingNotice(
                  'Registrazione non salvata',
                  'Il file audio non va perso: resta nell\'app e al prossimo '
                      'avvio UniNotes ti propone di salvarlo.',
                );
              },
            ),
          );
        } else {
          _s.recorder.command(RecorderCommand.save);
        }
      case 'quit':
        _askAndQuit();
    }
  }
}
