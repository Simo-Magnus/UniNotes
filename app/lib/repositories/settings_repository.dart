import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:sqflite/sqflite.dart';

import '../core/database/app_database.dart';

/// Chiavi note delle impostazioni.
class SettingKeys {
  static const exclusionPatterns = 'exclusion_patterns';
  static const lastDataUpdate = 'last_data_update';
  static const lastDataSource = 'last_data_source';
  static const updateUrl = 'update_url';
  static const appuntiRoot = 'appunti_root';
  static const themeMode = 'theme_mode';
  static const whisperModel = 'whisper_model';
  static const onedriveClientId = 'onedrive_client_id';
  static const onedriveTenant = 'onedrive_tenant';

  /// Indirizzo del database pubblico degli atenei (vuoto = predefinito).
  static const catalogBaseUrl = 'catalog_base_url';

  /// Versione del database (`meta.json`) proposta per l'aggiornamento.
  static const catalogOfferedVersion = 'catalog_offered_version';

  /// Impostazioni della chiave API di Gemini e di Antigravity (`agy`), tolte
  /// dall'app: Gemini si usa solo aprendolo con prompt e file. Si cancellano
  /// una volta ([legacyGeminiRemoved]).
  static const legacyGemini = ['agy_path', 'gemini_model', 'gemini_api_model'];

  /// La pulizia di [legacyGemini] è già stata fatta.
  static const legacyGeminiRemoved = 'legacy_gemini_removed';
}

/// Esclusioni che lo studente può attivare in Impostazioni → Esclusioni
/// (regex senza distinzione maiuscole/minuscole). Nessuna è attiva di
/// default: decide lo studente se è esonerato da OFA o lingua straniera.
class ExclusionPreset {
  const ExclusionPreset(this.id, this.label, this.description, this.patterns);
  final String id;
  final String label;
  final String description;
  final List<String> patterns;
}

const List<ExclusionPreset> kExclusionPresets = [
  ExclusionPreset(
    'ofa',
    'OFA e obblighi formativi',
    'Se li hai già superati o non li devi fare.',
    [r'\bOFA\b', r'obblighi formativi'],
  ),
  ExclusionPreset(
    'lingua',
    'Inglese e lingua straniera',
    'Lezioni ed esami di lingua, se hai una certificazione o un esonero.',
    [r'inglese', r'\benglish\b', r'lingua straniera'],
  ),
  ExclusionPreset(
    'facoltativi',
    'Corsi facoltativi',
    'Insegnamenti segnati come facoltativi nel piano.',
    [r'facoltativ'],
  ),
];

/// Tutti i filtri dei [kExclusionPresets].
final List<String> kAllPresetPatterns = [
  for (final g in kExclusionPresets) ...g.patterns,
];

/// Nessuna esclusione finché lo studente non la sceglie.
const List<String> kDefaultExclusionPatterns = [];

class SettingsRepository {
  SettingsRepository(this._db);
  final AppDatabase _db;

  Future<String?> get(String key) async {
    final rows = await _db.db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : _text(rows.first['value']);
  }

  /// Valore come testo anche se arriva come numero (sincronizzazione o
  /// backup di un'altra versione dell'app).
  static String? _text(Object? v) =>
      v == null || v is String ? v as String? : '$v';

  Future<void> set(String key, String? value) => _db.db.insert('app_settings', {
    'key': key,
    'value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Cancella le impostazioni [keys].
  Future<void> removeKeys(List<String> keys) async {
    if (keys.isEmpty) return;
    await _db.db.delete(
      'app_settings',
      where: 'key IN (${List.filled(keys.length, '?').join(', ')})',
      whereArgs: keys,
    );
  }

  Future<Map<String, String?>> allSettings() async {
    final rows = await _db.db.query('app_settings');
    return {
      for (final r in rows)
        if (r['key'] != null) '${r['key']}': _text(r['value']),
    };
  }

  Future<List<String>> exclusionPatterns() async {
    final raw = await get(SettingKeys.exclusionPatterns);
    if (raw == null) return kDefaultExclusionPatterns;
    try {
      return (jsonDecode(raw) as List).map((e) => e.toString()).toList();
    } catch (_) {
      return kDefaultExclusionPatterns;
    }
  }

  Future<void> setExclusionPatterns(List<String> patterns) =>
      set(SettingKeys.exclusionPatterns, jsonEncode(patterns));
}

/// Cartella degli appunti scelta dall'utente sul PC (vuoto = Documenti\
/// UniNotes, vedi NotesStore.root).
const String kDefaultAppuntiRoot = '';

/// Metodi di comodo aggiunti per Impostazioni e altre schermate.
extension SettingsRepositoryDefaults on SettingsRepository {
  /// Valore dell'impostazione o [fallback] se assente/vuota.
  Future<String> getOr(String key, String fallback) async {
    final v = (await get(key))?.trim();
    return (v == null || v.isEmpty) ? fallback : v;
  }

  /// Cartella Appunti sul PC (registrazioni e appunti dei corsi).
  Future<String> appuntiRoot() =>
      getOr(SettingKeys.appuntiRoot, kDefaultAppuntiRoot);

  /// Toglie tutte le esclusioni (valore predefinito: nessuna).
  Future<void> resetExclusionPatterns() =>
      set(SettingKeys.exclusionPatterns, null);
}

/// "system" | "dark" | "light" → ThemeMode (predefinito: scuro).
ThemeMode parseThemeMode(String? v) => switch (v) {
  'system' => ThemeMode.system,
  'light' => ThemeMode.light,
  _ => ThemeMode.dark,
};
