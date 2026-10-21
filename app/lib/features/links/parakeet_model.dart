/// NVIDIA Parakeet TDT 0.6B v3: il motore del testo istantaneo su PC e Mac
/// (Windows, macOS, Linux), con sherpa-onnx (k2-fsa, Apache-2.0).
///
/// Fonti (consultate il 21/10/2026):
/// - modello: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 (600 M
///   parametri, 25 lingue europee compreso l'italiano, punteggiatura e
///   maiuscole, licenza CC-BY-4.0: va citata NVIDIA, vedi
///   [kParakeetAttribution]);
/// - file ONNX int8 per sherpa-onnx (stessi file dell'archivio ufficiale
///   `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2` delle release di
///   k2-fsa/sherpa-onnx, qui scaricati uno per uno per non dover
///   decomprimere un bz2): https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8;
///   pesi e SHA-256 dalla API di Hugging Face (per `tokens.txt`, che non è
///   un file LFS, l'impronta è quella calcolata sul file scaricato);
/// - Silero VAD (MIT): https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx,
///   incluso negli asset delle build desktop.
library;

import 'whisper_models.dart';

/// Un file del modello da scaricare.
class ParakeetFile {
  const ParakeetFile(this.name, this.bytes, this.sha256);
  final String name;
  final int bytes;
  final String sha256;
}

/// Id di Parakeet fra i motori di trascrizione (stesso spazio degli id dei
/// modelli Whisper: «Trascrivi con…», trascrizioni salvate).
const kParakeetId = 'parakeet-tdt-0.6b-v3';

/// Repository Hugging Face con i file per sherpa-onnx.
const kParakeetRepo = 'csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8';

/// Cartella del modello (nome dell'archivio ufficiale di sherpa-onnx).
const kParakeetDir = 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8';

/// Pagina ufficiale del modello (NVIDIA).
const kParakeetPage = 'https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3';

/// Attribuzione richiesta dalla licenza CC-BY-4.0 (pagina delle licenze e
/// card dei collegamenti).
const kParakeetAttribution =
    'Parakeet TDT 0.6B v3 di NVIDIA (nvidia/parakeet-tdt-0.6b-v3), licenza '
    'CC-BY-4.0 (creativecommons.org/licenses/by/4.0), convertito in ONNX '
    'int8 da sherpa-onnx (k2-fsa) senza altre modifiche.';

/// I quattro file, dal più piccolo (la ripresa di un download interrotto
/// riparte dal file a metà).
const kParakeetFiles = [
  ParakeetFile(
    'tokens.txt',
    93939,
    'd58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d',
  ),
  ParakeetFile(
    'joiner.int8.onnx',
    6355277,
    '3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3',
  ),
  ParakeetFile(
    'decoder.int8.onnx',
    11845275,
    '179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e',
  ),
  ParakeetFile(
    'encoder.int8.onnx',
    652184281,
    'acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247',
  ),
];

/// Peso totale dei file (670 MB, 639 MiB).
final int kParakeetBytes = kParakeetFiles.fold(0, (a, f) => a + f.bytes);

Uri parakeetFileUrl(ParakeetFile f) =>
    Uri.parse('https://huggingface.co/$kParakeetRepo/resolve/main/${f.name}');

/// Silero VAD per sherpa-onnx (asset delle build desktop).
const kSileroVadAsset = 'assets/vad/silero_vad.onnx';
const kSileroVadBytes = 643854;
const kSileroVadSha256 =
    '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6';

/// Silero VAD per whisper.cpp (formato ggml, asset di tutte le build):
/// https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
const kWhisperVadAsset = 'assets/vad/ggml-silero-v5.1.2.bin';
const kWhisperVadBytes = 885098;
const kWhisperVadSha256 =
    '29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf';

/// RAM minima del PC per Parakeet: il modello caricato occupa ~1 GB
/// (misurato: 0,97 GB dopo il caricamento, ~1,2 GB mentre trascrive).
const kParakeetMinRam = 4 * 1000 * 1000 * 1000;

/// Parakeet come voce della tabella dei motori (stessi campi dei modelli
/// Whisper): «Trascrivi con…», modello predefinito, tempi stimati. Non è
/// nella tabella dei download di Whisper ([kWhisperModels]): si scarica
/// dalla sua sezione della card (ParakeetService).
const kParakeetModel = WhisperModelInfo(
  id: kParakeetId,
  params: '600 M',
  disk: '639 MiB',
  approxBytes: 670478772,
  ram: '~1,2 GB',
  gpu: 'Non serve',
  speed: '~20× il tempo reale (CPU, 2 thread)',
  italian: 'Ottima (WER ~5% su frasi vere, misurato)',
  multilingual: true,
  italianOk: true,
  minHardware: 'PC o Mac con 4 GB di RAM',
  platforms: {WhisperPlatform.pc, WhisperPlatform.mac},
  note:
      'NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0): testo istantaneo mentre '
      'registri e ripiego di «Trascrivi con…».',
);
