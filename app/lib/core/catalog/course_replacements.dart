import '../academic/student_profile.dart';
import '../services/app_services.dart';
import 'catalog_models.dart';
import 'curricula.dart';

/// Esito della migrazione del corso del profilo.
class CourseReplacementResult {
  const CourseReplacementResult({
    required this.oldId,
    required this.newId,
    required this.newName,
    required this.profile,
  });

  final String oldId;
  final String newId;
  final String newName;

  /// Profilo aggiornato (già salvato).
  final StudentProfile profile;
}

/// Sostituisce nell'app gli id dei corsi di laurea eliminati dal catalogo
/// perché doppioni (`corsi_sostituiti.json`) con quelli dei corsi che li
/// hanno assorbiti: profilo, insegnamenti, esami, libri e date collegati al
/// corso, elenchi salvati nelle impostazioni. I dati dello studente (voti,
/// esami, appunti, studio) non si toccano: cambia solo il collegamento al
/// catalogo. Si può rilanciare quando si vuole (una volta migrato non resta
/// nulla da fare).
class CourseReplacements {
  CourseReplacements(this._s);
  final AppServices _s;

  /// Impostazione con il nome del nuovo corso, da mostrare una volta sola
  /// allo studente (vedi `showCourseReplacedNotice`).
  static const noticeKey = 'course_replaced_notice';

  /// Id esterno dopo il cambio del corso [oldId] → [newId]. Gli id degli
  /// elementi del catalogo hanno la forma `<ateneo>:<tipo>:<insegnamento>[:…]`
  /// e l'id dell'insegnamento comincia con quello del corso di laurea.
  /// null se [ext] non appartiene a [oldId].
  static String? remapExternalId(String ext, String oldId, String newId) {
    final parts = ext.split(':');
    if (parts.length < 3) return null;
    final ins = parts[2];
    if (!ins.startsWith('$oldId-')) return null;
    parts[2] = '$newId${ins.substring(oldId.length)}';
    return parts.join(':');
  }

  /// Applica la mappa a profilo e dati. Ritorna l'esito se è cambiato il
  /// corso del profilo, altrimenti null (anche se altri riferimenti sono
  /// stati aggiornati). Un corso nuovo che il catalogo non conosce ancora
  /// non viene usato: si riprova al prossimo aggiornamento.
  Future<CourseReplacementResult?> migrate() async {
    final map = await _s.catalog.corsiSostituiti();
    if (map.isEmpty) return null;
    final db = _s.database.db;
    final profile = _s.profile.value ?? await _s.profiles.load();

    // (ateneo, id vecchio) di tutto ciò che nell'app punta a un corso
    final used = <(String?, String)>{
      if (profile != null && !profile.manual)
        (profile.universityId, profile.degreeId),
      for (final r in await db.rawQuery(
        'SELECT DISTINCT university_id, degree_id FROM courses '
        'WHERE degree_id IS NOT NULL',
      ))
        (r['university_id'] as String?, r['degree_id'] as String),
    };

    final renames = <String, ({String to, CorsoIndice info})>{};
    for (final (uni, old) in used) {
      if (renames.containsKey(old)) continue;
      final to = map.risolvi(old, universitaId: uni);
      if (to == null) continue;
      final info = await _find(uni, to);
      if (info != null) renames[old] = (to: to, info: info);
    }
    if (renames.isEmpty) return null;

    await db.transaction((txn) async {
      for (final e in renames.entries) {
        final old = e.key, to = e.value.to;
        Future<void> remap(
          String table,
          String where,
          List<Object?> args,
        ) async {
          for (final r in await txn.query(
            table,
            columns: ['id', 'external_id'],
            where: where,
            whereArgs: args,
          )) {
            final ext = r['external_id'] as String?;
            final next = ext == null ? null : remapExternalId(ext, old, to);
            if (next == null) continue;
            // già presente (UNIQUE): l'elemento vecchio resta com'è e
            // «Aggiorna database» lo archivia o lo toglie
            final dup = await txn.query(
              table,
              columns: ['id'],
              where: 'external_id = ?',
              whereArgs: [next],
              limit: 1,
            );
            if (dup.isNotEmpty) continue;
            await txn.update(
              table,
              {'external_id': next},
              where: 'id = ?',
              whereArgs: [r['id']],
            );
          }
        }

        const own = 'course_id IN (SELECT id FROM courses WHERE degree_id = ?)';
        await remap('courses', 'degree_id = ?', [old]);
        await remap('exams', own, [old]);
        await remap('books', own, [old]);
        await remap('events', own, [old]);
        await txn.update(
          'courses',
          {'degree_id': to},
          where: 'degree_id = ?',
          whereArgs: [old],
        );
        await txn.delete('degrees', where: 'id = ?', whereArgs: [old]);
      }
    });

    // elenchi di id salvati nelle impostazioni (PathSetupService.removedKey
    // e prefilledKey)
    for (final key in const ['removed_catalog_courses', 'prefilled_modules']) {
      final raw = await _s.settings.get(key);
      if (raw == null || raw.isEmpty) continue;
      var changed = false;
      final lines = <String>[];
      for (final line in raw.split('\n')) {
        var out = line.trim();
        for (final e in renames.entries) {
          out = remapExternalId(out, e.key, e.value.to) ?? out;
        }
        changed |= out != line.trim();
        if (out.isNotEmpty && !lines.contains(out)) lines.add(out);
      }
      if (changed) await _s.settings.set(key, lines.join('\n'));
    }

    final r = profile == null ? null : renames[profile.degreeId];
    if (profile == null || r == null || profile.manual) {
      _s.revision.bump();
      return null;
    }
    final updated = await _updateProfile(profile, r.to, r.info);
    await _s.settings.set(noticeKey, r.info.nome);
    if (_s.profile.value != null) _s.profile.value = updated;
    _s.revision.bump();
    return CourseReplacementResult(
      oldId: profile.degreeId,
      newId: r.to,
      newName: r.info.nome,
      profile: updated,
    );
  }

  /// Il corso [id] nel catalogo (indice, poi file dell'ateneo), se c'è.
  Future<CorsoIndice?> _find(String? ateneoId, String id) async {
    final indice = await _s.catalog.indiceCorsi();
    for (final c in indice.corsi) {
      if (c.id == id && (ateneoId == null || c.ateneoId == ateneoId)) return c;
    }
    if (ateneoId == null) return null;
    try {
      final file = await _s.catalog.corsiAteneo(
        ateneoId,
        remote: false,
        corso: id,
      );
      final c = file?.data.corso(id);
      if (c == null) return null;
      return CorsoIndice(
        ateneoId: ateneoId,
        id: c.id,
        nome: c.nome,
        tipo: c.tipo,
        classe: c.classe,
        durataAnni: c.durataAnni,
      );
    } catch (_) {
      return null;
    }
  }

  Future<StudentProfile> _updateProfile(
    StudentProfile p,
    String newId,
    CorsoIndice info,
  ) async {
    // il percorso (curriculum) resta se esiste anche nel nuovo corso
    String? curriculum = p.curriculum;
    try {
      final file = await _s.catalog.corsiAteneo(
        p.universityId,
        remote: false,
        corso: newId,
      );
      final corso = file?.data.corso(newId);
      if (corso != null) {
        final percorsi = PercorsiCorso.di(corso);
        curriculum = percorsi.daScegliere ? percorsi.valido(curriculum) : null;
      }
    } catch (_) {}
    final updated = p.copyWith(
      degreeId: newId,
      degreeName: info.nome,
      degreeType: info.tipo.key,
      classCode: () => info.classe ?? p.classCode,
      // una durata fuori intervallo nel catalogo non si usa
      durationYears: switch (info.durataAnni) {
        final d? when d >= 1 && d <= 10 => d,
        _ => null,
      },
      curriculum: () => curriculum,
    );
    await _s.profiles.save(updated);
    return updated;
  }
}

/// Nome del nuovo corso se c'è un avviso da mostrare (e lo toglie: si
/// mostra una sola volta).
Future<String?> takeCourseReplacedNotice(AppServices s) async {
  final name = (await s.settings.get(CourseReplacements.noticeKey))?.trim();
  if (name == null || name.isEmpty) return null;
  await s.settings.set(CourseReplacements.noticeKey, null);
  return name;
}
