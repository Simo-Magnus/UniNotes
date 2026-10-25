import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/feedback/app_modals.dart';
import '../core/services/app_services.dart';
import '../core/services/external_launcher.dart';
import '../core/theme/app_tokens.dart';
import 'section_active.dart';

/// Stato vuoto con icona e messaggio.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // scorre: con caratteri grandi e poco spazio (schede basse, finestra
    // stretta) il messaggio non esce dallo schermo
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: scheme.outline),
            const SizedBox(height: 12),
            // testo: colore secondario dello schema (il contorno non
            // arriva a 4,5:1 sul fondo del tema chiaro)
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: LayoutBuilder(
        // l'elemento a destra (un pulsante con la scritta lunga) non supera il
        // 60% della riga: se serve la sua scritta va a capo
        builder: (context, c) => Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (trailing != null)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: c.hasBoundedWidth ? c.maxWidth * 0.6 : 400,
                ),
                child: trailing,
              ),
          ],
        ),
      ),
    );
  }
}

/// Carica dati con [load] e li ricarica a ogni `revision.bump()` o quando
/// cambiano [deps] (es. filtri, giorno selezionato).
/// Gestisce caricamento ed errori in modo uniforme.
class RevisionBuilder<T> extends StatefulWidget {
  const RevisionBuilder({
    super.key,
    required this.load,
    required this.builder,
    this.deps = const [],
  });

  final Future<T> Function(AppServices s) load;
  final Widget Function(BuildContext context, T data) builder;
  final List<Object?> deps;

  @override
  State<RevisionBuilder<T>> createState() => _RevisionBuilderState<T>();
}

class _RevisionBuilderState<T> extends State<RevisionBuilder<T>>
    with SectionReturn<RevisionBuilder<T>> {
  late final AppServices _services = context.read<AppServices>();
  late Future<T> _future;
  T? _last;

  /// Caricamenti in corso (per non ripartire al ritorno nella sezione se
  /// quello di prima non è ancora finito).
  int _loading = 0;

  @override
  void initState() {
    super.initState();
    _future = _run();
    _services.revision.addListener(_reload);
  }

  Future<T> _run() {
    final f = _load();
    // l'errore lo mostra il FutureBuilder; due ricaricamenti nello stesso
    // fotogramma (due `revision.bump()` di fila) sostituiscono il futuro
    // prima che venga ascoltato e l'errore del primo restava senza
    // ascoltatori (eccezione non gestita)
    unawaited(f.then<void>((_) {}, onError: (Object _) {}));
    return f;
  }

  Future<T> _load() async {
    _loading++;
    try {
      final v = await widget.load(_services);
      _last = v;
      return v;
    } finally {
      _loading--;
    }
  }

  void _reload() {
    // sezione nascosta (resta viva dietro quella visibile): niente lavoro
    // inutile, i dati si rileggono quando torna visibile
    if (mounted && sectionActive) {
      setState(() {
        _future = _run();
      });
    }
  }

  /// Ritorno nella sezione: si rileggono i dati (cambiati intanto nel
  /// database o sul disco) mostrando quelli di prima finché arrivano.
  @override
  void onSectionReturn() {
    if (_loading == 0) _future = _run();
  }

  @override
  void didUpdateWidget(covariant RevisionBuilder<T> old) {
    super.didUpdateWidget(old);
    if (!_listEquals(old.deps, widget.deps)) _future = _run();
  }

  static bool _listEquals(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _services.revision.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          return EmptyState(
            icon: Icons.error_outline,
            message: 'Errore: ${snap.error}',
          );
        }
        // Durante un ricaricamento mostra i dati precedenti (niente sfarfallio).
        final data = snap.connectionState == ConnectionState.done
            ? snap.data
            : _last;
        if (data == null && snap.connectionState != ConnectionState.done) {
          // il cerchio solo se il primo caricamento dura (niente lampo per
          // le letture brevi)
          return const DelayedSpinner();
        }
        return widget.builder(context, (data ?? snap.data) as T);
      },
    );
  }
}

/// Cerchio di caricamento che compare solo dopo [delay] (con una breve
/// dissolvenza): un caricamento più rapido non mostra niente invece di un
/// lampo del cerchio. Il ritardo resta anche con «Riduci animazioni» (non è
/// un'animazione); la dissolvenza no.
class DelayedSpinner extends StatefulWidget {
  const DelayedSpinner({
    super.key,
    this.delay = const Duration(milliseconds: 250),
  });

  final Duration delay;

  @override
  State<DelayedSpinner> createState() => _DelayedSpinnerState();
}

class _DelayedSpinnerState extends State<DelayedSpinner>
    with SingleTickerProviderStateMixin {
  static const _fade = Duration(milliseconds: 150);
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.delay + _fade,
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = (widget.delay + _fade).inMicroseconds;
    final start = total == 0 ? 0.0 : widget.delay.inMicroseconds / total;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final v = _c.value;
        if (v < start) return const SizedBox.shrink();
        final o = reduce ? 1.0 : ((v - start) / (1 - start)).clamp(0.0, 1.0);
        return Opacity(opacity: o, child: child);
      },
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Mostra un errore di apertura esterna senza crash.
void showLaunchResult(BuildContext context, LaunchResult r) {
  if (!r.ok && r.message != null) showSnack(context, r.message!);
}

/// Pallino colorato (università / corso).
class ColorDot extends StatelessWidget {
  const ColorDot(this.color, {super.key, this.size = 12});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: readableOn(color, Theme.of(context).brightness),
      shape: BoxShape.circle,
    ),
  );
}

Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String message,
) async {
  final r = await showAppDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Conferma'),
        ),
      ],
    ),
  );
  return r ?? false;
}
