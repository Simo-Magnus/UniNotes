/// Segnalazioni dei dati mancanti senza backend: l'app apre una issue
/// precompilata nel repository pubblico del database.
library;

import '../../models/course.dart';
import '../academic/student_profile.dart';

const String kRepoOwner = 'Simo-Magnus';
const String kRepoName = 'UniNotes';

enum ContributionKind {
  books(
    'Libri mancanti',
    'Libri (titolo, autori, editore, anno, ISBN, '
        'obbligatorio o consigliato)',
  ),
  examDates(
    'Date d\'esame',
    'Date d\'esame (appello o prova in itinere: data, '
        'ora, aula, modalità)',
  );

  const ContributionKind(this.title, this.template);
  final String title;
  final String template;
}

/// URL `https://github.com/<owner>/<repo>/issues/new?title=…&body=…` con
/// ateneo, corso, insegnamento e anno già compilati.
Uri contributionIssueUrl({
  required ContributionKind kind,
  StudentProfile? profile,
  Course? course,
  int? year,
}) {
  final who = course?.name ?? profile?.degreeName ?? 'corso';
  final uni = profile?.universityLabel;
  final title = '${kind.title}: $who${uni == null ? '' : ' ($uni)'}';
  final aa = (profile != null && year != null)
      ? profile.academicYearOf(year).label
      : null;
  final lines = <String>[
    if (profile != null)
      '- Ateneo: ${profile.universityName} (`${profile.universityId}`)',
    if (profile != null)
      '- Corso: ${profile.degreeName} (`${profile.degreeId}`'
          '${profile.classCode == null ? '' : ', classe ${profile.classCode}'})',
    if (course != null)
      '- Insegnamento: ${course.name}'
          '${course.code == null ? '' : ' (codice ${course.code})'}'
          '${course.externalId == null ? '' : ' `${course.externalId}`'}',
    if (year != null) '- Anno: $year° anno${aa == null ? '' : ' · $aa'}',
    '',
    '## ${kind.template}',
    '',
    '- ',
    '',
    '## Fonte',
    '',
    'Link alla pagina ufficiale (programma, syllabus, calendario esami):',
    '',
  ];
  return Uri.https('github.com', '/$kRepoOwner/$kRepoName/issues/new', {
    'title': title,
    'body': lines.join('\n'),
  });
}
