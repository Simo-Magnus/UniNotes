import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agenda.dart';
import 'notification_plan.dart';

/// Chiave dei dati dei widget nelle SharedPreferences di Flutter: su
/// Android il plugin la salva nel file «FlutterSharedPreferences» come
/// «flutter.uninotes_widget_data», dove la legge il widget nativo
/// (UpcomingExamsWidget.kt).
const String kWidgetDataKey = 'uninotes_widget_data';

/// Dati del widget «Prossime prove» (JSON): le prossime 3 prove con i
/// giorni mancanti e dove porta il tocco. Funzione pura.
Map<String, Object?> widgetPayload(List<AgendaItem> agenda, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final exams = [
    for (final i in agenda)
      if (i.kind != AgendaKind.session && i.examId != null) i,
  ].take(3);
  String days(int n) => switch (n) {
    0 => 'Oggi',
    1 => 'Domani',
    _ => 'Tra $n giorni',
  };
  // giorni di calendario, non blocchi di 24 ore: con il cambio dell'ora
  // legale fra oggi e la prova (giornata di 23 ore) «Tra 2 giorni» non
  // diventa «Domani»
  int daysTo(DateTime d) => DateTime.utc(
    d.year,
    d.month,
    d.day,
  ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  return {
    'version': 1,
    'updated': now.toIso8601String(),
    'exams': [
      for (final e in exams)
        {
          'id': e.examId,
          'title': e.subject,
          'kind': e.kind == AgendaKind.midterm ? 'Prova in itinere' : 'Esame',
          'date': italianDate(e.date, weekday: true),
          // il widget ricalcola i giorni mancanti ogni giorno da qui
          'isoDate':
              '${e.date.year.toString().padLeft(4, '0')}-'
              '${e.date.month.toString().padLeft(2, '0')}-'
              '${e.date.day.toString().padLeft(2, '0')}',
          'time': e.time,
          'days': daysTo(e.date),
          'daysLabel': days(daysTo(e.date)),
          'route': AppRoutes.exam(e.examId!),
        },
    ],
    'emptyText': 'Nessuna prova in programma',
    'route': AppRoutes.exams,
  };
}

/// Ponte con i widget della schermata Home: Android (AppWidgetProvider in
/// Kotlin), iOS e macOS (WidgetKit, App Group). Su Windows non ci sono
/// widget (servirebbe un pacchetto MSIX).
class HomeWidgetBridge {
  HomeWidgetBridge([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'io.github.simomagnus.universitynotes/widgets';
  final MethodChannel _channel;

  static bool get supported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  String? _last;

  /// Scrive i dati e chiede al sistema di ridisegnare i widget (solo se
  /// sono cambiati).
  Future<void> update(Map<String, Object?> payload) async {
    if (!supported) return;
    final data = Map.of(payload)..remove('updated');
    final json = jsonEncode(data);
    if (json == _last) return;
    try {
      if (Platform.isAndroid) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(kWidgetDataKey, json);
        await _channel.invokeMethod<void>('update');
      } else {
        // iOS/macOS: UserDefaults dell'App Group, scritto dal lato nativo
        await _channel.invokeMethod<void>('update', {'json': json});
      }
      _last = json;
    } on MissingPluginException {
      // build senza il codice nativo dei widget
    } catch (e) {
      debugPrint('Widget non aggiornati: $e');
    }
  }

  /// Percorso aperto da un widget (es. `registra`, `prova:12`), una volta.
  Future<String?> takeRoute() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('takeRoute');
    } catch (_) {
      return null;
    }
  }

  /// Tocchi sui widget con l'app già aperta.
  void listen(void Function(String route) onRoute) {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'route' && call.arguments is String) {
        onRoute(call.arguments as String);
      }
    });
  }
}
