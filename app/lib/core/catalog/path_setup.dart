import '../academic/academic_year.dart';
import '../academic/student_profile.dart';
import '../services/app_services.dart';
import '../services/datapack_importer.dart';
import 'catalog_datapack.dart';
import 'catalog_models.dart';
import 'catalog_service.dart';
import 'course_replacements.dart';
import 'curricula.dart';
import '../../models/study.dart';

/// Scelte fatte nell'onboarding.
class PathSelection {
  const PathSelection({
    required this.ateneo,
    required this.tipo,
    this.corso,
    this.manualName,
    this.manualClass,
    this.manualDuration,
    required this.year,
    this.fuoriCorso = false,
    this.percorso,
  });

  /// Percorso scelto nei corsi che ne hanno più d'uno (null = principale).
  final String? percorso;

  final Ateneo ateneo;
  final TipoCorso tipo;

  /// Corso scelto dall'indice; null = inserito a mano.
  final CorsoIndice? corso;
  final String? manualName;
  final String? manualClass;
  final int? manualDuration;

  /// Anno del piano frequentato (fuori corso: quello che si sta completando).
  final int year;
  final bool fuoriCorso;

  bool get isManual => corso == null;

  PathSelection withPercorso(String? p) => PathSelection(
    ateneo: ateneo,
    tipo: tipo,
    corso: corso,
    manualName: manualName,
    manualClass: manualClass,
    manualDuration: manualDuration,
    year: year,
    fuoriCorso: fuoriCorso,
    percorso: p,
  );

  String get degreeName => corso?.nome ?? manualName ?? 'Corso di studio';

  String get degreeId =>
      corso?.id ?? CatalogIds.manualDegree(ateneo.id, degreeName);

  /// Durata in anni (da 1 a 10: una durata sbagliata nel catalogo, 0 o
  /// enorme, non rompe il calcolo degli anni del piano).
  int get duration {
    final d = corso?.durataAnni ?? manualDuration ?? tipo.durataTipica ?? 3;
    return d >= 1 && d <= 10 ? d : (tipo.durataTipica ?? 3);
  }

  StudentProfile toProfile(DateTime now) => StudentProfile(
    universityId: ateneo.id,
    universityName: ateneo.nome,
    universityShort: ateneo.sigla,
    universityType: ateneo.tipo.key,
    degreeId: degreeId,
    degreeName: degreeName,
    degreeType: tipo.key,
    classCode: corso?.classe ?? manualClass,
    durationYears: duration,
    currentYear: year.clamp(1, duration),
    fuoriCorso: fuoriCorso,
    referenceAa: AcademicYear.of(now),
    manual: isManual,
    curriculum: percorso,
  );
}

/// Esito dell'import del piano di studi.
class PlanImportResult {
  const PlanImportResult({
    required this.imported,
    this.courses = 0,
    this.books = 0,
    this.source,
    this.message,
    this.senzaRete = false,
  });

  /// true se gli insegnamenti sono stati importati dal catalogo.
  final bool imported;
  final int courses;
  final int books;
  final CatalogSource? source;

  /// Spiegazione per lo studente (es. offline: si potrà fare più tardi).
  final String? message;

  /// I dati del corso non sono sul dispositivo e non si sono potuti
  /// scaricare: l'interfaccia mostra [kServeConnessione] e «Riprova».
  final bool senzaRete;
}

/// Salva il percorso scelto e importa il piano di studi (tutti gli anni)
/// nelle tabelle dell'app passando dal data pack.
class PathSetupService {
  PathSetupService(this._s);
  final AppServices _s;

  static const offlineMessage =
      '$kServeConnessione Intanto puoi usare l\'app e aggiungere i corsi a '
      'mano; potrai scaricarli più tardi anche da Impostazioni → Il mio '
      'percorso → Aggiorna database.';

  /// Il database non ha ancora i corsi dell'ateneo scelto (404).
  static const missingMessage =
      'Il tuo ateneo non è ancora nel database: aggiungi gli insegnamenti a '
      'mano dalla sezione Insegnamenti o con "Aggiungi esame" in Esami.';

  /// Fine dell'onboarding: profilo, anni del piano e import del piano.
  /// Con [remote] falso non si prova a scaricare nulla (lo studente
  /// conferma senza connessione: il piano si scaricherà più tardi).
  Future<PlanImportResult> apply(
    PathSelection sel, {
    DateTime? now,
    bool remote = true,
  }) async {
    final at = now ?? DateTime.now();
    final profile = sel.toProfile(at);
    final previous = await _s.profiles.load();
    // Il profilo in memoria ([AppServices.profile]) si aggiorna solo quando
    // lo studente chiude il riepilogo (loadProfile), così l'onboarding resta
    // visibile fino a "Vai all'app".
    await _s.profiles.replace(profile);
    if (previous != null && previous.degreeId != profile.degreeId) {
      await hideOtherPaths(previous, profile);
    }
    // cambio d'ateneo o di corso: i dati del precedente escono dalla cache
    // (app leggera)
    if (previous != null &&
        (previous.universityId != profile.universityId ||
            previous.degreeId != profile.degreeId)) {
      await _s.catalog.eliminaAltri(profile.universityId, profile.degreeId);
    }
    final ateneo = sel.ateneo;
    PlanImportResult result;
    if (sel.isManual) {
      await _importMap(
        manualDegreeDataPack(
          ateneo: ateneo,
          degreeId: profile.degreeId,
          nome: profile.degreeName,
          classe: profile.classCode,
          now: at,
        ),
      );
      result = const PlanImportResult(
        imported: false,
        message:
            'Corso inserito a mano: aggiungi i tuoi insegnamenti dalla '
            'sezione Insegnamenti o con "Aggiungi esame" in Esami.',
      );
    } else {
      result = await importPlan(
        profile,
        ateneo: ateneo,
        now: at,
        remote: remote,
      );
    }
    _s.revision.bump();
    return result;
  }

  /// Cambio di corso di laurea: i dati del corso precedente (insegnamenti,
  /// esami, voti, studio, libri, appunti) restano nel database ma l'app
  /// mostra solo il nuovo corso (vedi [PlanScope.inDegree]). Gli
  /// insegnamenti aggiunti a mano senza corso di laurea passano al corso
  /// [previous], così non compaiono nel nuovo; tornando al corso precedente
  /// ricompare tutto. Restituisce quanti insegnamenti sono ora nascosti.
  Future<int> hideOtherPaths(
    StudentProfile previous,
    StudentProfile profile,
  ) async {
    final db = _s.database.db;
    await db.update('courses', {
      'degree_id': previous.degreeId,
    }, where: 'degree_id IS NULL');
    final n = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM courses WHERE degree_id != ?',
      [profile.degreeId],
    );
    return (n.first['n'] as int?) ?? 0;
  }

  /// Insegnamenti del catalogo per cui i moduli proposti sono già stati
  /// creati una volta (se lo studente li cancella non tornano).
  static const prefilledKey = 'prefilled_modules';

  /// Crea in Studio i moduli e gli argomenti proposti dal database (nel
  /// file del corso [corso], per esempio i capitoli del libro di
  /// riferimento) per gli insegnamenti che non hanno ancora moduli.
  /// Restituisce quanti insegnamenti sono stati precompilati.
  /// [moduli]: quelli già letti (es. da [importPlan]), così non si
  /// rileggono.
  Future<int> prefillModules(
    String ateneoId, {
    String? corso,
    bool remote = false,
    ModuliAteneo? moduli,
  }) async {
    final data =
        (moduli ??
                (corso == null
                        ? null
                        : await _s.catalog.moduli(
                            ateneoId,
                            corso: corso,
                            remote: remote,
                          ))
                    ?.data)
            ?.insegnamenti;
    if (data == null || data.isEmpty) return 0;
    final done = {
      for (final x in (await _s.settings.get(prefilledKey) ?? '').split('\n'))
        if (x.trim().isNotEmpty) x.trim(),
    };
    final prefix = '$ateneoId:course:';
    var n = 0;
    for (final c in await _s.courses.all()) {
      final ext = c.externalId;
      if (c.id == null || ext == null || !ext.startsWith(prefix)) continue;
      if (done.contains(ext)) continue;
      final proposti = data[ext.substring(prefix.length)];
      // solo il programma per gli argomenti d'esame, nessun modulo di Studio
      if (proposti == null || proposti.moduli.isEmpty) continue;
      if ((await _s.study.modules(c.id!)).isNotEmpty) {
        done.add(ext);
        continue;
      }
      for (final (i, m) in proposti.moduli.indexed) {
        final id = await _s.study.insertModule(
          StudyModule(courseId: c.id!, name: m.nome, sort: i),
        );
        for (final (j, t) in m.argomenti.indexed) {
          await _s.study.insertTopic(Topic(moduleId: id, name: t, sort: j));
        }
      }
      done.add(ext);
      n++;
    }
    await _s.settings.set(prefilledKey, done.join('\n'));
    return n;
  }

  /// Chiave delle impostazioni con gli insegnamenti del catalogo eliminati
  /// dallo studente (non tornano con «Aggiorna database»).
  static const removedKey = 'removed_catalog_courses';

  /// Ricorda che lo studente ha eliminato l'insegnamento del catalogo [ext].
  Future<void> rememberRemoved(String? ext) async {
    if (ext == null) return;
    final set = await _removed();
    if (set.add(ext)) {
      await _s.settings.set(removedKey, set.join('\n'));
    }
  }

  Future<Set<String>> _removed() async => {
    for (final x in (await _s.settings.get(removedKey) ?? '').split('\n'))
      if (x.trim().isNotEmpty) x.trim(),
  };

  /// Dopo l'import del catalogo: gli insegnamenti del corso di laurea che il
  /// catalogo non ha più (es. doppioni per canale o sede, ora uniti) e quelli
  /// eliminati dallo studente spariscono. Se contengono dati dello studente
  /// (voti, esami prenotati o sostenuti, sessioni di studio, moduli, libri
  /// posseduti) si archiviano invece di eliminarli. Restituisce quanti.
  Future<int> retireStaleCourses(String ateneoId, CorsoDettaglio corso) async {
    // un file del corso senza insegnamenti (malformato o in preparazione)
    // non toglie tutto il piano dello studente
    if (corso.insegnamenti.isEmpty) return 0;
    final db = _s.database.db;
    final valid = {
      for (final i in corso.insegnamenti) CatalogIds.course(ateneoId, i.id),
    };
    final removed = await _removed();
    final rows = await db.query(
      'courses',
      columns: ['id', 'external_id'],
      where: "degree_id = ? AND external_id LIKE ? AND status != 'archived'",
      whereArgs: [corso.id, '$ateneoId:course:%'],
    );
    var n = 0;
    for (final r in rows) {
      final id = r['id'] as int;
      final ext = r['external_id'] as String;
      if (valid.contains(ext) && !removed.contains(ext)) continue;
      Future<int> count(String sql) async =>
          (await db.rawQuery(sql, [id])).first.values.first as int? ?? 0;
      final userData =
          await count(
            "SELECT COUNT(*) FROM exams WHERE course_id = ? AND "
            "(grade IS NOT NULL OR status != 'planned')",
          ) +
          await count(
            'SELECT COUNT(*) FROM study_sessions WHERE course_id = ?',
          ) +
          await count('SELECT COUNT(*) FROM modules WHERE course_id = ?') +
          await count(
            "SELECT COUNT(*) FROM books WHERE course_id = ? AND "
            "(ownership_status != 'wanted' OR stored_file IS NOT NULL OR "
            'file_path IS NOT NULL)',
          );
      if (userData > 0 && !removed.contains(ext)) {
        await db.update(
          'courses',
          {'status': 'archived'},
          where: 'id = ?',
          whereArgs: [id],
        );
      } else {
        await db.transaction((txn) async {
          for (final t in ['events', 'study_sessions', 'books']) {
            await txn.delete(t, where: 'course_id = ?', whereArgs: [id]);
          }
          await txn.delete('courses', where: 'id = ?', whereArgs: [id]);
        });
      }
      n++;
    }
    return n;
  }

  /// Scarica i dati del corso del profilo (con [remote]: il corso con tutti
  /// gli anni e i moduli, e le sessioni dell'ateneo, solo ciò che è
  /// cambiato, vedi [CatalogService.scaricaCorso]) o li legge dalla copia
  /// salvata, e importa il corso. Senza dati importa solo ateneo e corso di
  /// laurea. [meta] è `meta.json` già scaricato; [forza] riscarica anche se
  /// il corso è stato appena scaricato (es. nel riepilogo dell'onboarding).
  Future<PlanImportResult> importPlan(
    StudentProfile profile, {
    Ateneo? ateneo,
    DateTime? now,
    bool remote = true,
    DatabaseMeta? meta,
    bool forza = false,
  }) async {
    final a =
        ateneo ??
        (await _s.catalog.universita()).byId(profile.universityId) ??
        Ateneo(
          id: profile.universityId,
          nome: profile.universityName,
          sigla: profile.universityShort,
          tipo:
              TipoAteneo.fromKey(profile.universityType) ?? TipoAteneo.statale,
        );
    final download = remote
        ? await _s.catalog.scaricaCorso(
            a.id,
            profile.degreeId,
            meta: meta,
            forza: forza,
          )
        : null;
    // dalla copia appena salvata (senza rete: da quella precedente o, se
    // manca, scaricata ora se possibile)
    final read = await _s.catalog.corsiAteneo(
      a.id,
      remote: false,
      corso: profile.degreeId,
    );
    final file = read == null || download == null || !download.corsiAggiornati
        ? read
        : CatalogResult(read.data, CatalogSource.remote);
    // solo gli insegnamenti del percorso dello studente (es. non quelli
    // dell'orientamento Shanghai o del percorso INTRAPRENDENTI)
    final tutto = file?.data.corso(profile.degreeId);
    final corso = tutto == null
        ? null
        : soloPercorso(tutto, profile.curriculum);
    if (corso == null) {
      await _importMap(
        manualDegreeDataPack(
          ateneo: a,
          degreeId: profile.degreeId,
          nome: profile.degreeName,
          classe: profile.classCode,
          now: now,
        ),
      );
      final missing = download?.corsiAssenti ?? false;
      return PlanImportResult(
        imported: false,
        source: file?.source,
        senzaRete: file == null && !missing,
        message: file == null
            ? (missing ? missingMessage : offlineMessage)
            : 'Il tuo corso probabilmente non è ancora nel database: aggiungi '
                  'gli insegnamenti a mano o riprova.',
      );
    }
    final before = {for (final c in await _s.courses.all()) c.id: c};
    // moduli e programmi, nello stesso file del corso: danno gli argomenti
    // d'esame e i moduli di Studio (facoltativi)
    ModuliAteneo? moduli;
    try {
      moduli = (await _s.catalog.moduli(
        a.id,
        corso: profile.degreeId,
        insegnamenti: [for (final i in tutto!.insegnamenti) i.id],
      ))?.data;
    } catch (_) {
      moduli = null;
    }
    final pack = catalogToDataPack(
      ateneo: a,
      corso: corso,
      aggiornatoIl: file!.data.aggiornatoIl,
      now: now,
      moduli: moduli,
    );
    final report = await _importMap(pack);
    await retireStaleCourses(a.id, corso);
    try {
      await prefillModules(a.id, moduli: moduli);
    } catch (_) {
      // i moduli proposti sono facoltativi
    }
    // prove in itinere del catalogo non più presenti (spostate di data) nel
    // corso di laurea aggiornato: si tolgono se lo studente non le ha usate
    final midterms = {
      for (final e in (pack['exams'] as List? ?? const []))
        if (e is Map && e['kind'] == 'midterm') e['externalId'],
    };
    final db = _s.database.db;
    for (final r in await db.query(
      'exams',
      columns: ['id', 'external_id'],
      where:
          "external_id LIKE ? AND status = 'planned' AND grade IS NULL "
          'AND course_id IN (SELECT id FROM courses WHERE degree_id = ?)',
      whereArgs: ['${a.id}:midterm:%', corso.id],
    )) {
      if (!midterms.contains(r['external_id'])) {
        await db.delete('exams', where: 'id = ?', whereArgs: [r['id']]);
      }
    }
    // nomi cambiati nel catalogo: le cartelle di appunti e registrazioni seguono
    for (final c in await _s.courses.all()) {
      final old = before[c.id];
      if (old != null && old.name != c.name) {
        await _s.notes.renameCourse(old, c);
      }
    }
    final local = await _s.catalog.localMeta();
    final updated = profile.copyWith(
      catalogVersion: () => local?.versione ?? file.data.aggiornatoIl,
    );
    await _s.profiles.save(updated);
    if (_s.profile.value != null) _s.profile.value = updated;
    return PlanImportResult(
      imported: true,
      courses: report.courses,
      books: report.books,
      source: file.source,
      message: file.offline
          ? 'Dati letti dalla copia salvata (${file.source.label}).'
          : null,
    );
  }

  /// "Aggiorna database": indici, piano del profilo. I dati personali
  /// (voti, libri tenuti/rimossi, note) non vengono toccati dall'import.
  /// Cambia il percorso (curriculum) seguito e reimporta il piano: gli
  /// insegnamenti degli altri percorsi escono (archiviati se contengono
  /// dati dello studente).
  Future<PlanImportResult> changeCurriculum(String? curriculum) async {
    final p = _s.profile.value ?? await _s.profiles.load();
    if (p == null) {
      return const PlanImportResult(
        imported: false,
        message: 'Nessun percorso scelto.',
      );
    }
    final updated = p.copyWith(curriculum: () => curriculum);
    await _s.profiles.save(updated);
    _s.profile.value = updated;
    final r = await importPlan(updated, remote: false);
    _s.revision.bump();
    return r;
  }

  /// Corsi di laurea eliminati dal catalogo perché doppioni
  /// (`corsi_sostituiti.json`): il collegamento del profilo e dei dati al
  /// vecchio id passa al nuovo, senza perdere i dati dello studente. Se
  /// cambia il corso del profilo, con [importNewPlan] importa subito il
  /// piano del nuovo corso dalle copie già presenti. Null se non c'è nulla
  /// da migrare. Non lancia mai: nel peggiore dei casi resta tutto com'è.
  Future<CourseReplacementResult?> migrateReplacedCourses({
    bool importNewPlan = true,
  }) async {
    try {
      final r = await CourseReplacements(_s).migrate();
      if (r != null && importNewPlan) {
        try {
          await importPlan(r.profile, remote: false);
        } catch (_) {
          // si importerà con «Aggiorna database»
        }
        _s.revision.bump();
      }
      return r;
    } catch (_) {
      return null;
    }
  }

  /// «Aggiorna database»: indici comuni, `meta.json` e i dati del solo
  /// ateneo del profilo (riscaricati solo se cambiati), poi il piano.
  Future<PlanImportResult> refresh({DateTime? now}) async {
    await _s.catalog.refreshIndexes();
    final meta = await _s.catalog.remoteMeta();
    await migrateReplacedCourses(importNewPlan: false);
    final p = _s.profile.value ?? await _s.profiles.load();
    if (p == null) {
      return const PlanImportResult(
        imported: false,
        message: 'Nessun percorso scelto.',
      );
    }
    final r = await importPlan(p, now: now, meta: meta, forza: true);
    _s.revision.bump();
    return r;
  }

  Future<ImportReport> _importMap(Map<String, Object?> pack) async =>
      _s.importer.importMap(
        pack,
        exclusionPatterns: await _s.settings.exclusionPatterns(),
      );
}
