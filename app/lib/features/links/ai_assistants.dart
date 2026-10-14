/// AI di riferimento dello studente: l'app propone il prompt e i file da
/// allegare e apre l'app sul telefono o il sito sul PC. Nessuna chiave: si
/// usa l'account che lo studente ha già.
library;

enum ReferenceAi {
  chatgpt(
    label: 'ChatGPT',
    web: 'https://chatgpt.com/',
    // Parametro `q` documentato da OpenAI (link «chatgpt.com/?q=»).
    prefill: 'https://chatgpt.com/?q=',
    androidPackage: 'com.openai.chatgpt',
    iosAppStoreId: '6448311069',
  ),
  claude(
    label: 'Claude',
    web: 'https://claude.ai/new',
    // `claude.ai/new?q=` apre una nuova chat con il testo precompilato.
    prefill: 'https://claude.ai/new?q=',
    androidPackage: 'com.anthropic.claude',
    iosAppStoreId: '6473753684',
  ),
  copilot(
    label: 'Microsoft Copilot',
    web: 'https://copilot.microsoft.com/',
    androidPackage: 'com.microsoft.copilot',
    iosAppStoreId: '6472538445',
  ),
  perplexity(
    label: 'Perplexity',
    web: 'https://www.perplexity.ai/',
    // `perplexity.ai/search?q=` documentato da Perplexity.
    prefill: 'https://www.perplexity.ai/search?q=',
    androidPackage: 'ai.perplexity.app.android',
    iosAppStoreId: '1668000334',
  ),
  notebooklm(
    label: 'NotebookLM',
    web: 'https://notebooklm.google.com/',
    androidPackage: 'com.google.android.apps.labs.language.tailwind',
    iosAppStoreId: '6737527615',
  ),
  gemini(
    label: 'Gemini',
    web: 'https://gemini.google.com/app',
    androidPackage: 'com.google.android.apps.bard',
    iosAppStoreId: '6477489729',
  );

  const ReferenceAi({
    required this.label,
    required this.web,
    this.prefill,
    required this.androidPackage,
    required this.iosAppStoreId,
  });

  final String label;

  /// Sito (desktop) e link universale/App Link (telefono).
  final String web;

  /// Indirizzo con il testo precompilato (null = solo appunti).
  final String? prefill;
  final String androidPackage;
  final String iosAppStoreId;

  static const defaultAi = ReferenceAi.chatgpt;

  /// Oltre questa lunghezza (codificata) il testo non va nell'indirizzo:
  /// alcuni siti troncano o rifiutano URL lunghi. Si usa solo gli appunti.
  static const maxPrefillChars = 1800;

  static ReferenceAi parse(String? v) {
    for (final a in values) {
      if (a.name == v) return a;
    }
    return defaultAi;
  }

  Uri get webUri => Uri.parse(web);

  Uri get playStoreUri => Uri.parse(
    'https://play.google.com/store/apps/details?id=$androidPackage',
  );

  Uri get appStoreUri =>
      Uri.parse('https://apps.apple.com/app/id$iosAppStoreId');

  /// Indirizzo con [prompt] precompilato, se l'AI lo supporta e il testo è
  /// abbastanza corto; altrimenti null.
  Uri? prefillUri(String prompt) {
    final base = prefill;
    if (base == null) return null;
    final encoded = Uri.encodeQueryComponent(prompt);
    if (encoded.length > maxPrefillChars) return null;
    return Uri.parse('$base$encoded');
  }

  /// Breve indicazione di cosa fare dopo l'apertura.
  String get hint => switch (this) {
    ReferenceAi.notebooklm =>
      'In NotebookLM crea un taccuino, aggiungi il file come fonte e incolla '
          'la richiesta nella chat.',
    ReferenceAi.copilot =>
      'In Copilot allega il file con «+» e incolla la richiesta.',
    _ =>
      'Allega il file (se c\'è) e incolla la richiesta, se non è già scritta.',
  };
}
