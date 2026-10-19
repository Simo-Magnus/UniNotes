import 'package:flutter/material.dart';

import '../study/focus/focus_quiet_section.dart';
import 'sections/appearance_section.dart';
import 'sections/backup_section.dart';
import 'sections/calendar_section.dart';
import 'sections/exclusions_section.dart';
import 'sections/feedback_section.dart';
import 'sections/notifications_section.dart';
import 'sections/privacy_section.dart';
import 'sections/profile_section.dart';

/// Impostazioni: il mio percorso (con «Cambia corso») e database, calendario,
/// esclusioni, Focus e Non disturbare, aspetto, suoni e vibrazioni,
/// notifiche, esporta/importa dati, privacy e informazioni (con le licenze).
/// Intelligenza artificiale, OneDrive e Google Drive sono in Collegamenti.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// Larghezza oltre la quale le sezioni si dispongono su due colonne.
  static const double twoColumnBreakpoint = 1100;

  static const List<Widget> _left = [
    ProfileSection(),
    CalendarSection(),
    ExclusionsSection(),
    FocusQuietSection(),
  ];

  static const List<Widget> _right = [
    AppearanceSection(),
    FeedbackSection(),
    NotificationsSection(),
    BackupSection(),
    PrivacySection(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= twoColumnBreakpoint) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1400),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: Column(children: _left)),
                      Expanded(child: Column(children: _right)),
                    ],
                  ),
                ),
              ),
            );
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: const [..._left, ..._right],
              ),
            ),
          );
        },
      ),
    );
  }
}
