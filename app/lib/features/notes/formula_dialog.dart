import 'package:flutter/material.dart';

import '../../core/feedback/feedback_service.dart';
import '../../core/theme/app_tokens.dart';
import '../../widgets/math_text.dart';
import 'markdown_lite.dart';

/// Formula scelta nel dialogo: LaTeX e se va su una riga a sé.
typedef FormulaChoice = ({String tex, bool block});

/// Modelli rapidi (si inseriscono al cursore del campo LaTeX).
const List<(String, String)> kFormulaSnippets = [
  ('Frazione', r'\frac{a}{b}'),
  ('Potenza', r'x^{2}'),
  ('Pedice', r'x_{i}'),
  ('Radice', r'\sqrt{x}'),
  ('Somma', r'\sum_{i=1}^{n}'),
  ('Integrale', r'\int_{a}^{b} f(x)\,dx'),
  ('Limite', r'\lim_{x \to 0}'),
  ('Vettore', r'\vec{v}'),
  ('Matrice', r'\begin{pmatrix} a & b \\ c & d \end{pmatrix}'),
  ('α', r'\alpha'),
  ('π', r'\pi'),
  ('∞', r'\infty'),
  ('≤', r'\leq'),
  ('≠', r'\neq'),
];

/// Testo da inserire nell'appunto: `$…$` nella riga, `$$…$$` su righe
/// proprie (con un a capo prima e dopo se serve).
String formulaMarkdown(
  FormulaChoice f, {
  required String before,
  required String after,
}) {
  final tex = f.tex.trim();
  if (!f.block) {
    // "$2 x$" sembrerebbe un prezzo: allora \( … \), che non si confonde
    final dollar = '\$$tex\$';
    final spans = parseMathOnly(dollar);
    final ok = spans.length == 1 && spans.single.math;
    return ok ? dollar : '\\($tex\\)';
  }
  final lead = before.isEmpty || before.endsWith('\n') ? '' : '\n';
  final tail = after.isEmpty || after.startsWith('\n') ? '' : '\n';
  return '$lead\$\$\n$tex\n\$\$$tail';
}

/// Inserisce la formula al cursore di [c] (o al posto della selezione).
void insertFormula(TextEditingController c, FormulaChoice f) {
  final text = c.text;
  final sel = c.selection.isValid
      ? c.selection
      : TextSelection.collapsed(offset: text.length);
  final before = text.substring(0, sel.start);
  final after = text.substring(sel.end);
  final md = formulaMarkdown(f, before: before, after: after);
  c.value = TextEditingValue(
    text: before + md + after,
    selection: TextSelection.collapsed(offset: before.length + md.length),
  );
}

/// «Inserisci formula»: campo LaTeX con l'anteprima dal vivo.
Future<FormulaChoice?> showFormulaDialog(
  BuildContext context, {
  String initial = '',
}) => showDialog<FormulaChoice>(
  context: context,
  builder: (_) => _FormulaDialog(initial: initial),
);

class _FormulaDialog extends StatefulWidget {
  const _FormulaDialog({required this.initial});
  final String initial;

  @override
  State<_FormulaDialog> createState() => _FormulaDialogState();
}

class _FormulaDialogState extends State<_FormulaDialog> {
  late final _tex = TextEditingController(text: widget.initial);
  bool _block = false;

  @override
  void dispose() {
    _tex.dispose();
    super.dispose();
  }

  void _snippet(String s) {
    final t = _tex.text;
    final sel = _tex.selection.isValid
        ? _tex.selection
        : TextSelection.collapsed(offset: t.length);
    _tex.value = TextEditingValue(
      text: t.replaceRange(sel.start, sel.end, s),
      selection: TextSelection.collapsed(offset: sel.start + s.length),
    );
    AppFeedback.of(context).toggle();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final tex = _tex.text.trim();
    return AlertDialog(
      title: const Text('Inserisci formula'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('formula-tex'),
                controller: _tex,
                autofocus: true,
                minLines: 2,
                maxLines: 6,
                style: const TextStyle(fontFamily: 'IBMPlexMono'),
                decoration: const InputDecoration(
                  labelText: 'Formula in LaTeX',
                  hintText: r'es. \frac{1}{2} m v^2',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (label, s) in kFormulaSnippets)
                    ActionChip(
                      label: Text(label),
                      tooltip: s,
                      onPressed: () => _snippet(s),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Nella riga')),
                  ButtonSegment(value: true, label: Text('Su una riga a sé')),
                ],
                selected: {_block},
                onSelectionChanged: (v) => setState(() => _block = v.first),
              ),
              const SizedBox(height: 12),
              Text('Anteprima', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(minHeight: 64),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: t.innerCard,
                  border: Border.all(color: t.innerBorder),
                  borderRadius: BorderRadius.circular(AppScale.radiusInner),
                ),
                alignment: Alignment.center,
                child: tex.isEmpty
                    ? Text(
                        'Scrivi la formula per vederla qui.',
                        style: theme.textTheme.bodySmall,
                      )
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: MathFormula(
                          tex,
                          display: _block,
                          style: theme.textTheme.bodyLarge,
                        ),
                      ),
              ),
              const SizedBox(height: 6),
              Text(
                'Se la formula ha un errore resta scritta così com\'è, in '
                'rosso.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          key: const Key('formula-insert'),
          onPressed: tex.isEmpty
              ? null
              : () => Navigator.pop<FormulaChoice>(context, (
                  tex: tex,
                  block: _block,
                )),
          child: const Text('Inserisci'),
        ),
      ],
    );
  }
}
