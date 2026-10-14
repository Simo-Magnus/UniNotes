/// Tabella dei modelli Whisper (formato ggml di whisper.cpp) scaricabili
/// dall'app.
///
/// Fonti (consultate il 04/10/2026):
/// - peso su disco e SHA-1: whisper.cpp `models/README.md` («Available
///   models»), https://github.com/ggml-org/whisper.cpp/tree/master/models;
///   elenco completo (anche q5_0/q8_0): `models/download-ggml-model.sh`.
///   I pesi delle varianti non in tabella (medium-q5_0, medium-q8_0,
///   large-v2-q8_0, large-v3-turbo-q8_0) sono quelli dei file su Hugging
///   Face, arrotondati («≈»), senza SHA pubblicato.
/// - RAM: whisper.cpp `README.md` («Memory usage»: tiny ~273 MB, base
///   ~388 MB, small ~852 MB, medium ~2,1 GB, large ~3,9 GB); per turbo e
///   quantizzati è una stima (peso del file + ~0,4 GB di buffer).
/// - parametri, VRAM (PyTorch) e velocità relativa a large: OpenAI whisper
///   `README.md` («Available models and languages»), misurati in inglese su
///   A100: in italiano e su CPU i tempi reali sono diversi.
/// - qualità in italiano: indicativa, dai grafici WER per lingua (FLEURS /
///   Common Voice) dell'articolo di Whisper (arXiv 2212.04356, App. D) e
///   del README di OpenAI; valori arrotondati, solo per confronto.
/// - distil-large-v3: https://huggingface.co/distil-whisper/distil-large-v3-ggml
///   (distillato su dati inglesi: non adatto all'italiano).
///
/// Per aggiornare: aggiungere/modificare una riga di [kWhisperModels].
library;

/// Dove ha senso usare il modello.
enum WhisperPlatform {
  pc('PC'),
  mac('Mac'),
  phone('Telefono');

  const WhisperPlatform(this.label);
  final String label;
}

class WhisperModelInfo {
  const WhisperModelInfo({
    required this.id,
    required this.params,
    required this.disk,
    required this.approxBytes,
    required this.ram,
    required this.gpu,
    required this.speed,
    required this.italian,
    required this.multilingual,
    required this.italianOk,
    required this.minHardware,
    required this.platforms,
    this.sha1,
    this.quantized = false,
    this.repo = defaultRepo,
    this.note,
  });

  /// Nome del modello in whisper.cpp (es. `large-v3-turbo-q5_0`).
  final String id;

  /// Parametri del modello originale (es. «809 M»).
  final String params;

  /// Peso del file su disco come mostrato (es. «547 MiB»).
  final String disk;

  /// Dimensione approssimata in byte (controllo dello spazio libero).
  final int approxBytes;

  /// RAM necessaria durante la trascrizione.
  final String ram;

  /// GPU/VRAM consigliata (whisper.cpp funziona anche solo con la CPU).
  final String gpu;

  /// Velocità relativa a large (OpenAI, inglese su A100).
  final String speed;

  /// Qualità in italiano (indicativa).
  final String italian;

  /// Multilingue (false = solo inglese).
  final bool multilingual;

  /// Adatto alle lezioni in italiano.
  final bool italianOk;

  /// Hardware minimo consigliato.
  final String minHardware;
  final Set<WhisperPlatform> platforms;

  /// SHA-1 pubblicato da whisper.cpp (null = non verificabile).
  final String? sha1;
  final bool quantized;

  /// Repository Hugging Face che contiene il file.
  final String repo;
  final String? note;

  static const defaultRepo = 'ggerganov/whisper.cpp';

  String get fileName => 'ggml-$id.bin';

  /// Indirizzo di download (sempre il file esatto, ramo main).
  Uri get downloadUrl =>
      Uri.parse('https://huggingface.co/$repo/resolve/main/$fileName');

  /// Pagina del file su Hugging Face.
  Uri get pageUrl =>
      Uri.parse('https://huggingface.co/$repo/blob/main/$fileName');

  /// Pagina ufficiale del modello: OpenAI (huggingface.co/openai) per i
  /// modelli Whisper; per i distillati la pagina dei loro autori. Il file da
  /// scaricare resta quello ggml di whisper.cpp ([downloadUrl]): i pesi
  /// pubblicati da OpenAI sono in formato PyTorch, che whisper.cpp non legge.
  Uri get officialPageUrl {
    if (id.startsWith('distil-')) {
      return Uri.parse('https://huggingface.co/distil-whisper/$id');
    }
    final base = id.replaceAll(RegExp(r'-q\d_\d$'), '');
    final name = base == 'large-v1' ? 'large' : base;
    return Uri.parse('https://huggingface.co/openai/whisper-$name');
  }

  String get languages =>
      multilingual ? 'Multilingue (99 lingue)' : 'Solo inglese';

  bool runsOn(WhisperPlatform p) => platforms.contains(p);
}

const _mib = 1024 * 1024;

const _all = {WhisperPlatform.pc, WhisperPlatform.mac, WhisperPlatform.phone};
const _desktop = {WhisperPlatform.pc, WhisperPlatform.mac};

/// Tutti i modelli mostrati nella tabella, dal più leggero.
const List<WhisperModelInfo> kWhisperModels = [
  WhisperModelInfo(
    id: 'tiny',
    params: '39 M',
    disk: '75 MiB',
    approxBytes: 75 * _mib,
    ram: '~273 MB',
    gpu: 'Non serve',
    speed: '~10×',
    italian: 'Scarsa (WER ~30–40%): solo per prove',
    multilingual: true,
    italianOk: true,
    minHardware: 'Qualsiasi PC; anche telefoni datati',
    platforms: _all,
    sha1: 'bd577a113a864445d4c299885e0cb97d4ba92b5f',
  ),
  WhisperModelInfo(
    id: 'base',
    params: '74 M',
    disk: '142 MiB',
    approxBytes: 142 * _mib,
    ram: '~388 MB',
    gpu: 'Non serve',
    speed: '~7×',
    italian: 'Bassa (WER ~20–30%): comprensibile, molti errori',
    multilingual: true,
    italianOk: true,
    minHardware: 'Telefono recente (4 GB RAM); PC con 4 GB RAM',
    platforms: _all,
    sha1: '465707469ff3a37a2b9b8d8f89f2f99de7299dac',
  ),
  WhisperModelInfo(
    id: 'small',
    params: '244 M',
    disk: '466 MiB',
    approxBytes: 466 * _mib,
    ram: '~852 MB',
    gpu: 'Facoltativa (≥ 2 GB)',
    speed: '~4×',
    italian: 'Discreta (WER ~10–15%): buona per ripassare',
    multilingual: true,
    italianOk: true,
    minHardware: 'Telefono di fascia alta (6 GB RAM); PC con 8 GB RAM',
    platforms: _all,
    sha1: '55356645c2b361a969dfd0ef2c5a50d530afd8d5',
  ),
  WhisperModelInfo(
    id: 'medium',
    params: '769 M',
    disk: '1,5 GiB',
    approxBytes: 1533 * _mib,
    ram: '~2,1 GB',
    gpu: 'Consigliata ≥ 4 GB (PyTorch ~5 GB)',
    speed: '~2×',
    italian: 'Buona (WER ~6–8%)',
    multilingual: true,
    italianOk: true,
    minHardware: 'PC con 8 GB RAM (16 consigliati); Mac Apple Silicon',
    platforms: _desktop,
    sha1: 'fd9727b6e1217c2f614f9b698455c4ffd82463b4',
  ),
  WhisperModelInfo(
    id: 'medium-q5_0',
    params: '769 M',
    disk: '≈ 514 MiB',
    approxBytes: 514 * _mib,
    ram: '~0,9 GB (stima)',
    gpu: 'Facoltativa (≥ 2 GB)',
    speed: '~2× (più veloce su CPU)',
    italian: 'Buona (quasi come medium)',
    multilingual: true,
    italianOk: true,
    minHardware: 'PC con 8 GB RAM; telefono di fascia alta (8 GB RAM, lento)',
    platforms: _all,
    quantized: true,
  ),
  WhisperModelInfo(
    id: 'medium-q8_0',
    params: '769 M',
    disk: '≈ 785 MiB',
    approxBytes: 785 * _mib,
    ram: '~1,2 GB (stima)',
    gpu: 'Facoltativa (≥ 2 GB)',
    speed: '~2×',
    italian: 'Buona (praticamente come medium)',
    multilingual: true,
    italianOk: true,
    minHardware: 'PC con 8 GB RAM; Mac Apple Silicon',
    platforms: _desktop,
    quantized: true,
  ),
  WhisperModelInfo(
    id: 'large-v1',
    params: '1550 M',
    disk: '2,9 GiB',
    approxBytes: 2951 * _mib,
    ram: '~3,9 GB',
    gpu: 'Consigliata ≥ 6 GB (PyTorch ~10 GB)',
    speed: '1×',
    italian: 'Molto buona (WER ~5–6%), superata da v2/v3',
    multilingual: true,
    italianOk: true,
    minHardware: 'PC con 16 GB RAM o GPU ≥ 6 GB; Mac Apple Silicon 16 GB',
    platforms: _desktop,
    sha1: 'b1caaf735c4cc1429223d5a74f0f4d0b9b59a299',
  ),
  WhisperModelInfo(
    id: 'large-v2',
    params: '1550 M',
    disk: '2,9 GiB',
    approxBytes: 2951 * _mib,
    ram: '~3,9 GB',
    gpu: 'Consigliata ≥ 6 GB (PyTorch ~10 GB)',
    speed: '1×',
    italian: 'Ottima (WER ~4–5%)',
    multilingual: true,
    italianOk: true,
    minHardware: 'PC con 16 GB RAM o GPU ≥ 6 GB; Mac Apple Silicon 16 GB',
    platforms: _desktop,
    sha1: '0f4c8e34f21cf1a914c59d8b3ce882345ad349d6',
  ),
  WhisperModelInfo(
    id: 'large-v2-q5_0',
    params: '1550 M',
    disk: '1,1 GiB',
    approxBytes: 1080 * _mib,
    ram: '~1,6 GB (stima)',
    gpu: 'Facoltativa (≥ 4 GB)',
    speed: '1× (più veloce su CPU)',
    italian: 'Ottima (quasi come large-v2)',
    multilingual: true,
    italianOk: true,
    minHardware: 'PC con 8 GB RAM; Mac Apple Silicon',
    platforms: _desktop,
    sha1: '00e39f2196344e901b3a2bd5814807a769bd1630',
    quantized: true,
  ),
  WhisperModelInfo(
    id: 'large-v2-q8_0',
    params: '1550 M',
    disk: '≈ 1,5 GiB',
    approxBytes: 1580 * _mib,
    ram: '~2,0 GB (stima)',
    gpu: 'Facoltativa (≥ 4 GB)',
    speed: '1×',
    italian: 'Ottima (come large-v2)',
    multilingual: true,
    italianOk: true,
    minHardware: 'PC con 8 GB RAM (16 consigliati); Mac Apple Silicon',
    platforms: _desktop,
    quantized: true,
  ),
  WhisperModelInfo(
    id: 'large-v3',
    params: '1550 M',
    disk: '2,9 GiB',
    approxBytes: 2951 * _mib,
    ram: '~3,9 GB',
    gpu: 'Consigliata ≥ 6 GB (PyTorch ~10 GB)',
    speed: '1×',
    italian: 'Ottima (WER ~3–4%): la più precisa',
    multilingual: true,
    italianOk: true,
    minHardware: 'PC con 16 GB RAM o GPU ≥ 6 GB; Mac Apple Silicon 16 GB',
    platforms: _desktop,
    sha1: 'ad82bf6a9043ceed055076d0fd39f5f186ff8062',
  ),
  WhisperModelInfo(
    id: 'large-v3-q5_0',
    params: '1550 M',
    disk: '1,1 GiB',
    approxBytes: 1080 * _mib,
    ram: '~1,6 GB (stima)',
    gpu: 'Facoltativa (≥ 4 GB)',
    speed: '1× (più veloce su CPU)',
    italian: 'Ottima (quasi come large-v3)',
    multilingual: true,
    italianOk: true,
    minHardware: 'PC con 8 GB RAM; Mac Apple Silicon',
    platforms: _desktop,
    sha1: 'e6e2ed78495d403bef4b7cff42ef4aaadcfea8de',
    quantized: true,
  ),
  WhisperModelInfo(
    id: 'large-v3-turbo',
    params: '809 M',
    disk: '1,5 GiB',
    approxBytes: 1549 * _mib,
    ram: '~2,0 GB (stima)',
    gpu: 'Consigliata ≥ 4 GB (PyTorch ~6 GB)',
    speed: '~8×',
    italian: 'Ottima (WER ~4–5%), molto più veloce di large-v3',
    multilingual: true,
    italianOk: true,
    minHardware: 'PC con 8 GB RAM; Mac Apple Silicon',
    platforms: _desktop,
    sha1: '4af2b29d7ec73d781377bfd1758ca957a807e941',
  ),
  WhisperModelInfo(
    id: 'large-v3-turbo-q5_0',
    params: '809 M',
    disk: '547 MiB',
    approxBytes: 547 * _mib,
    ram: '~1,0 GB (stima)',
    gpu: 'Facoltativa (≥ 2 GB)',
    speed: '~8× (più veloce su CPU)',
    italian: 'Ottima (quasi come large-v3-turbo)',
    multilingual: true,
    italianOk: true,
    minHardware: 'PC con 8 GB RAM; Mac Apple Silicon; telefono di fascia alta (8 GB RAM, lento)',
    platforms: _all,
    sha1: 'e050f7970618a659205450ad97eb95a18d69c9ee',
    quantized: true,
  ),
  WhisperModelInfo(
    id: 'large-v3-turbo-q8_0',
    params: '809 M',
    disk: '≈ 834 MiB',
    approxBytes: 834 * _mib,
    ram: '~1,3 GB (stima)',
    gpu: 'Facoltativa (≥ 2 GB)',
    speed: '~8×',
    italian: 'Ottima (come large-v3-turbo)',
    multilingual: true,
    italianOk: true,
    minHardware: 'PC con 8 GB RAM; Mac Apple Silicon',
    platforms: _desktop,
    quantized: true,
  ),
];

/// Modello consigliato: large-v3-turbo q5_0 su PC/Mac, small sul telefono.
const kRecommendedDesktopModel = 'large-v3-turbo-q5_0';
const kRecommendedPhoneModel = 'small';

/// Alternativa leggera per telefoni meno recenti.
const kLightPhoneModel = 'base';

WhisperModelInfo? whisperModelById(String? id) {
  for (final m in kWhisperModels) {
    if (m.id == id) return m;
  }
  return null;
}

WhisperModelInfo recommendedWhisperModel({required bool phone}) =>
    whisperModelById(
      phone ? kRecommendedPhoneModel : kRecommendedDesktopModel,
    )!;

/// Modelli da mostrare su [platform]; quelli solo inglese solo se richiesti.
List<WhisperModelInfo> whisperModelsFor(WhisperPlatform platform) => [
  for (final m in kWhisperModels)
    if (m.runsOn(platform) && m.italianOk) m,
];
