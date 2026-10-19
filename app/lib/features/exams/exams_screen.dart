import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../core/theme/app_theme.dart';
import '../../models/exam.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import 'averages_tab.dart';
import 'exam_detail.dart';
import 'exam_form.dart';
import 'exam_stats.dart';
import 'pending_exams_tab.dart';
import 'taken_exams_tab.dart';

/// Sezione Esami: "Da sostenere", "Sostenuti", "Medie".
/// Su schermi larghi (Windows) mostra il dettaglio della prova a destra.
class ExamsScreen extends StatefulWidget {
  const ExamsScreen({super.key});

  @override
  State<ExamsScreen> createState() => _ExamsScreenState();
}

class _ExamsScreenState extends State<ExamsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this)
    ..addListener(() {
      if (!_tabs.indexIsChanging) setState(() {});
    });
  int? _selectedId;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _select(Exam e) {
    if (e.id == null) return;
    if (context.isWide) {
      setState(() => _selectedId = e.id);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ExamDetailScreen(examId: e.id!)),
      );
    }
  }

  /// «Nuova prova»: due scelte. L'esame a scelta fuori piano si indica nel
  /// modulo dell'esame finale (ultima voce del menù del corso).
  Future<void> _add() async {
    final kind = await showModalBottomSheet<ExamKind>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Esame finale'),
              subtitle: const Text('Anche un esame a scelta fuori piano'),
              onTap: () => Navigator.pop(c, ExamKind.finalExam),
            ),
            ListTile(
              leading: const Icon(Icons.timelapse),
              title: const Text('Prova in itinere o Esonero'),
              onTap: () => Navigator.pop(c, ExamKind.midterm),
            ),
          ],
        ),
      ),
    );
    if (!mounted || kind == null) return;
    await openExamForm(context, kind: kind);
  }

  @override
  Widget build(BuildContext context) {
    final wide = context.isWide;
    final showDetail = wide && _tabs.index != 2;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Esami'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Da sostenere', icon: Icon(Icons.event_note_outlined)),
            Tab(
              text: 'Sostenuti',
              icon: Icon(Icons.assignment_turned_in_outlined),
            ),
            Tab(text: 'Medie', icon: Icon(Icons.calculate_outlined)),
          ],
        ),
      ),
      floatingActionButton: GlowFab(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Nuova prova'),
      ),
      body: RevisionBuilder<ExamsData>(
        load: loadExamsData,
        builder: (context, data) {
          if (data.courses.isEmpty) {
            return const EmptyState(
              icon: Icons.school_outlined,
              message: 'Nessun corso presente.\nAggiungi i tuoi corsi nella sezione Insegnamenti o aggiorna il database in Impostazioni.',
            );
          }
          final tabs = TabBarView(
            controller: _tabs,
            children: [
              PendingExamsTab(
                data: data,
                selectedId: wide ? _selectedId : null,
                onSelect: _select,
              ),
              TakenExamsTab(
                data: data,
                selectedId: wide ? _selectedId : null,
                onSelect: _select,
              ),
              AveragesTab(data: data, onSelect: _select),
            ],
          );
          if (!showDetail) return tabs;
          return Row(
            children: [
              Expanded(flex: 3, child: tabs),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 2,
                child: _selectedId == null
                    ? const EmptyState(
                        icon: Icons.touch_app_outlined,
                        message: 'Seleziona un esame o una prova per vederne il dettaglio.',
                      )
                    : ExamDetailView(
                        key: ValueKey(_selectedId),
                        examId: _selectedId!,
                        onDeleted: () => setState(() => _selectedId = null),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
