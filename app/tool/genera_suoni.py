"""Suoni dell'app, sintetizzati da codice (nessun file preso da internet).

Uso (dalla cartella app/):

    python tool/genera_suoni.py

Scrive in assets/suoni/ dei WAV mono 16 bit a 44,1 kHz, brevi e a volume
basso: il servizio lib/core/feedback/ li riproduce con media_kit. Ogni suono
è una somma di sinusoidi con un inviluppo morbido (attacco breve, coda
esponenziale), così non ci sono scatti all'inizio o alla fine.

- tocco.wav             clic leggero (pulsanti principali, interruttori)
- conferma.wav          due note che salgono (salvataggio, argomento completato)
- avviso.wav            due note che scendono (errore, attenzione)
- focus_inizio.wav      tre note che salgono (inizio della sessione Focus)
- focus_fine.wav        campanella (fine della sessione Focus)
- pausa_inizio.wav      due note morbide che scendono (inizio della pausa)
- pausa_fine.wav        due note morbide che salgono (fine della pausa)
- registrazione_inizio.wav  segnale breve che sale
- registrazione_fine.wav    segnale breve che scende
"""

from __future__ import annotations

import math
import os
import struct
import wave

RATE = 44100
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   'assets', 'suoni')


def note(freq: float, dur: float, *, start: float = 0.0, gain: float = 1.0,
         attack: float = 0.006, decay: float = 6.0,
         harmonics: tuple[tuple[float, float], ...] = ((1.0, 1.0),),
         glide: float = 0.0) -> list[tuple[float, float, float, float, float,
                                            tuple[tuple[float, float], ...],
                                            float]]:
    """Una nota: frequenza, durata, inizio (s), volume, attacco, coda,
    armoniche (moltiplicatore, ampiezza) e glissato (Hz al secondo)."""
    return [(freq, dur, start, gain, attack, decay, harmonics, glide)]


def render(parts, length: float, peak: float) -> list[float]:
    n = int(RATE * length)
    buf = [0.0] * n
    for freq, dur, start, gain, attack, decay, harmonics, glide in parts:
        s0 = int(start * RATE)
        count = int(dur * RATE)
        phase = [0.0] * len(harmonics)
        for i in range(count):
            j = s0 + i
            if j >= n:
                break
            t = i / RATE
            env = min(1.0, t / attack) * math.exp(-decay * t)
            # coda: gli ultimi 8 ms scendono a zero (niente scatti)
            tail = (count - i) / RATE
            if tail < 0.008:
                env *= tail / 0.008
            f = freq + glide * t
            v = 0.0
            for k, (mult, amp) in enumerate(harmonics):
                phase[k] += 2 * math.pi * f * mult / RATE
                v += amp * math.sin(phase[k])
            buf[j] += gain * env * v
    top = max((abs(x) for x in buf), default=0.0) or 1.0
    return [x / top * peak for x in buf]


def write(name: str, samples: list[float]) -> None:
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b''.join(
            struct.pack('<h', max(-32767, min(32767, int(x * 32767))))
            for x in samples))
    print(f'{name}: {len(samples) / RATE * 1000:.0f} ms')


BELL = ((1.0, 1.0), (2.0, 0.28), (3.01, 0.12), (4.2, 0.05))
SOFT = ((1.0, 1.0), (2.0, 0.15))


def main() -> None:
    # clic: sinusoide acuta brevissima con un'ottava sotto per corpo
    write('tocco.wav', render(
        note(1850, 0.03, attack=0.001, decay=140, harmonics=((1, 1), (0.5, 0.4))),
        0.035, 0.22))
    write('conferma.wav', render(
        note(659.25, 0.16, decay=14, harmonics=SOFT)
        + note(987.77, 0.24, start=0.085, decay=11, harmonics=SOFT),
        0.33, 0.30))
    write('avviso.wav', render(
        note(587.33, 0.18, decay=10, harmonics=((1, 1), (3, 0.08)))
        + note(440.0, 0.26, start=0.12, decay=9, harmonics=((1, 1), (3, 0.08))),
        0.40, 0.30))
    write('focus_inizio.wav', render(
        note(523.25, 0.5, decay=5, harmonics=BELL)
        + note(659.25, 0.5, start=0.12, decay=5, harmonics=BELL)
        + note(783.99, 0.7, start=0.24, decay=4, harmonics=BELL),
        0.95, 0.32))
    write('focus_fine.wav', render(
        note(1046.5, 1.4, decay=3.2, harmonics=BELL)
        + note(783.99, 1.4, start=0.18, decay=3.0, harmonics=BELL)
        + note(1046.5, 1.6, start=0.55, decay=2.6, gain=0.8, harmonics=BELL),
        2.2, 0.34))
    write('pausa_inizio.wav', render(
        note(698.46, 0.45, decay=6, harmonics=SOFT)
        + note(523.25, 0.6, start=0.16, decay=5, harmonics=SOFT),
        0.8, 0.28))
    write('pausa_fine.wav', render(
        note(523.25, 0.45, decay=6, harmonics=SOFT)
        + note(698.46, 0.6, start=0.16, decay=5, harmonics=SOFT),
        0.8, 0.28))
    write('registrazione_inizio.wav', render(
        note(880, 0.14, attack=0.004, decay=16, harmonics=SOFT, glide=900),
        0.16, 0.26))
    write('registrazione_fine.wav', render(
        note(1100, 0.16, attack=0.004, decay=14, harmonics=SOFT, glide=-1000),
        0.18, 0.26))


if __name__ == '__main__':
    main()
