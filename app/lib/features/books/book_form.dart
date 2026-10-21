import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/constants/enums.dart';
import '../../core/constants/text_limits.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_theme.dart';
import '../../models/book.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../cloud/cloud_drive_service.dart';
import '../study/course_catalog.dart';
import '../../core/feedback/motion.dart';

/// Apre il form libro a schermo intero. Restituisce il libro salvato.
///
/// Transizione breve e leggera (dissolvenza con un piccolo scorrimento dal
/// basso, 220 ms) al posto di quella predefinita delle pagine: con la lista
/// dei libri sotto, piena di card con l'ombra, quella era lenta e scattosa.
/// Con «Riduci animazioni» il form compare subito.
Future<Book?> showBookForm(
  BuildContext context, {
  required CourseCatalog catalog,
  Book? book,
  int? initialCourseId,
}) => Navigator.of(context).push<Book>(
  PageRouteBuilder<Book>(
    fullscreenDialog: true,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (_, _, _) => BookForm(
      catalog: catalog,
      book: book,
      initialCourseId: initialCourseId,
    ),
    transitionsBuilder: (context, animation, _, child) {
      if (reduceMotion(context)) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  ),
);

enum _Req {
  required('Obbligatorio', true),
  recommended('Consigliato', false),
  unknown('Non indicato', null);

  const _Req(this.label, this.value);
  final String label;
  final bool? value;

  // senza indicazioni il libro è consigliato
  static _Req of(bool? v) => v == true ? required : recommended;
}

class BookForm extends StatefulWidget {
  const BookForm({
    super.key,
    required this.catalog,
    this.book,
    this.initialCourseId,
  });

  final CourseCatalog catalog;
  final Book? book;
  final int? initialCourseId;

  @override
  State<BookForm> createState() => _BookFormState();
}

class _BookFormState extends State<BookForm> {
  final _formKey = GlobalKey<FormState>();
  late final Book? _b = widget.book;
  late final _title = _ctrl(_b?.title);
  late final _author = _ctrl(_b?.author);
  late final _isbn = _ctrl(_b?.isbn);
  late final _edition = _ctrl(_b?.edition);
  late final _publisher = _ctrl(_b?.publisher);
  late final _year = _ctrl(_b?.year?.toString());
  late final _notes = _ctrl(_b?.notes);
  late final _filePath = _ctrl(_b?.filePath);
  late final _language = _ctrl(_b?.language);
  late int? _courseId = _b?.courseId ?? widget.initialCourseId;

  /// Formato: non si sceglie più nel form, si deduce dal file aggiunto.
  late BookFormat _format = _b?.format ?? BookFormat.pdf;
  late BookOwnership _ownership = _b?.ownership ?? BookOwnership.wanted;
  late _Req _req = _Req.of(_b?.required);

  /// File già copiato nell'app e file scelto da copiare al salvataggio.
  late String? _storedFile = _b?.storedFile;
  String? _pendingSource;
  bool _saving = false;

  /// «Salva su OneDrive»: il file del libro va anche su OneDrive (e/o Google
  /// Drive), così si legge sugli altri dispositivi dell'utente.
  bool _onOneDrive = true;

  /// Servizi collegati, per il nome della casella (vuoto = nessuno).
  String _cloudNames = '';

  @override
  void initState() {
    super.initState();
    final s = context.read<AppServices>();
    final stored = _b?.storedFile;
    if (stored != null) {
      s.onedrive.booksLocalOnly().then((l) {
        if (mounted && l.contains(stored)) setState(() => _onOneDrive = false);
      });
    }
    // dopo la transizione d'apertura: niente ricostruzioni a metà animazione
    Future<void>.delayed(const Duration(milliseconds: 260), () async {
      final names = [
        for (final c in s.clouds)
          if (await c.connected()) c.serviceName,
      ].join(' e ');
      if (mounted && names.isNotEmpty) setState(() => _cloudNames = names);
    });
  }

  final List<TextEditingController> _all = [];

  TextEditingController _ctrl(String? v) {
    final c = TextEditingController(text: v ?? '');
    _all.add(c);
    return c;
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  static String? _t(TextEditingController c) {
    final v = c.text.trim();
    return v.isEmpty ? null : v;
  }

  Future<void> _pickFile() async {
    try {
      final f = await FilePicker.pickFile(
        dialogTitle: 'Scegli il file del libro',
      );
      final path = f?.path;
      if (path == null) return;
      setState(() => _pendingSource = path);
      // Su Android il percorso scelto è una copia temporanea: non si salva.
      _applyPath(path, isFile: true, keepPath: !Platform.isAndroid);
    } catch (e) {
      if (mounted) showSnack(context, 'Selezione file non riuscita: $e');
    }
  }

  Future<void> _pickFolder() async {
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Scegli la cartella del libro',
      );
      if (path == null) return;
      _applyPath(path, isFile: false);
    } catch (e) {
      if (mounted) showSnack(context, 'Selezione cartella non riuscita: $e');
    }
  }

  /// Imposta il percorso e completa i campi deducibili dal file.
  void _applyPath(String path, {required bool isFile, bool keepPath = true}) {
    setState(() {
      if (keepPath) _filePath.text = path;
      if (!isFile) return;
      final ext = p.extension(path).toLowerCase();
      if (ext == '.pdf') _format = BookFormat.pdf;
      if (ext == '.epub' || ext == '.mobi' || ext == '.azw3') {
        _format = BookFormat.ebook;
      }
      if (_ownership == BookOwnership.wanted ||
          _ownership == BookOwnership.unavailable) {
        _ownership = BookOwnership.owned;
      }
    });
  }

  void _removeFile() => setState(() {
    _pendingSource = null;
    _storedFile = null;
  });

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final b = _b;
    final library = context.read<AppServices>().library;
    setState(() => _saving = true);
    var stored = _storedFile;
    try {
      final src = _pendingSource;
      if (src != null) stored = await library.store(src);
      // La copia precedente si elimina solo dopo aver salvato la nuova.
      if (b?.storedFile != null && b?.storedFile != stored) {
        await library.remove(b!.storedFile);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, 'Copia del file nell\'app non riuscita: $e');
      }
      return;
    }
    if (stored != null && mounted) {
      final clouds = context.read<AppServices>().clouds;
      // lista comune dei libri solo locali, casella «Libri» su ogni servizio
      await CloudDriveService.setBookInCloudFor(clouds, stored, _onOneDrive);
      final connected = [
        for (final c in clouds)
          if (await c.connected()) c,
      ];
      if (!mounted) return;
      if (_onOneDrive && connected.isNotEmpty) {
        for (final c in connected) {
          unawaited(c.sync()); // in background: il form si chiude subito
        }
      } else if (_onOneDrive) {
        showSnack(
          context,
          'Collega OneDrive o Google Drive in Collegamenti per salvare il '
          'libro anche lì.',
        );
      }
    }
    if (!mounted) return;
    final sameFile = stored == b?.storedFile;
    Navigator.pop(
      context,
      Book(
        id: b?.id,
        externalId: b?.externalId,
        courseId: _courseId,
        title: _title.text.trim(),
        author: _t(_author),
        isbn: _t(_isbn),
        edition: _t(_edition),
        publisher: _t(_publisher),
        year: int.tryParse(_year.text.trim()),
        format: _format,
        ownership: _ownership,
        // posizione fisica e nome file previsto non sono più nel form: i
        // valori già salvati restano
        physicalLocation: b?.physicalLocation,
        notes: _t(_notes),
        filePath: _t(_filePath),
        expectedFileName: b?.expectedFileName,
        language: _t(_language),
        required: _req.value,
        storedFile: stored,
        // Un file nuovo riparte dalla prima pagina.
        lastPage: sameFile ? b?.lastPage : null,
        pageCount: sameFile ? b?.pageCount : null,
        lastOpenedAt: sameFile ? b?.lastOpenedAt : null,
        // Un libro del catalogo modificato a mano è "tenuto" e gli
        // aggiornamenti del database non ne sovrascrivono più i dati.
        catalogChoice:
            b?.catalogChoice ??
            (b?.externalId != null ? CatalogChoice.kept : null),
        userEdited: b?.externalId != null || (b?.userEdited ?? false),
      ),
    );
  }

  Widget _appFileCard(ThemeData theme) {
    final pending = _pendingSource;
    final stored = _storedFile;
    final (IconData icon, String text) = pending != null
        ? (
            Icons.upload_file,
            'Al salvataggio verrà copiato nell\'app: ${p.basename(pending)}',
          )
        : stored != null
        ? (
            Icons.phone_android,
            [
              'Nell\'app: $stored',
              if (_b?.lastPage != null)
                'letto fino a pagina ${_b!.lastPage}'
                    '${_b.pageCount == null ? '' : ' di ${_b.pageCount}'}',
            ].join(' · '),
          )
        : (Icons.cloud_off_outlined, 'Nessun file nell\'app');
    return GlassCard(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(text)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _saving ? null : _pickFile,
                  icon: const Icon(Icons.insert_drive_file_outlined),
                  label: Text(
                    stored == null && pending == null
                        ? 'Aggiungi file all\'app'
                        : 'Sostituisci file',
                  ),
                ),
                if (stored != null || pending != null)
                  TextButton.icon(
                    onPressed: _saving ? null : _removeFile,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Rimuovi dall\'app'),
                  ),
              ],
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _onOneDrive,
              onChanged: (v) => setState(() => _onOneDrive = v ?? true),
              title: Text(
                'Salva su ${_cloudNames.isEmpty ? 'OneDrive' : _cloudNames}',
              ),
              subtitle: const Text(
                'Per leggere il libro anche sugli altri tuoi dispositivi',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Limite di caratteri per campo (vedi [TextLimits]).
  static int? _limit(String label) => switch (label) {
    final l when l.startsWith('Titolo') => TextLimits.bookTitle,
    final l when l.startsWith('Autor') => TextLimits.bookAuthor,
    'Editore' => TextLimits.publisher,
    'Edizione' => TextLimits.edition,
    'ISBN' => TextLimits.isbn,
    'Anno' => 4,
    'Lingua' => TextLimits.language,
    'Note' => TextLimits.notes,
    _ => null,
  };

  Widget _text(
    TextEditingController c,
    String label, {
    TextInputType? keyboard,
    String? Function(String?)? validator,
    int maxLines = 1,
  }) => TextFormField(
    controller: c,
    keyboardType: keyboard,
    validator: validator,
    minLines: 1,
    maxLines: maxLines,
    // contatore solo per le note (testo lungo)
    maxLength: label == 'Note' ? _limit(label) : null,
    inputFormatters: label == 'Note' || _limit(label) == null
        ? null
        : TextLimits.max(_limit(label)!),
    decoration: InputDecoration(labelText: label),
  );

  @override
  Widget build(BuildContext context) {
    final wide = context.isWide;
    Widget pair(Widget a, Widget b) => wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: a),
              const SizedBox(width: 12),
              Expanded(child: b),
            ],
          )
        : Column(children: [a, const SizedBox(height: 12), b]);

    final fields = <Widget>[
      _text(
        _title,
        'Titolo *',
        validator: (v) =>
            (v ?? '').trim().isEmpty ? 'Il titolo è obbligatorio' : null,
      ),
      pair(_text(_author, 'Autore'), _text(_publisher, 'Editore')),
      pair(
        _text(_edition, 'Edizione'),
        pair(
          _text(
            _year,
            'Anno',
            keyboard: TextInputType.number,
            validator: (v) {
              final s = (v ?? '').trim();
              if (s.isEmpty) return null;
              return int.tryParse(s) == null ? 'Anno non valido' : null;
            },
          ),
          _text(_isbn, 'ISBN'),
        ),
      ),
      _CourseField(
        catalog: widget.catalog,
        value: _courseId,
        onChanged: (v) => setState(() => _courseId = v),
      ),
      SegmentedButton<_Req>(
        segments: [
          for (final r in _Req.values)
            ButtonSegment(value: r, label: Text(r.label)),
        ],
        selected: {_req},
        onSelectionChanged: (s) => setState(() => _req = s.first),
      ),
      pair(
        _text(_language, 'Lingua'),
        DropdownButtonFormField<BookOwnership>(
          key: ValueKey(_ownership),
          style: Theme.of(context).textTheme.bodyLarge,
          initialValue: _ownership,
          decoration: const InputDecoration(labelText: 'Stato di possesso'),
          items: [
            for (final o in BookOwnership.values)
              DropdownMenuItem(value: o, child: Text(o.label)),
          ],
          onChanged: (v) => setState(() => _ownership = v ?? _ownership),
        ),
      ),
      _appFileCard(Theme.of(context)),
      _text(_filePath, 'Percorso originale (facoltativo)', maxLines: 3),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: _pickFolder,
            icon: const Icon(Icons.folder_open),
            label: const Text('Scegli cartella'),
          ),
          if (_filePath.text.isNotEmpty)
            TextButton.icon(
              onPressed: () => setState(_filePath.clear),
              icon: const Icon(Icons.clear),
              label: const Text('Rimuovi percorso'),
            ),
        ],
      ),
      _text(_notes, 'Note', maxLines: 5),
      // «Salva» solo qui, in fondo a tutti i campi (non più nella barra)
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: FilledButton.icon(
          key: const Key('book-save'),
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save),
          label: const Text('Salva'),
        ),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book == null ? 'Nuovo libro' : 'Modifica libro'),
      ),
      body: Form(
        key: _formKey,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final f in fields) ...[f, const SizedBox(height: 12)],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Materia del libro: un campo leggero che apre l'elenco degli insegnamenti
/// solo quando serve (il menù a tendina costruiva subito tutte le voci,
/// rallentando l'apertura del form). Solo il nome dell'insegnamento.
class _CourseField extends StatelessWidget {
  const _CourseField({
    required this.catalog,
    required this.value,
    required this.onChanged,
  });

  final CourseCatalog catalog;
  final int? value;
  final ValueChanged<int?> onChanged;

  Future<void> _pick(BuildContext context) async {
    final courses = catalog.courses;
    final r = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Materia associata'),
        children: [
          SizedBox(
            width: 420,
            height: math.min(480, (courses.length + 1) * 52.0),
            child: ListView.builder(
              itemCount: courses.length + 1,
              itemBuilder: (_, i) {
                final id = i == 0 ? _none : courses[i - 1].id;
                return ListTile(
                  title: Text(
                    i == 0 ? 'Nessuna materia' : courses[i - 1].label,
                  ),
                  trailing: id == (value ?? _none)
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(c, id),
                );
              },
            ),
          ),
        ],
      ),
    );
    if (r != null) onChanged(r == _none ? null : r);
  }

  static const _none = -1;

  @override
  Widget build(BuildContext context) {
    final valid = value != null && catalog.byId.containsKey(value);
    return InkWell(
      key: const Key('book-course'),
      onTap: () => _pick(context),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Materia associata',
          suffixIcon: Icon(Icons.arrow_drop_down),
        ),
        child: Text(
          valid ? catalog.byId[value]!.label : 'Nessuna materia',
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
