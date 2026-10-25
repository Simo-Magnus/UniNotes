import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/services/external_launcher.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/cloud/data_sync_snapshot.dart';
import 'package:university_notes/features/cloud/drive_picker.dart';
import 'package:university_notes/features/reader/reader_screen.dart'
    show isNearbyLink;

/// Caccia alle falle, giro 1 — rete, accessi e dati in ingresso (vedi
/// docs/sicurezza.md). Senza binding dei widget: il binding sostituirebbe
/// l'HttpClient vero dei server locali.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sic_g1_rete_');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('1. programmi aperti da un percorso arrivato da un file', () {
    test('punti e spazi finali o flusso NTFS non nascondono un programma '
        '(Windows apre «setup.exe.» come setup.exe)', () {
      for (final name in [
        'setup.exe.',
        'setup.exe..',
        'setup.exe. .',
        'setup.exe::\$DATA',
        'setup.exe:flusso',
        'SETUP.EXE.',
        'console.msc',
        'pacchetto.msix',
        'impostazioni.settingcontent-ms',
        'avvio.desktop',
      ]) {
        expect(
          ExternalLauncher.unsafePathReason(p.join(tmp.path, name)),
          isNotNull,
          reason: name,
        );
      }
    });

    test('i documenti si aprono ancora', () {
      for (final name in [
        'libro.pdf',
        'appunti v1.2.docx',
        'slide.final.pptx',
        'lezione.mp3',
        'cartella.exe.d${Platform.pathSeparator}nota.txt',
      ]) {
        expect(
          ExternalLauncher.unsafePathReason(p.join(tmp.path, name)),
          isNull,
          reason: name,
        );
      }
    });
  });

  group('2. collegamenti dentro i documenti del lettore', () {
    test('«note:» e link ai file: niente percorsi di rete, assoluti o fuori '
        'dalla zona del documento', () {
      final dir = p.join(tmp.path, 'vault', 'corso');
      for (final link in [
        r'\\server\condivisa\nota.md',
        '//server/condivisa/nota.md',
        r'/\server\nota.md',
        p.join(tmp.path, 'altrove', 'nota.md'),
        '../../../segreto.md',
        'https://esempio.it/nota.md',
        '',
        '   ',
      ]) {
        expect(isNearbyLink(dir, link), isFalse, reason: link);
      }
    });

    test('note vicine al documento: sì', () {
      final dir = p.join(tmp.path, 'vault', 'corso');
      for (final link in ['nota.md', 'sotto/nota.md', '../vicina.md']) {
        expect(isNearbyLink(dir, link), isTrue, reason: link);
      }
    });
  });

  group('3. ritorno del selettore di Google Drive', () {
    test('una richiesta con byte non validi sulla porta locale non ferma '
        'l\'attesa del ritorno giusto', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      const state = 'stato-segreto';
      final result = DrivePicker.waitForReturn(server, state);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<int> get(String pathAndQuery) async {
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}$pathAndQuery'),
        );
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      }

      // (prima: FormatException dentro l'attesa, il selettore finiva in
      // errore e i file scelti dopo non arrivavano)
      expect(await get('/picker?%FF=1'), HttpStatus.notFound);
      expect(await get('/picker?state=altro&ids=x'), HttpStatus.notFound);
      expect(await get('/picker?state=$state&ids=abc,def'), HttpStatus.ok);
      final r = await result.timeout(const Duration(seconds: 10));
      expect(r.error, isNull);
      expect(r.ids, ['abc', 'def']);
    });
  });

  group('4. registri della sincronizzazione manipolati nel cloud', () {
    tearDown(() => SyncSnapshot.maxDecodedBytes = 256 * 1024 * 1024);

    test('un registro che decompresso supera il limite si ignora (niente '
        'memoria esaurita a ogni sincronizzazione)', () {
      SyncSnapshot.maxDecodedBytes = 1024 * 1024;
      // JSON valido gonfiato di spazi: 4 MB decompressi, pochi KB compressi
      final json =
          '{"format":"${SyncSnapshot.format}","version":1,"tables":{}'
          '${' ' * (4 * 1024 * 1024)}}';
      final bomb = gzip.encode(utf8.encode(json));
      expect(bomb.length, lessThan(64 * 1024));
      expect(SyncSnapshot.decode(bomb), isNull);
      expect(SyncSnapshot.decode(utf8.encode(json)), isNull);
      expect(
        () => SyncSnapshot.gunzipLimited(bomb, 1024 * 1024),
        throwsFormatException,
      );
    });

    test('i registri veri si leggono come prima', () {
      final s = SyncSnapshot(device: 'PC', installId: 'abc');
      s.table('courses')['c:1'] = SyncEntry(
        values: {'name': 'Analisi 1'},
        times: {'name': 10},
      );
      final back = SyncSnapshot.decode(s.encode());
      expect(back, isNotNull);
      expect(back!.encodeJson(), s.encodeJson());
      // gzip troncato a metà: registro ignorato, nessuna eccezione
      final cut = s.encode();
      expect(SyncSnapshot.decode(cut.sublist(0, cut.length ~/ 2)), isNull);
    });
  });

  group('5. programmi e modelli scaricati: impronta controllata', () {
    test('whisper.cpp: un archivio diverso da quello atteso non si estrae '
        'né si avvia', () async {
      final zip = ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile.string('Release/whisper-cli.exe', 'MZ finto')),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.contentLength = zip.length;
        req.response.add(zip);
        await req.response.close();
      });
      final url = Uri.parse(
        'http://127.0.0.1:${server.port}/whisper-bin-x64.zip',
      );
      WhisperService service(String sha) => WhisperService(
        baseDir: () async => tmp,
        host: WhisperHost.windows,
        freeSpace: (_) async => null,
        binariesUrl: url,
        binariesSha256: sha,
      );

      final wrong = service('0' * 64);
      await expectLater(
        wrong.installCli().drain<void>(),
        throwsA(
          isA<WhisperException>().having(
            (e) => e.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      expect(await wrong.findCli(), isNull);

      final right = service(sha256.convert(zip).toString());
      await right.installCli().drain<void>();
      expect(await right.findCli(), isNotNull);
    });

    test('l\'archivio ufficiale ha la sua impronta; un indirizzo scelto a '
        'mano no', () {
      expect(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(WhisperService.defaultBinariesSha256),
        isTrue,
      );
      expect(
        WhisperService(baseDir: () async => tmp).binariesSha256,
        WhisperService.defaultBinariesSha256,
      );
      expect(
        WhisperService(
          baseDir: () async => tmp,
          binariesUrl: Uri.parse('https://esempio.it/w.zip'),
        ).binariesSha256,
        isNull,
      );
    });

    test('ffmpeg: versione fissa (non «latest») con la sua impronta', () {
      final url = WhisperService.defaultFfmpegUrl.toString();
      expect(url, isNot(contains('/latest/')));
      expect(url, isNot(contains('master-latest')));
      expect(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(WhisperService.defaultFfmpegSha256),
        isTrue,
      );
      expect(
        WhisperService(baseDir: () async => tmp).ffmpegSha256,
        WhisperService.defaultFfmpegSha256,
      );
      expect(
        WhisperService(
          baseDir: () async => tmp,
          ffmpegUrl: Uri.parse('https://esempio.it/f.zip'),
        ).ffmpegSha256,
        isNull,
      );
    });

    test('ogni modello Whisper scaricabile ha un\'impronta da verificare', () {
      for (final m in [...kWhisperModels, kLiveWhisperModel]) {
        final has =
            (m.sha1?.isNotEmpty ?? false) || (m.sha256?.isNotEmpty ?? false);
        expect(has, isTrue, reason: m.id);
        if (m.sha256 != null) {
          expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(m.sha256!), isTrue);
        }
        if (m.sha1 != null) {
          expect(RegExp(r'^[0-9a-f]{40}$').hasMatch(m.sha1!), isTrue);
        }
      }
    });
  });
}
