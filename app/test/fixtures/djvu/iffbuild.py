"""Pagina DjVu da blocchi di altri file (per le prove del lettore).

python3 iffbuild.py out.djvu W H DPI FLAG ID=sorgente[:ID] ...
sorgente è un file DjVu (se ne copiano i blocchi ID, o quelli indicati
dopo ":") oppure un file grezzo copiato come contenuto del blocco.
"""
import struct
import sys


def chunks(data, start, end):
    pos = start
    while pos + 8 <= end:
        cid = data[pos:pos + 4].decode('latin1')
        n = struct.unpack('>I', data[pos + 4:pos + 8])[0]
        yield cid, pos + 8, n
        pos += 8 + n
        if pos % 2:
            pos += 1


def djvu_chunks(path, want):
    d = open(path, 'rb').read()
    assert d[:8] == b'AT&TFORM'
    n = struct.unpack('>I', d[8:12])[0]
    out = []
    for cid, s, ln in chunks(d, 16, 12 + n):
        if cid == want:
            out.append(d[s:s + ln])
    return out


def chunk(cid, payload):
    b = cid.encode('latin1') + struct.pack('>I', len(payload)) + payload
    if len(payload) % 2:
        b += b'\0'
    return b


def main():
    out, w, h, dpi, flags = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
    body = b'DJVU' + chunk('INFO', struct.pack('>HHBB', w, h, 24, 0) + struct.pack('<H', dpi) + bytes([22, flags]))
    for spec in sys.argv[6:]:
        cid, src = spec.split('=', 1)
        if src.split(':')[0].endswith('.djvu') or src.split(':')[0].endswith('.iw4'):
            parts = src.split(':')
            got = djvu_chunks(parts[0], parts[1] if len(parts) > 1 else cid)
            for g in got:
                body += chunk(cid, g)
        else:
            body += chunk(cid, open(src, 'rb').read())
    with open(out, 'wb') as f:
        f.write(b'AT&T' + b'FORM' + struct.pack('>I', len(body)) + body)


main()
