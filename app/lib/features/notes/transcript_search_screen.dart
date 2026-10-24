import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/text_limits.dart';
import '../../core/services/app_services.dart';
import '../../models/course.dart';
import '../../utils/safe_text.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../study/course_catalog.dart';
import 'note_viewer_screen.dart';
import 'notes_store.dart';
import 'recording_player_screen.dart';
import 'safe_files.dart';

/// Frammento del testo intorno alla prima occorrenza di [query] (null se
/// non c'è): «…poco prima **query** poco dopo…».
String? searchSnippet(
  String text,
  String query, {
  int before = 40,
  int after = 60,
  String? lower,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return null;
  // [lower]: [text] già in minuscolo (calcolato una volta sola)
  final i = (lower ?? text.toLowerCase()).indexOf(q);
  if (i < 0) return null;
  final a = (i - before).clamp(0, text.length);
  final b = (i + q.length + after).clamp(0, text.length);
  return '${a > 0 ? '…' : ''}'
      '${safeSlice(text, a, b).replaceAll(RegExp(r'\s+'), ' ').trim()}'
      '${b < text.length ? '…' : ''}';
}

/// Testo della trascrizione senza titolo, sottotitolo e tempi.
String transcriptBody(String md) => md
    .split('\n')
    .where((l) {
      final t = l.trim();
      return !t.startsWith('#') && !(t.startsWith('_') && t.endsWith('_'));
    })
    .map((l) => l.replaceFirst(RegExp(r'^\s*\[\d{1,2}:\d{2}:\d{2}\]\s*'), ''))
    .join('\n')
    .trim();

class _Item {
  _Item(this.course, this.transcript, this.audio, this.text)
    : lower = text.toLowerCase(),
      name = transcript.title.toLowerCase();
  final Course course;
  final NoteFile transcript;
  final NoteFile? audio;
  final String text;

  /// Testo e nome in minuscolo, calcolati una volta: a ogni lettera
  /// scritta si cercava rifacendo il minuscolo di tutte le trascrizioni
  /// (centinaia di lezioni: decine di milioni di caratteri copiati per
  /// tasto, sul filo dell'interfaccia).
  final String lower;
  final String name;
}

/// Ricerca nelle trascrizioni di tutte le registrazioni (Registra → lente).
class TranscriptSearchScreen extends StatefulWidget {
  const TranscriptSearchScreen({super.key});

  @override
  State<TranscriptSearchScreen> createState() => _TranscriptSearchScreenState();
}

class _TranscriptSearchScreenState extends State<TranscriptSearchScreen> {
  late final AppServices _s = context.read<AppServices>();
  final _query = TextEditingController();
  late final Future<List<_Item>> _items = _index();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<List<_Item>> _index() async {
    final catalog = await CourseCatalog.load(_s);
    final out = <_Item>[];
    for (final c in catalog.courses) {
      final files = await _s.notes.list(c);
      final audio = {
        for (final a in files[NoteFolder.recordings]!)
          if (a.isAudio) a.name: a,
      };
      for (final t in files[NoteFolder.transcripts]!) {
        if (t.extension != '.md') continue;
        String text;
        try {
          text = transcriptBody(await readTextLenient(t.file));
        } on FileSystemException {
          continue;
        }
        out.add(_Item(c, t, audio[t.name], text));
      }
    }
    return out;
  }

  Future<void> _open(_Item it, String q) async {
    final audio = it.audio;
    if (audio != null) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RecordingPlayerScreen(
            course: it.course,
            file: audio.file,
            query: q,
          ),
        ),
      );
    } else {
      await openNote(context, it.course, it.transcript, query: q);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          inputFormatters: TextLimits.max(TextLimits.search),
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Cerca nelle trascrizioni',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
          ),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          if (_query.text.isNotEmpty)
            IconButton(
              tooltip: 'Cancella',
              icon: const Icon(Icons.close),
              onPressed: () => setState(_query.clear),
            ),
        ],
      ),
      body: FutureBuilder<List<_Item>>(
        future: _items,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data ?? const <_Item>[];
          final q = _query.text.trim();
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.subtitles_off_outlined,
              message: 'Nessuna trascrizione salvata.',
            );
          }
          if (q.length < 2) {
            return EmptyState(
              icon: Icons.search,
              message:
                  'Scrivi almeno due lettere: cerco in ${items.length} '
                  '${items.length == 1 ? 'trascrizione' : 'trascrizioni'}.',
            );
          }
          final lq = q.toLowerCase();
          final hits = <(_Item, String?)>[
            for (final it in items)
              if (searchSnippet(it.text, q, lower: it.lower) case final snip?)
                (it, snip)
              else if (it.name.contains(lq))
                (it, null),
          ];
          if (hits.isEmpty) {
            return const EmptyState(
              icon: Icons.search_off,
              message: 'Nessuna trascrizione contiene questo testo.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
            children: [
              GlassCard(
                child: Column(
                  children: [
                    for (final (it, snip) in hits)
                      ListTile(
                        leading: Icon(
                          it.audio != null
                              ? Icons.graphic_eq
                              : Icons.article_outlined,
                          color: theme.colorScheme.primary,
                        ),
                        title: Text(it.transcript.title),
                        subtitle: Text(
                          // solo il nome dell'insegnamento
                          [it.course.name, ?snip].join('\n'),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: snip != null,
                        onTap: () => _open(it, q),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
