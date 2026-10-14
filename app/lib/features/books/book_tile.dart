import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/book.dart';
import 'book_filters.dart';

enum BookAction {
  edit,
  openFolder,
  saveCopy,
  removeFromApp,
  delete,

  /// Libro del catalogo: cerchio con la spunta (entra tra i miei libri).
  keep,

  /// Libro del catalogo: cerchio con la X (nascosto, ripristinabile).
  remove,

  /// Associa un file al libro (diventa «Scaricato»).
  attachFile,

  /// Ripristina un libro rimosso.
  restore,
}

/// Scheda di un libro. Il titolo è un link: apre il libro (nell'app se il
/// file è stato copiato, altrimenti dal percorso locale).
class BookTile extends StatelessWidget {
  const BookTile({
    super.key,
    required this.book,
    required this.onOpen,
    required this.onAction,
    this.toProcure,
  });

  final Book book;

  /// "Da procurare" calcolato sul catalogo intero (vedi needsProcurement).
  final bool? toProcure;
  final VoidCallback onOpen;
  final ValueChanged<BookAction> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final downloaded = isDownloaded(book);
    final details = [
      ?book.author,
      if (book.edition != null) '${book.edition} ed.',
      ?book.publisher,
      if (book.year != null) '${book.year}',
    ].join(' · ');
    // Telefono: «Aggiungi» sotto il testo insieme alle altre azioni, così il
    // titolo usa tutta la larghezza.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final attach = !isDownloaded(book) && !book.isRemoved
        ? TextButton.icon(
            key: ValueKey('attach-${book.id}'),
            onPressed: () => onAction(BookAction.attachFile),
            icon: const Icon(Icons.attach_file, size: 18),
            label: const Text('Aggiungi'),
          )
        : null;
    final choose = book.awaitingChoice && book.required != true;
    final link = Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(4),
        child: Tooltip(
          message: isInApp(book)
              ? 'Apri nell\'app'
              : downloaded
              ? 'Copia nell\'app e apri ${book.filePath}'
              : 'Nessun file associato',
          child: Text(
            book.title,
            style: theme.textTheme.titleMedium?.copyWith(
              color: downloaded ? scheme.primary : null,
              decoration: downloaded ? TextDecoration.underline : null,
              decorationColor: scheme.primary,
            ),
          ),
        ),
      ),
    );
    return ListTile(
      leading: Icon(Icons.menu_book_outlined, color: scheme.primary),
      // accanto al titolo i cerchi «tieni» (spunta) e «rimuovi» (X) per i
      // libri proposti dal catalogo
      title: choose
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: link),
                const SizedBox(width: 4),
                _ChoiceCircle(
                  key: ValueKey('keep-${book.id}'),
                  icon: Icons.check,
                  tooltip: 'Tieni',
                  color: const Color(0xFF2E7D32),
                  onTap: () => onAction(BookAction.keep),
                ),
                const SizedBox(width: 6),
                _ChoiceCircle(
                  key: ValueKey('remove-${book.id}'),
                  icon: Icons.close,
                  tooltip: 'Rimuovi',
                  color: const Color(0xFFC62828),
                  onTap: () => onAction(BookAction.remove),
                ),
              ],
            )
          : link,
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (details.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(details),
            ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: _badges(scheme)),
          if (book.isRemoved || (narrow && attach != null))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (book.isRemoved)
                    OutlinedButton.icon(
                      key: ValueKey('restore-${book.id}'),
                      onPressed: () => onAction(BookAction.restore),
                      icon: const Icon(Icons.restore, size: 18),
                      label: const Text('Ripristina'),
                    ),
                  if (narrow) ?attach,
                ],
              ),
            ),
        ],
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!narrow) ?attach,
          PopupMenuButton<BookAction>(
            onSelected: onAction,
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: BookAction.edit,
                child: Text('Modifica'),
              ),
              PopupMenuItem(
                value: BookAction.openFolder,
                enabled: (book.filePath ?? '').trim().isNotEmpty,
                child: const Text('Apri cartella originale'),
              ),
              PopupMenuItem(
                value: BookAction.saveCopy,
                enabled: isInApp(book),
                child: const Text('Salva una copia…'),
              ),
              PopupMenuItem(
                value: BookAction.removeFromApp,
                enabled: isInApp(book),
                child: const Text('Rimuovi file dall\'app'),
              ),
              if (book.fromCatalog && !book.isRemoved)
                const PopupMenuItem(
                  value: BookAction.remove,
                  child: Text('Rimuovi dai miei libri'),
                ),
              if (book.isRemoved)
                const PopupMenuItem(
                  value: BookAction.restore,
                  child: Text('Ripristina'),
                ),
              if (!book.fromCatalog)
                const PopupMenuItem(
                  value: BookAction.delete,
                  child: Text('Elimina'),
                ),
            ],
          ),
        ],
      ),
      onTap: () => onAction(BookAction.edit),
    );
  }

  /// Etichette del libro, con colori distinti e leggibili (chiaro e scuro):
  /// - «Obbligatorio» rosso; quando il libro è già scaricato il rosso si
  ///   attenua e «Scaricato» diventa verde acceso (non c'è più nulla da fare);
  /// - «Da procurare» solo per gli obbligatori senza file;
  /// - stato di possesso solo se dice qualcosa in più (prestito, venduto…).
  List<Widget> _badges(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    final downloaded = isDownloaded(book);
    const red = Color(0xFFC62828);
    const green = Color(0xFF2E7D32);
    final procure =
        book.required == true && (toProcure ?? needsProcurement(book));
    return [
      if (book.required == true)
        downloaded
            ? _Badge(
                'Obbligatorio',
                red.withValues(alpha: 0.06),
                (dark ? const Color(0xFFEF9A9A) : red).withValues(alpha: 0.55),
              )
            : _Badge(
                'Obbligatorio',
                red.withValues(alpha: dark ? 0.30 : 0.14),
                dark ? const Color(0xFFFFCDD2) : const Color(0xFFB71C1C),
                icon: Icons.priority_high,
              ),
      if (book.required != true)
        _Badge(
          'Consigliato',
          const Color(0xFF5E35B1).withValues(alpha: dark ? 0.30 : 0.12),
          dark ? const Color(0xFFD1C4E9) : const Color(0xFF4527A0),
        ),
      if (downloaded)
        _Badge(
          book.language == null ? 'Scaricato' : 'Scaricato (${book.language})',
          book.required == true
              ? const Color(0xFF00C853).withValues(alpha: dark ? 0.35 : 0.22)
              : green.withValues(alpha: dark ? 0.30 : 0.14),
          dark ? const Color(0xFFB9F6CA) : const Color(0xFF1B5E20),
          icon: Icons.download_done,
        ),
      if (isInApp(book))
        _Badge(
          'Nell\'app',
          const Color(0xFF00838F).withValues(alpha: dark ? 0.30 : 0.12),
          dark ? const Color(0xFFB2EBF2) : const Color(0xFF006064),
          icon: Icons.phone_android,
        ),
      if (readingProgress(book) case final progress?)
        _Badge(
          progress,
          const Color(0xFF1565C0).withValues(alpha: dark ? 0.30 : 0.12),
          dark ? const Color(0xFFBBDEFB) : const Color(0xFF0D47A1),
          icon: Icons.bookmark_outline,
        ),
      if (procure)
        _Badge(
          'Da procurare',
          const Color(0xFFEF6C00).withValues(alpha: dark ? 0.30 : 0.14),
          dark ? const Color(0xFFFFE0B2) : const Color(0xFFBF360C),
          icon: Icons.shopping_cart_outlined,
        ),
      if (book.ownership != BookOwnership.wanted &&
          !(book.ownership == BookOwnership.owned && downloaded))
        _Badge(
          book.ownership.label,
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
        ),
    ];
  }
}

/// Cerchio con la spunta («tieni») o la X («rimuovi») accanto al titolo.
class _ChoiceCircle extends StatelessWidget {
  const _ChoiceCircle({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = readableOn(color, Theme.of(context).brightness);
    // area di tocco di 40 px attorno a un cerchio di 30
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: SizedBox.square(
          dimension: 40,
          child: Center(
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.12),
                border: Border.all(color: fg, width: 1.5),
              ),
              child: Icon(icon, size: 18, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, this.bg, this.fg, {this.icon});
  final String label;
  final Color bg;
  final Color fg;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: fg),
          ),
        ),
      ],
    ),
  );
}
