import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services/app_services.dart';
import '../core/services/external_launcher.dart';
import '../core/theme/app_tokens.dart';

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
    return Center(
      child: Padding(
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
      child: Row(
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
          ?trailing,
        ],
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

class _RevisionBuilderState<T> extends State<RevisionBuilder<T>> {
  late final AppServices _services = context.read<AppServices>();
  late Future<T> _future;
  T? _last;

  @override
  void initState() {
    super.initState();
    _future = _run();
    _services.revision.addListener(_reload);
  }

  Future<T> _run() async {
    final v = await widget.load(_services);
    _last = v;
    return v;
  }

  void _reload() {
    if (mounted) {
      setState(() {
        _future = _run();
      });
    }
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
          return const Center(child: CircularProgressIndicator());
        }
        return widget.builder(context, (data ?? snap.data) as T);
      },
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
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
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
