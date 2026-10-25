import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../../../core/theme/app_tokens.dart';
import '../../../widgets/glass.dart';
import '../parsers/text_formats.dart' show formatClock;
import '../reader_controller.dart';
import '../reader_document.dart';
import 'document_view.dart';

/// Riproduzione con media_kit (libmpv), uguale su Windows, macOS, Linux,
/// Android e iOS. Impostazione nativa:
/// - Windows, Android, iOS, macOS: le librerie arrivano con
///   `media_kit_libs_video`, niente da configurare;
/// - macOS: con la sandbox attiva servono
///   `com.apple.security.files.user-selected.read-only` (file scelti) e
///   `com.apple.security.network.client` per i flussi in rete;
/// - Linux: serve `libmpv` di sistema (`sudo apt install libmpv-dev`).
///
/// Nei test (`FLUTTER_TEST`) libmpv di solito manca: il lettore non si
/// inizializza e la vista mostra un avviso al posto dei comandi.
bool readerMediaEnabled = !Platform.environment.containsKey('FLUTTER_TEST');

/// Registrazioni delle lezioni e video: riproduci/pausa, posizione, salti
/// di ±10/30 s, velocità 0,5–3×; accanto la trascrizione con lo stesso nome
/// (cercabile, con i tempi toccabili).
class MediaView extends StatefulWidget {
  const MediaView({
    super.key,
    required this.path,
    required this.video,
    required this.controller,
    this.transcript,
    this.transcriptName,
    this.initialSeconds,
  });

  final String path;
  final bool video;
  final ReaderPaneController controller;
  final RDoc? transcript;
  final String? transcriptName;
  final int? initialSeconds;

  @override
  State<MediaView> createState() => _MediaViewState();
}

const kMediaSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];

class _MediaViewState extends State<MediaView> {
  Player? _player;
  VideoController? _video;
  String? _error;
  final _subs = <StreamSubscription<Object?>>[];
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _playing = false;
  double _rate = 1;
  double? _dragging;
  final _transcriptCtl = ReaderPaneController();

  ReaderPaneController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.update(() {
      _c
        ..unitLabel = 'Minuto'
        ..describe = ((s) => 'Minuto ${formatClock(s.toDouble())}')
        ..onGoToPosition = ((s) => _seek(Duration(seconds: s)));
      if (widget.transcript != null) {
        _c
          ..onFind = _transcriptCtl.find
          ..onStep = _transcriptCtl.step
          ..plainText = (() => widget.transcript!.plainText);
      }
    });
    _transcriptCtl.addListener(_mirrorFind);
    _init();
  }

  void _mirrorFind() {
    _c.update(() {
      _c
        ..matchCount = _transcriptCtl.matchCount
        ..matchIndex = _transcriptCtl.matchIndex;
    });
  }

  Future<void> _init() async {
    if (!readerMediaEnabled) {
      setState(
        () => _error = 'Riproduzione non disponibile in questo ambiente.',
      );
      return;
    }
    try {
      MediaKit.ensureInitialized();
      final player = Player();
      _player = player;
      if (widget.video) _video = VideoController(player);
      _subs
        ..add(
          player.stream.position.listen((d) {
            if (!mounted) return;
            setState(() => _pos = d);
            if ((d.inSeconds - _c.position).abs() >= 2) {
              _c.update(() => _c.position = d.inSeconds);
            }
          }),
        )
        ..add(
          player.stream.duration.listen(
            (d) => mounted ? setState(() => _dur = d) : null,
          ),
        )
        ..add(
          player.stream.playing.listen(
            (v) => mounted ? setState(() => _playing = v) : null,
          ),
        )
        ..add(
          player.stream.rate.listen(
            (v) => mounted ? setState(() => _rate = v) : null,
          ),
        )
        ..add(
          player.stream.error.listen(
            (e) => mounted ? setState(() => _error = e) : null,
          ),
        );
      await player.open(Media(Uri.file(widget.path).toString()), play: false);
      final start = widget.initialSeconds;
      if (start != null && start > 0) {
        // Si aspetta la durata prima di saltare (il file deve essere aperto).
        await player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => Duration.zero,
            );
        await player.seek(Duration(seconds: start));
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = 'Impossibile avviare il lettore multimediale: $e',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _transcriptCtl
      ..removeListener(_mirrorFind)
      ..dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _seek(Duration d) async {
    final p = _player;
    if (p == null) return;
    var t = d < Duration.zero ? Duration.zero : d;
    if (_dur > Duration.zero && t > _dur) t = _dur;
    await p.seek(t);
  }

  void _skip(int seconds) => _seek(_pos + Duration(seconds: seconds));

  Widget _controls(BuildContext context) {
    final t = context.tokens;
    final total = _dur.inMilliseconds.toDouble();
    final value = (_dragging ?? _pos.inMilliseconds.toDouble()).clamp(
      0.0,
      total <= 0 ? 1.0 : total,
    );
    final ready = _player != null && _error == null;
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.video)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.graphic_eq, color: t.tintNotes, size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        p.basename(widget.path),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: t.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Slider(
              value: value,
              max: total <= 0 ? 1 : total,
              onChanged: ready && total > 0
                  ? (v) => setState(() => _dragging = v)
                  : null,
              onChangeEnd: (v) {
                setState(() => _dragging = null);
                _seek(Duration(milliseconds: v.round()));
              },
            ),
            Row(
              children: [
                Text(
                  formatClock(_pos.inMilliseconds / 1000),
                  style: TextStyle(
                    fontSize: 12,
                    color: t.cyanSoft,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const Spacer(),
                Text(
                  _dur == Duration.zero
                      ? '- -'
                      : formatClock(_dur.inMilliseconds / 1000),
                  style: TextStyle(
                    fontSize: 12,
                    color: t.textMuted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              children: [
                IconButton(
                  tooltip: 'Indietro 30 s',
                  icon: const Icon(Icons.replay_30),
                  onPressed: ready ? () => _skip(-30) : null,
                ),
                IconButton(
                  tooltip: 'Indietro 10 s',
                  icon: const Icon(Icons.replay_10),
                  onPressed: ready ? () => _skip(-10) : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(56, 48),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: ready ? () => _player!.playOrPause() : null,
                    child: Icon(
                      _playing ? Icons.pause : Icons.play_arrow,
                      semanticLabel: _playing ? 'Pausa' : 'Riproduci',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Avanti 10 s',
                  icon: const Icon(Icons.forward_10),
                  onPressed: ready ? () => _skip(10) : null,
                ),
                IconButton(
                  tooltip: 'Avanti 30 s',
                  icon: const Icon(Icons.forward_30),
                  onPressed: ready ? () => _skip(30) : null,
                ),
                PopupMenuButton<double>(
                  tooltip: 'Velocità',
                  enabled: ready,
                  initialValue: _rate,
                  onSelected: (r) => _player?.setRate(r),
                  itemBuilder: (_) => [
                    for (final r in kMediaSpeeds)
                      PopupMenuItem(value: r, child: Text('${_speed(r)}×')),
                  ],
                  child: Container(
                    constraints: const BoxConstraints(
                      minWidth: 52,
                      minHeight: 44,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${_speed(_rate)}×',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: t.cyanSoft,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: t.textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _speed(double r) => r == r.roundToDouble()
      ? r.toStringAsFixed(0)
      : r.toString().replaceAll('.', ',');

  @override
  Widget build(BuildContext context) {
    final player = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.video)
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _video == null
                ? const ColoredBox(color: Colors.black)
                // nessun comando del pacchetto: ci sono i nostri sotto
                // (NoVideoControls di media_kit vale null, senza tipo)
                : Video(controller: _video!, controls: null),
          ),
        _controls(context),
      ],
    );
    final transcript = widget.transcript;
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
          _player?.playOrPause(),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () =>
          _skip(-10),
      const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () =>
          _skip(10),
    };
    if (transcript == null) {
      return CallbackShortcuts(
        bindings: shortcuts,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: SingleChildScrollView(child: player),
          ),
        ),
      );
    }
    final view = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CardHeader(
          title: 'Trascrizione · ${widget.transcriptName ?? ''}',
          icon: Icons.article_outlined,
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppScale.radiusInner),
            child: DocumentView(
              doc: transcript,
              controller: _transcriptCtl,
              onSeek: (s) {
                _seek(Duration(milliseconds: (s * 1000).round()));
                _player?.play();
              },
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            ),
          ),
        ),
      ],
    );
    return CallbackShortcuts(
      bindings: shortcuts,
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth >= 900
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 420,
                    child: SingleChildScrollView(child: player),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 6, 12, 12),
                      child: view,
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  // i comandi non superano la metà dell'altezza: con la
                  // finestra bassa e i caratteri grandi scorrono invece di
                  // spingere fuori la trascrizione
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: c.hasBoundedHeight
                          ? c.maxHeight * 0.5
                          : double.infinity,
                    ),
                    child: SingleChildScrollView(child: player),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: view,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
