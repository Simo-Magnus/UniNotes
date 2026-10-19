import 'package:flutter/material.dart';

import '../../core/catalog/curricula.dart';

/// Scelta del percorso (curriculum, orientamento) nei corsi che ne hanno
/// più d'uno: nel piano entrano solo gli insegnamenti di quel percorso.
class PercorsoField extends StatelessWidget {
  const PercorsoField({
    super.key,
    required this.percorsi,
    required this.value,
    required this.onChanged,
  });

  final PercorsiCorso percorsi;
  final String? value;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final labels = [for (final p in percorsi.scelte) percorsi.etichetta(p)];
    return DropdownButtonFormField<String>(
      key: const Key('percorso'),
      isExpanded: true,
      initialValue: percorsi.valido(value),
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: const InputDecoration(
        labelText: 'Percorso (curriculum o orientamento)',
        helperText:
            'Nel piano entrano solo gli insegnamenti di questo percorso',
        helperMaxLines: 3,
      ),
      // Nel menu i nomi lunghi vanno a capo (voci alte quanto serve); nel
      // campo restano su una riga.
      itemHeight: null,
      selectedItemBuilder: (context) => [
        for (final l in labels)
          Text(l, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
      items: [
        for (final (i, p) in percorsi.scelte.indexed)
          DropdownMenuItem(
            value: p,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(labels[i]),
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
