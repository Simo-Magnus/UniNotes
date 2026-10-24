import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// File WAV PCM a 16 bit: intestazione, scrittura progressiva, riparazione,
/// lettura di un tratto, livelli e taglio. Funzioni pure o quasi (test in
/// test/recorder_logic_test.dart).
///
/// Il registratore scrive l'audio in un WAV «di lavoro» man mano che arriva
/// dal microfono. L'intestazione (dimensioni) si aggiorna a ogni pausa, a
/// ogni stop e ogni pochi secondi; se l'app si chiude di colpo il file resta
/// leggibile e [repairWav] ricalcola le dimensioni dalla lunghezza reale.
class WavInfo {
  const WavInfo({
    required this.sampleRate,
    required this.channels,
    this.bitsPerSample = 16,
    this.dataOffset = 44,
    required this.dataLength,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  /// Inizio dei campioni nel file.
  final int dataOffset;

  /// Byte di audio.
  final int dataLength;

  int get blockAlign => channels * bitsPerSample ~/ 8;
  int get byteRate => sampleRate * blockAlign;

  Duration get duration => byteRate <= 0
      ? Duration.zero
      : Duration(microseconds: dataLength * 1000000 ~/ byteRate);

  /// Byte (dall'inizio dei dati, allineato al campione) dell'istante [t].
  int bytesAt(Duration t) {
    final frames = t.inMicroseconds * sampleRate ~/ 1000000;
    return (frames * blockAlign).clamp(0, dataLength);
  }

  WavInfo withLength(int length) => WavInfo(
    sampleRate: sampleRate,
    channels: channels,
    bitsPerSample: bitsPerSample,
    dataOffset: dataOffset,
    dataLength: length,
  );
}

/// Dimensione massima dei dati di un WAV: i campi dell'intestazione sono a
/// 32 bit (circa 4 GB, ~37 ore a 16 kHz mono).
const int kWavMaxData = 0xFFFFFFFF - 36;

/// [v] nei 32 bit di un campo dell'intestazione: oltre il limite resta il
/// massimo (0xFFFFFFFF = «fino alla fine del file», vedi [parseWavHeader])
/// invece di ricominciare da zero e far sembrare il file cortissimo.
int _u32(int v) => v < 0 ? 0 : (v > 0xFFFFFFFF ? 0xFFFFFFFF : v);

/// Intestazione standard di 44 byte (PCM, little endian).
Uint8List wavHeader({
  required int sampleRate,
  required int channels,
  int bitsPerSample = 16,
  required int dataLength,
}) {
  final b = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  final blockAlign = channels * bitsPerSample ~/ 8;
  tag(0, 'RIFF');
  final data = dataLength > kWavMaxData ? 0xFFFFFFFF : _u32(dataLength);
  b.setUint32(4, data == 0xFFFFFFFF ? 0xFFFFFFFF : 36 + data, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, channels, Endian.little);
  b.setUint32(24, _u32(sampleRate), Endian.little);
  b.setUint32(28, _u32(sampleRate * blockAlign), Endian.little);
  b.setUint16(32, blockAlign, Endian.little);
  b.setUint16(34, bitsPerSample, Endian.little);
  tag(36, 'data');
  b.setUint32(40, data, Endian.little);
  return b.buffer.asUint8List();
}

/// Legge l'intestazione da [head] (i primi byte del file). Con
/// [fileLength] la dimensione dei dati mancante o sbagliata (0, 0xFFFFFFFF,
/// oltre la fine del file) viene ricavata dalla lunghezza reale. null se non
/// è un WAV PCM a 16 bit.
WavInfo? parseWavHeader(Uint8List head, {int? fileLength}) {
  if (head.length < 12) return null;
  final b = ByteData.sublistView(head);
  String tag(int at) => String.fromCharCodes(head.sublist(at, at + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  int? rate, channels, bits;
  var pos = 12;
  while (pos + 8 <= head.length) {
    final id = tag(pos);
    final size = b.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ') {
      if (body + 16 > head.length) return null;
      final format = b.getUint16(body, Endian.little);
      // 1 = PCM, 0xFFFE = WAVE_FORMAT_EXTENSIBLE (PCM nei sottotipi comuni)
      if (format != 1 && format != 0xFFFE) return null;
      channels = b.getUint16(body + 2, Endian.little);
      rate = b.getUint32(body + 4, Endian.little);
      bits = b.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (rate == null ||
          channels == null ||
          bits != 16 ||
          channels == 0 ||
          rate == 0) {
        return null;
      }
      final info = WavInfo(
        sampleRate: rate,
        channels: channels,
        bitsPerSample: 16,
        dataOffset: body,
        dataLength: size,
      );
      if (fileLength == null) return info;
      final available = math.max(0, fileLength - body);
      var length = size;
      if (size == 0 || size == 0xFFFFFFFF || size > available) {
        length = available;
      }
      return info.withLength(length - length % info.blockAlign);
    }
    // i blocchi hanno lunghezza pari (byte di riempimento)
    pos = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

Future<WavInfo?> readWavInfo(File f) async {
  if (!await f.exists()) return null;
  final raf = await f.open();
  try {
    final len = await raf.length();
    final head = await raf.read(math.min(len, 4096));
    return parseWavHeader(head, fileLength: len);
  } finally {
    await raf.close();
  }
}

/// Ripara un WAV rimasto a metà (app chiusa durante la registrazione):
/// dimensioni nell'intestazione ricalcolate dalla lunghezza del file e
/// coda incompleta (mezzo campione) tolta. null se il file non è un WAV.
Future<WavInfo?> repairWav(File f) async {
  final info = await readWavInfo(f);
  if (info == null) return null;
  final raf = await f.open(mode: FileMode.append);
  try {
    final end = info.dataOffset + info.dataLength;
    if (await raf.length() != end) await raf.truncate(end);
    final big = info.dataLength > kWavMaxData;
    final riff = ByteData(4)
      ..setUint32(0, big ? 0xFFFFFFFF : _u32(end - 8), Endian.little);
    await raf.setPosition(4);
    await raf.writeFrom(riff.buffer.asUint8List());
    final data = ByteData(4)
      ..setUint32(0, big ? 0xFFFFFFFF : info.dataLength, Endian.little);
    await raf.setPosition(info.dataOffset - 4);
    await raf.writeFrom(data.buffer.asUint8List());
  } finally {
    await raf.close();
  }
  return info;
}

/// Scrive l'audio in arrivo in un WAV, un pezzo alla volta e in ordine.
/// L'intestazione si aggiorna con [updateHeader] (pause, stop) e da sola ogni
/// [headerEvery] di audio.
class WavWriter {
  WavWriter._(this.file, this._raf, this.sampleRate, this.channels);

  static Future<WavWriter> create(
    File file, {
    required int sampleRate,
    required int channels,
  }) async {
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    await raf.writeFrom(
      wavHeader(sampleRate: sampleRate, channels: channels, dataLength: 0),
    );
    return WavWriter._(file, raf, sampleRate, channels);
  }

  final File file;
  final RandomAccessFile _raf;
  int sampleRate;
  int channels;
  static const headerEvery = Duration(seconds: 5);

  int _bytes = 0;
  int _sinceHeader = 0;
  int? _carry; // byte dispari rimasto da un pezzo precedente
  Future<void> _queue = Future.value();
  bool _closed = false;

  /// Primo errore di scrittura (es. spazio esaurito).
  Object? error;

  int get dataBytes => _bytes;
  int get _blockAlign => channels * 2;
  Duration get duration {
    final rate = sampleRate * _blockAlign;
    return rate <= 0
        ? Duration.zero
        : Duration(microseconds: _bytes * 1000000 ~/ rate);
  }

  /// Formato effettivo scelto dal sistema (prima dei dati). Valori non
  /// validi (0 Hz, nessun canale) si ignorano: resta il formato chiesto.
  void setFormat(int rate, int ch) {
    if (rate <= 0 || ch <= 0) return;
    sampleRate = rate;
    channels = ch;
  }

  void add(Uint8List pcm) {
    if (_closed || pcm.isEmpty) return;
    var data = pcm;
    if (_carry != null) {
      data = Uint8List(pcm.length + 1)
        ..[0] = _carry!
        ..setRange(1, pcm.length + 1, pcm);
      _carry = null;
    }
    if (data.length.isOdd) {
      _carry = data.last;
      data = Uint8List.sublistView(data, 0, data.length - 1);
    }
    if (data.isEmpty) return;
    if (_bytes + data.length > kWavMaxData) {
      // oltre i 4 GB l'intestazione del WAV non può più descrivere i dati:
      // ci si ferma qui (il registratore va in pausa e l'audio fin qui si
      // salva)
      error ??= const WavLimitReached();
      return;
    }
    _bytes += data.length;
    _sinceHeader += data.length;
    final copy = Uint8List.fromList(data);
    final header = _sinceHeader >= headerEvery.inSeconds * sampleRate * 2;
    if (header) _sinceHeader = 0;
    _queue = _queue.then((_) async {
      if (error != null) return;
      try {
        await _raf.writeFrom(copy);
        if (header) await _writeSizes();
      } catch (e) {
        error = e;
      }
    });
  }

  Future<void> _writeSizes() async {
    final end = await _raf.position();
    final head = wavHeader(
      sampleRate: sampleRate,
      channels: channels,
      dataLength: end - 44,
    );
    await _raf.setPosition(0);
    await _raf.writeFrom(head);
    await _raf.setPosition(end);
  }

  /// Intestazione aggiornata e dati sul disco.
  Future<void> updateHeader() {
    _queue = _queue.then((_) async {
      if (_closed) return;
      try {
        await _writeSizes();
        await _raf.flush();
      } catch (e) {
        error ??= e;
      }
    });
    return _queue;
  }

  /// Attende che tutti i pezzi ricevuti siano scritti.
  Future<void> drain() => _queue;

  Future<void> close() async {
    if (_closed) return;
    await updateHeader();
    _closed = true;
    try {
      await _raf.close();
    } catch (_) {}
  }
}

/// Il WAV di lavoro ha raggiunto il limite di 4 GB del formato.
class WavLimitReached implements Exception {
  const WavLimitReached();
  @override
  String toString() =>
      'la registrazione ha raggiunto la lunghezza massima di un file WAV '
      '(4 GB).';
}

/// Campioni a 16 bit di [bytes] (little endian).
Int16List pcm16(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  if (bytes.offsetInBytes.isEven) {
    return Int16List.view(bytes.buffer, bytes.offsetInBytes, n);
  }
  final b = ByteData.sublistView(bytes);
  return Int16List.fromList([
    for (var i = 0; i < n; i++) b.getInt16(i * 2, Endian.little),
  ]);
}

/// Livello 0–1 di un gruppo di campioni: valore efficace in dBFS
/// (−60…0) riportato a 0…1, come l'indicatore del microfono.
double levelOfRms(double rms) {
  if (rms <= 0) return 0;
  final db = 20 * math.log(rms / 32768) / math.ln10;
  return ((db + 60) / 60).clamp(0.0, 1.0);
}

double pcmLevel(Int16List samples) {
  if (samples.isEmpty) return 0;
  var sum = 0.0;
  for (final s in samples) {
    sum += s * s;
  }
  return levelOfRms(math.sqrt(sum / samples.length));
}

/// Accumula i campioni in arrivo e produce un livello ogni [every] (la
/// forma d'onda della registrazione).
class LevelBinner {
  LevelBinner({required int sampleRate, required int channels, Duration? every})
    : _per =
          (sampleRate *
                  channels *
                  (every ?? const Duration(milliseconds: 100)).inMicroseconds ~/
                  1000000)
              .clamp(1, 1 << 30);

  final int _per;
  double _sum = 0;
  int _count = 0;

  /// Aggiunge i campioni e restituisce i livelli dei gruppi completati.
  List<double> add(Int16List samples) {
    final out = <double>[];
    for (final s in samples) {
      _sum += s * s;
      if (++_count >= _per) {
        out.add(levelOfRms(math.sqrt(_sum / _count)));
        _sum = 0;
        _count = 0;
      }
    }
    return out;
  }
}

/// Audio mono a 16 kHz (quello che legge Whisper) da campioni interlacciati
/// a [rate] Hz con [channels] canali: media dei canali e interpolazione
/// lineare.
Int16List toMono16k(Int16List samples, int rate, int channels) {
  if (rate <= 0 || channels <= 0) return Int16List(0);
  final frames = samples.length ~/ channels;
  final mono = Float64List(frames);
  for (var f = 0; f < frames; f++) {
    var v = 0;
    for (var c = 0; c < channels; c++) {
      v += samples[f * channels + c];
    }
    mono[f] = v / channels;
  }
  if (rate == 16000) {
    return Int16List.fromList([for (final v in mono) v.round()]);
  }
  final outLen = (frames * 16000 / rate).floor();
  final out = Int16List(outLen);
  final step = rate / 16000;
  for (var i = 0; i < outLen; i++) {
    final x = i * step;
    final a = x.floor();
    final t = x - a;
    final s0 = mono[math.min(a, frames - 1)];
    final s1 = mono[math.min(a + 1, frames - 1)];
    out[i] = (s0 + (s1 - s0) * t).round().clamp(-32768, 32767);
  }
  return out;
}

/// Campioni del tratto [start]–[end] di un WAV.
Future<Int16List> readWavRange(
  File f,
  WavInfo info,
  Duration start,
  Duration end,
) async {
  final a = info.bytesAt(start);
  final b = info.bytesAt(end);
  if (b <= a) return Int16List(0);
  final raf = await f.open();
  try {
    await raf.setPosition(info.dataOffset + a);
    final bytes = await raf.read(b - a);
    return Int16List.fromList(pcm16(bytes));
  } finally {
    await raf.close();
  }
}

/// WAV mono 16 kHz con i campioni [mono16k].
Future<File> writeWav16k(File out, Int16List mono16k) async {
  final data = mono16k.buffer.asUint8List(
    mono16k.offsetInBytes,
    mono16k.lengthInBytes,
  );
  final sink = out.openWrite();
  sink.add(wavHeader(sampleRate: 16000, channels: 1, dataLength: data.length));
  sink.add(data);
  await sink.close();
  return out;
}

/// Livelli (0–255, uno ogni [every]) di tutto il WAV: la forma d'onda delle
/// registrazioni senza dati salvati. Lavora in un isolate separato.
Future<Uint8List> computePeaks(
  File f, {
  Duration every = const Duration(milliseconds: 100),
}) {
  final path = f.path;
  final everyUs = every.inMicroseconds;
  return Isolate.run(() async {
    final file = File(path);
    final info = await readWavInfo(file);
    if (info == null) return Uint8List(0);
    final binner = LevelBinner(
      sampleRate: info.sampleRate,
      channels: info.channels,
      every: Duration(microseconds: everyUs),
    );
    final out = BytesBuilder(copy: false);
    final raf = await file.open();
    try {
      await raf.setPosition(info.dataOffset);
      var left = info.dataLength;
      const block = 1 << 20;
      while (left > 0) {
        final bytes = await raf.read(math.min(block, left));
        if (bytes.isEmpty) break;
        left -= bytes.length;
        final levels = binner.add(Int16List.fromList(pcm16(bytes)));
        out.add(
          Uint8List.fromList([for (final l in levels) (l * 255).round()]),
        );
      }
    } finally {
      await raf.close();
    }
    return out.takeBytes();
  });
}

/// Copia in [dst] solo i tratti [keep] (in ordine) del WAV [src]: il taglio
/// di inizio, fine o di un tratto centrale.
Future<WavInfo> cutWav(
  File src,
  WavInfo info,
  File dst,
  List<(Duration, Duration)> keep,
) async {
  final ranges = [
    for (final (a, b) in keep)
      if (info.bytesAt(b) > info.bytesAt(a)) (info.bytesAt(a), info.bytesAt(b)),
  ];
  final total = ranges.fold<int>(0, (s, r) => s + r.$2 - r.$1);
  final out = await dst.open(mode: FileMode.write);
  final RandomAccessFile inp;
  try {
    inp = await src.open();
  } catch (_) {
    // originale sparito o bloccato: il file di destinazione non resta aperto
    // (su Windows non si potrebbe più cancellare né rinominare)
    await out.close();
    rethrow;
  }
  try {
    await out.writeFrom(
      wavHeader(
        sampleRate: info.sampleRate,
        channels: info.channels,
        dataLength: total,
      ),
    );
    for (final (a, b) in ranges) {
      await inp.setPosition(info.dataOffset + a);
      var left = b - a;
      while (left > 0) {
        final chunk = await inp.read(math.min(left, 1 << 20));
        if (chunk.isEmpty) break;
        await out.writeFrom(chunk);
        left -= chunk.length;
      }
    }
  } finally {
    await inp.close();
    await out.close();
  }
  return WavInfo(
    sampleRate: info.sampleRate,
    channels: info.channels,
    dataLength: total,
  );
}
