"""Gera as fotos HEIC de teste (grade com corte e rotação; imagem única com rotação).

Só usa a biblioteca padrão do Python e o FFmpeg (libx265). Uso: python3 make.py
"""
import struct, subprocess, tempfile, os

def box(t, payload): return struct.pack('>I4s', 8 + len(payload), t) + payload
def full(t, v, flags, payload): return box(t, struct.pack('>I', (v << 24) | flags) + payload)

def encode(color_expr, w, h):
    """Codifica um quadro HEVC; devolve a lista de NALs (sem o código de início)."""
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, 'a.hevc')
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', color_expr.format(w=w, h=h),
                        '-frames:v', '1', '-c:v', 'libx265', '-pix_fmt', 'yuv420p',
                        '-x265-params', 'keyint=1:no-info=1:log-level=none', '-f', 'hevc', out], check=True)
        data = open(out, 'rb').read()
    nals, i = [], 0
    starts = []
    while True:
        j = data.find(b'\x00\x00\x01', i)
        if j < 0: break
        starts.append(j); i = j + 3
    for k, s in enumerate(starts):
        e = starts[k + 1] if k + 1 < len(starts) else len(data)
        n = data[s + 3:e]
        while n.endswith(b'\x00') and k + 1 < len(starts): n = n[:-1]
        nals.append(n)
    return nals

class Bits:
    def __init__(self, b): self.b, self.p = b, 0
    def u(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | ((self.b[self.p >> 3] >> (7 - (self.p & 7))) & 1); self.p += 1
        return v
    def ue(self):
        z = 0
        while self.u(1) == 0: z += 1
        return (1 << z) - 1 + (self.u(z) if z else 0)

def hvcc(nals):
    vps = [n for n in nals if (n[0] >> 1) & 63 == 32]
    sps = [n for n in nals if (n[0] >> 1) & 63 == 33]
    pps = [n for n in nals if (n[0] >> 1) & 63 == 34]
    raw = bytearray(); z = 0
    for c in sps[0][2:]:
        if z >= 2 and c == 3: z = 0; continue
        raw.append(c); z = z + 1 if c == 0 else 0
    ptl = bytes(raw[1:13])
    b = Bits(bytes(raw[13:]))
    b.ue(); chroma = b.ue()
    if chroma == 3: b.u(1)
    b.ue(); b.ue()
    if b.u(1):
        for _ in range(4): b.ue()
    luma = b.ue(); cb = b.ue()
    out = bytes([1]) + ptl + struct.pack('>HBBBBHB', 0xF000, 0xFC, 0xFC | chroma, 0xF8 | luma, 0xF8 | cb, 0, 0x0F)
    out += bytes([3])
    for t, arr in ((32, vps), (33, sps), (34, pps)):
        out += bytes([0x80 | t]) + struct.pack('>H', len(arr))
        for n in arr: out += struct.pack('>H', len(n)) + n
    return box(b'hvcC', out)

def frame(nals):
    return b''.join(struct.pack('>I', len(n)) + n for n in nals if (n[0] >> 1) & 63 < 32)

def build(path, tiles, tile_wh, grid=None, irot=None):
    """tiles: lista de NALs por ladrilho. grid: (rows, cols, out_w, out_h) ou None."""
    tw, th = tile_wh
    props = [hvcc(tiles[0]), full(b'ispe', 0, 0, struct.pack('>II', tw, th))]
    tile_ids = list(range(1, len(tiles) + 1))
    assoc = {i: [(1, True), (2, False)] for i in tile_ids}
    primary = tile_ids[0]
    infe = [full(b'infe', 2, 1 if grid else 0, struct.pack('>HH4s', i, 0, b'hvc1') + b'\0') for i in tile_ids]
    idat = b''; iref = b''
    if grid:
        rows, cols, ow, oh = grid
        primary = len(tiles) + 1
        infe.append(full(b'infe', 2, 0, struct.pack('>HH4s', primary, 0, b'grid') + b'\0'))
        idat = struct.pack('>BBBBHH', 0, 0, rows - 1, cols - 1, ow, oh)
        props.append(full(b'ispe', 0, 0, struct.pack('>II', ow, oh)))
        assoc[primary] = [(len(props), False)]
        iref = full(b'iref', 0, 0, box(b'dimg', struct.pack('>HH', primary, len(tile_ids)) + b''.join(struct.pack('>H', i) for i in tile_ids)))
    if irot is not None:
        props.append(box(b'irot', bytes([irot])))
        assoc[primary].append((len(props), True))
    ipma = struct.pack('>I', len(assoc))
    for i in sorted(assoc):
        ipma += struct.pack('>HB', i, len(assoc[i])) + bytes([(0x80 if ess else 0) | idx for idx, ess in assoc[i]])
    frames = [frame(t) for t in tiles]

    def meta(offsets):
        iloc = struct.pack('>BBH', 0x44, 0x00, len(tile_ids) + (1 if grid else 0))
        for i, (off, f) in zip(tile_ids, zip(offsets, frames)):
            iloc += struct.pack('>HHHHII', i, 0, 0, 1, off, len(f))
        if grid:
            iloc += struct.pack('>HHHHII', primary, 1, 0, 1, 0, len(idat))
        kids = full(b'hdlr', 0, 0, struct.pack('>I4s', 0, b'pict') + b'\0' * 12 + b'\0')
        kids += full(b'pitm', 0, 0, struct.pack('>H', primary))
        kids += full(b'iloc', 1, 0, iloc)
        kids += full(b'iinf', 0, 0, struct.pack('>H', len(infe)) + b''.join(infe))
        kids += iref
        kids += box(b'iprp', box(b'ipco', b''.join(props)) + full(b'ipma', 0, 0, ipma))
        if grid: kids += box(b'idat', idat)
        return full(b'meta', 0, 0, kids)

    ftyp = box(b'ftyp', b'heic' + struct.pack('>I', 0) + b'mif1heic')
    base = len(ftyp) + len(meta([0] * len(frames))) + 8
    offsets, o = [], base
    for f in frames: offsets.append(o); o += len(f)
    open(path, 'wb').write(ftyp + meta(offsets) + box(b'mdat', b''.join(frames)))

here = os.path.dirname(os.path.abspath(__file__))
# Grade 3x2 de ladrilhos 64x64 (192x128), cortada para 180x120 e girada 90° anti-horário.
# Antes de girar: vermelho | verde em cima, azul | amarelo embaixo (divisa em x=90, y=60).
def quad(col, row):
    x0, y0 = col * 64, row * 64
    return ("color=black:s={w}x{h},format=rgb24,geq="
            f"r='if(lt(X+{x0},90),if(lt(Y+{y0},60),255,0),if(lt(Y+{y0},60),0,255))':"
            f"g='if(lt(X+{x0},90),0,255)':"
            f"b='if(lt(X+{x0},90),if(lt(Y+{y0},60),0,255),0)'")
tiles = [encode(quad(c, r), 64, 64) for r in range(2) for c in range(3)]
build(os.path.join(here, 'grade.heic'), tiles, (64, 64), grid=(2, 3, 180, 120), irot=1)
# Imagem única 128x64 (vermelho à esquerda, azul à direita), girada 90° horário.
single = encode("color=black:s={w}x{h},format=rgb24,geq=r='if(lt(X,64),255,0)':g=0:b='if(lt(X,64),0,255)'", 128, 64)
build(os.path.join(here, 'simples.heic'), [single], (128, 64), irot=3)
print('ok')
