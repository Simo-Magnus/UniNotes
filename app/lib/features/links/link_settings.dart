import '../../repositories/settings_repository.dart';
import 'ai_assistants.dart';

/// Chiavi delle impostazioni della sezione Collegamenti (tabella
/// `app_settings`, come le altre impostazioni).
abstract final class LinkKeys {
  static const referenceAi = 'links_reference_ai';
}

extension LinkSettings on SettingsRepository {
  Future<ReferenceAi> referenceAi() async =>
      ReferenceAi.parse(await get(LinkKeys.referenceAi));

  Future<void> setReferenceAi(ReferenceAi ai) =>
      set(LinkKeys.referenceAi, ai.name);
}
