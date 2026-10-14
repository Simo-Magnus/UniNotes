import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../study/course_catalog.dart';
import 'book_filters.dart';
import '../../core/constants/text_limits.dart';

/// Ricerca + filtri (materia, stato, formato, disponibilità).
class BookFilterBar extends StatefulWidget {
  const BookFilterBar({
    super.key,
    required this.catalog,
    required this.filter,
    required this.onChanged,
    required this.summary,
  });

  final CourseCatalog catalog;
  final BookFilter filter;
  final ValueChanged<BookFilter> onChanged;
  final String summary;

  @override
  State<BookFilterBar> createState() => _BookFilterBarState();
}

class _BookFilterBarState extends State<BookFilterBar> {
  late final _search = TextEditingController(text: widget.filter.query);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  BookFilter get _f => widget.filter;

  void _reset() {
    _search.clear();
    widget.onChanged(const BookFilter());
  }

  @override
  Widget build(BuildContext context) {
    final catalog = widget.catalog;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _search,
            inputFormatters: TextLimits.max(TextLimits.search),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Cerca titolo, autore, ISBN, materia…',
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Cancella',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _search.clear();
                        widget.onChanged(_f.copyWith(query: ''));
                      },
                    ),
            ),
            onChanged: (v) => widget.onChanged(_f.copyWith(query: v)),
          ),
          const SizedBox(height: 8),
          // «Scaricati» / «Da procurare» e, a destra, il solo numero dei
          // libri (posseduti su totali)
          Row(
            children: [
              Flexible(
                child: SegmentedButton<BookAvailability>(
                  showSelectedIcon: false,
                  emptySelectionAllowed: true,
                  segments: [
                    for (final a in BookAvailability.values)
                      ButtonSegment(value: a, label: Text(a.label)),
                  ],
                  selected: {?_f.availability},
                  onSelectionChanged: (s) => widget.onChanged(
                    _f.copyWith(availability: () => s.firstOrNull),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Libri posseduti su totali',
                child: Chip(
                  key: const Key('books-owned-count'),
                  label: Text(widget.summary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // filtri sotto i segmenti
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _MenuChip<int>(
                label: 'Materia',
                icon: Icons.school_outlined,
                value: _f.courseId,
                options: [
                  // solo il nome dell'insegnamento
                  for (final c in catalog.courses) _Option(c.id!, c.name),
                  const _Option(BookFilter.noCourse, 'Senza materia'),
                ],
                onChanged: (v) =>
                    widget.onChanged(_f.copyWith(courseId: () => v)),
              ),
              _MenuChip<BookOwnership>(
                label: 'Stato',
                icon: Icons.inventory_2_outlined,
                value: _f.ownership,
                options: [
                  for (final o in BookOwnership.values) _Option(o, o.label),
                ],
                onChanged: (v) =>
                    widget.onChanged(_f.copyWith(ownership: () => v)),
              ),
              _MenuChip<BookFormat>(
                label: 'Formato',
                icon: Icons.description_outlined,
                value: _f.format,
                options: [
                  for (final f in BookFormat.values) _Option(f, f.label),
                ],
                onChanged: (v) =>
                    widget.onChanged(_f.copyWith(format: () => v)),
              ),
              if (_f.isActive)
                TextButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.filter_alt_off_outlined),
                  label: const Text('Azzera filtri'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Option<T> {
  const _Option(this.value, this.label);
  final T value;
  final String label;
}

/// Chip che apre un menu di scelta. Niente voce «Tutti»: si torna a vedere
/// tutto toccando di nuovo la voce scelta o la × del chip.
class _MenuChip<T> extends StatelessWidget {
  const _MenuChip({
    required this.label,
    required this.icon,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final T? value;
  final List<_Option<T>> options;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final current = options.where((o) => o.value == value).firstOrNull;
    final selected = current != null;
    final chip = Chip(
      avatar: Icon(icon, size: 18),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Text(
          selected ? '$label: ${current.label}' : label,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      backgroundColor: selected
          ? Theme.of(context).colorScheme.secondaryContainer
          : null,
      onDeleted: selected ? () => onChanged(null) : null,
      deleteButtonTooltipMessage: 'Togli il filtro',
    );
    return PopupMenuButton<int>(
      tooltip: label,
      onSelected: (i) =>
          onChanged(options[i].value == value ? null : options[i].value),
      itemBuilder: (_) => [
        for (var i = 0; i < options.length; i++)
          CheckedPopupMenuItem(
            value: i,
            checked: options[i].value == value,
            child: Text(options[i].label),
          ),
      ],
      // il tocco sul chip apre il menù, quello sulla × toglie il filtro
      child: chip,
    );
  }
}
