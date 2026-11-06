#!/usr/bin/env python3
"""Dessine un travail GCC : gravure en gris (plus foncé = plus de puissance), découpes en rouge.
Usage : gccview.py travail.prn image.png"""
import sys, re, subprocess, os

def unrle(b):
    out, i = bytearray(), 0
    while i < len(b):
        c = b[i]
        if c == 0:
            if i + 1 < len(b) and b[i+1] == 0: return bytes(out), i + 2
            if b[i+1] == 3:
                ln = b[i+2]; out += b[i+3:i+3+ln]; i += 3 + ln; continue
            raise ValueError(f"unknown code 00 {b[i+1]:02x} at {i}")
        out += bytes([b[i+1]]) * c; i += 2
    return bytes(out), i

d = open(sys.argv[1], 'rb').read()
xdpi = int(re.search(rb'\x1b\*t(\d+)R', d).group(1)); ydpi = int(re.search(rb'\x1b&u(\d+)D', d).group(1))
x = y = 0; width = 0; band_rows = 0; in_band = False; up = False; power = 1000
black = {}; red = []
pos = re.compile(rb'\x1b!r(\d+)([BP])|\x1b\*p([+-]?\d+)([XYEF])|\x1b\*r(\d+)S|\x1b\*b(\d+)W|\x1b\*r1A|\x1b\*rC|\x1b%1B;|((?:PR|PU|PD|SP|PH|ZS|RS)[-\d,]*;)')
mode_hpgl = False
for m in pos.finditer(d):
    if m.group(2):
        if m.group(2) == b'B': up = m.group(1) == b'1'
        else: power = int(m.group(1))
    elif m.group(4):
        v = m.group(3); val = int(v)
        if m.group(4) in b'XE': x = x + val if v[:1] in b'+-' else val
        else: y = y + val if v[:1] in b'+-' else val
    elif m.group(5): width = int(m.group(5))
    elif m.group(0) == b'\x1b*r1A': band_rows = 0; in_band = True
    elif m.group(0) == b'\x1b*rC':
        if in_band and band_rows: y += -(band_rows - 1) if up else band_rows - 1
        in_band = False
    elif m.group(6):
        ln = int(m.group(6)); row, _ = unrle(d[m.end():m.end()+ln])
        ry = y - band_rows if up else y + band_rows
        for bi, byte in enumerate(row):
            if byte:
                for k in range(8):
                    if byte & (0x80 >> k): black[(x + bi*8 + k, ry)] = power
        band_rows += 1
    elif m.group(0) == b'\x1b%1B;': mode_hpgl = True
    elif m.group(7) and mode_hpgl:
        cmd = m.group(7).decode()
        if cmd[:2] in ('PU', 'PD') and len(cmd) > 3:
            dx, dy = (int(t) for t in cmd[2:-1].split(','))
            nx, ny = x + dx * xdpi / 1016, y - dy * ydpi / 1016
            if cmd[:2] == 'PD': red.append((x, y, nx, ny))
            x, y = nx, ny
pts = list(black) + [(a, b) for s in red for a, b in (s[:2], s[2:])]
x0 = int(min(p[0] for p in pts)) - 20; y0 = int(min(p[1] for p in pts)) - 20
x1 = int(max(p[0] for p in pts)) + 20; y1 = int(max(p[1] for p in pts)) + 20
sc = max(1, (x1 - x0) // 1600 + 1)
W, H = (x1 - x0) // sc + 1, (y1 - y0) // sc + 1
img = bytearray(b'\xff' * (W * H * 3))
for (px, py), pw in black.items():
    v = int(230 - min(pw, 1000) * 230 / 1000)
    i = ((py - y0) // sc * W + (px - x0) // sc) * 3; img[i:i+3] = bytes([v, v, v])
for (ax, ay, bx, by) in red:
    n = int(max(abs(bx-ax), abs(by-ay)) / sc) + 1
    for k in range(n + 1):
        t = k / n; px = int(ax + (bx-ax)*t); py = int(ay + (by-ay)*t)
        for ox in (-1, 0, 1):
            for oy in (-1, 0, 1):
                X = (px - x0)//sc + ox; Y = (py - y0)//sc + oy
                if 0 <= X < W and 0 <= Y < H: i = (Y*W + X)*3; img[i:i+3] = b'\xe0\x10\x10'
ppm = sys.argv[2] + '.ppm'
open(ppm, 'wb').write(b'P6\n%d %d\n255\n' % (W, H) + bytes(img))
subprocess.run(['sips', '-s', 'format', 'png', ppm, '--out', sys.argv[2]], capture_output=True)
os.remove(ppm)
print(f'{xdpi}x{ydpi} dpi, raster px {len(black)}, vector segments {len(red)}, origin ({x0},{y0}) scale 1/{sc}')
