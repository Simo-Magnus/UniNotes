import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/services/calendar_export.dart';
import 'package:university_notes/models/exam.dart';

void main() {
  test('file .ics con orario, giornata intera e caratteri speciali', () {
    final ics = buildIcs([
      (
        exam: Exam(
          id: 7,
          courseId: 1,
          date: DateTime(2027, 1, 20),
          time: '09:30',
          location: 'Aula 1, Lingotto',
          notes: 'Portare; calcolatrice',
        ),
        course: 'Analisi I',
      ),
      (
        exam: Exam(
          id: 8,
          courseId: 1,
          kind: ExamKind.midterm,
          date: DateTime(2026, 11, 5),
        ),
        course: 'Fisica',
      ),
      (exam: const Exam(id: 9, courseId: 1), course: 'senza data'),
    ], now: DateTime.utc(2026, 10, 10, 12));
    expect(ics, startsWith('BEGIN:VCALENDAR\r\n'));
    expect(ics, endsWith('END:VCALENDAR\r\n'));
    expect('BEGIN:VEVENT'.allMatches(ics).length, 2);
    expect(ics, contains('UID:university-notes-exam-7@universitynotes'));
    expect(ics, contains('DTSTART;TZID=Europe/Rome:20270120T093000'));
    expect(ics, contains('DTEND;TZID=Europe/Rome:20270120T113000'));
    expect(ics, contains(r'LOCATION:Aula 1\, Lingotto'));
    expect(ics, contains(r'Portare\; calcolatrice'));
    expect(ics, contains('DTSTART;VALUE=DATE:20261105'));
    expect(ics, contains('DTEND;VALUE=DATE:20261106'));
    expect(ics, contains('SUMMARY:Prova in itinere/esonero · Fisica'));
    expect(ics, contains('TRIGGER:-P1D'));
  });

  test(
    'righe lunghe ripiegate a 75 byte senza spezzare le lettere accentate',
    () {
      final ics = buildIcs([
        (
          exam: Exam(
            id: 1,
            courseId: 1,
            date: DateTime(2027, 2, 3),
            time: '14:00',
            topics: List.filled(
              20,
              'limiti, derivate, integrali è à',
            ).join(' '),
          ),
          course: 'Analisi matematica I',
        ),
      ]);
      for (final l in ics.split('\r\n')) {
        expect(utf8.encode(l).length, lessThanOrEqualTo(75), reason: l);
      }
      // ricomponendo le righe il testo torna intero
      expect(
        ics.replaceAll('\r\n ', ''),
        contains(r'DESCRIPTION:Argomenti: limiti\, derivate'),
      );
      expect(ics, contains('BEGIN:VTIMEZONE'));
      expect(ics, contains('SEQUENCE:'));
    },
  );
}
