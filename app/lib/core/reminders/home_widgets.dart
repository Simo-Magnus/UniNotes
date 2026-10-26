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

/// Prove al massimo nel JSON dei widget: il widget più grande ne mostra 6
/// (le altre come «+N», vedi WidgetPlan.kt e UpcomingExamsWidget.kt).
const int kWidgetMaxExams = 6;

/// Dati del widget «Prossime prove» (JSON): le prossime [kWidgetMaxExams]
/// prove con i giorni mancanti, quante sono in tutto (`total`) e dove porta
/// il tocco. Il widget ne mostra quante ne stanno (1 nel 2×2, 3 nel 4×2,
/// fino a 6). Funzione pura.
Map<String, Object?> widgetPayload(List<AgendaItem> agenda, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final all = [
    for (final i in agenda)
      if (i.kind != AgendaKind.session && i.examId != null) i,
  ];
  final exams = all.take(kWidgetMaxExams);
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
    'version': 2,
    'updated': now.toIso8601String(),
    'total': all.length,
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

/// Stato della registrazione per il widget «Registra lezione» (Android).
/// Viaggia con la notifica della registrazione (`show` e `stopped` sul
/// canale `registrazione`, vedi background_controls.dart): un'unica fonte
/// per notifica e widget (RecordingNotification.kt → RecordWidget.kt), qualunque
/// sia il punto da cui la registrazione è partita o finita. Funzione pura.
Map<String, Object?> recordingWidgetState({
  required bool active,
  bool paused = false,
  Duration elapsed = Duration.zero,
  String course = '',
}) => {
  'state': !active ? 'idle' : (paused ? 'paused' : 'recording'),
  'paused': active && paused,
  'elapsedMs': active && !elapsed.isNegative ? elapsed.inMilliseconds : 0,
  'course': active ? course : '',
};

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

  /// Android: riporta l'utente alla schermata Home lasciando l'app aperta
  /// in background (MainActivity.moveTaskToBack), dopo l'avvio della
  /// registrazione dal widget. Altrove non fa nulla (false).
  static Future<bool> moveTaskToBack([MethodChannel? channel]) async {
    if (!Platform.isAndroid) return false;
    try {
      return await (channel ?? const MethodChannel(channelName))
              .invokeMethod<bool>('moveToBack') ??
          false;
    } catch (e) {
      debugPrint('Ritorno alla schermata Home non riuscito: $e');
      return false;
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
