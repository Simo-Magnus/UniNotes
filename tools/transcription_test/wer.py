"""Word error rate tra testo atteso e trascrizione (minuscole, senza punteggiatura)."""
import re
import sys
import unicodedata


def words(s: str) -> list[str]:
    s = unicodedata.normalize("NFKD", s.lower()).encode("ascii", "ignore").decode()
    return re.findall(r"[a-z0-9]+", s)


def wer(ref: str, hyp: str) -> float:
    r, h = words(ref), words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)] / max(1, len(r))


if __name__ == "__main__":
    ref = open(sys.argv[1], encoding="utf-8").read()
    hyp = open(sys.argv[2], encoding="utf-8").read()
    w = wer(ref, hyp)
    print(f"WER = {w:.1%}")
    sys.exit(0 if w <= float(sys.argv[3] if len(sys.argv) > 3 else 0.5) else 1)
