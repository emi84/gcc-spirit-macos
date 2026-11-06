#!/usr/bin/env python3
"""Affiche un travail GCC LaserPro (PCL + extensions ESC! + HP-GL/2) en clair et verifie
chaque ligne raster.  Usage : gccdump.py travail.prn"""
import sys, re

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
i, n, out = 0, len(d), []
hpgl = False
rows = 0
while i < n:
    c = d[i]
    if c == 0x1b:
        if d[i+1:i+2] == b'%':
            m = re.match(rb'\x1b%(-?\d*)([A-Za-z])', d[i:])
            tok = m.group(0); i += len(tok)
            hpgl = tok.endswith(b'B'); out.append(f"ESC%{m.group(1).decode()}{m.group(2).decode()}" + ("   [-> HP-GL/2]" if hpgl else "   [-> PCL]" if tok.endswith(b'A') else ""))
            continue
        if d[i+1:i+2] == b'E':
            out.append("ESC E   [reset]"); i += 2; continue
        m = re.match(rb'\x1b([!*&])([a-z])(-?\+?\d*)([A-Za-z])', d[i:])
        if not m:
            out.append(f"?? ESC {d[i+1:i+8]!r}"); i += 2; continue
        fam, grp, val, term = (x.decode() for x in m.groups()); i += len(m.group(0))
        if fam == '*' and grp == 'b' and term == 'W':
            ln = int(val); rows += 1
            if rows <= 5 or rows % 200 == 0: out.append(f"ESC*b{val}W  <{ln} bytes data: {d[i:i+min(ln,24)].hex()}...>")
            i += ln; continue
        if fam == '!' and grp == 'v' and term in 'VPIRFDZTMS':
            # table follows: count = val digits/bytes
            ln = int(val)
            out.append(f"ESC!v{val}{term}  table: {d[i:i+ln]!r}"); i += ln; continue
        if fam == '!' and grp == 'm' and term == 'N':
            ln = int(val); out.append(f"ESC!m{val}N  name: {d[i:i+ln]!r}"); i += ln; continue
        out.append(f"ESC{fam}{grp}{val}{term}")
        continue
    # HP-GL text until ESC
    j = d.find(b'\x1b', i)
    j = n if j < 0 else j
    chunk = d[i:j]
    if chunk.strip():
        for cmd in chunk.split(b';'):
            if cmd.strip(): out.append(f"  HPGL {cmd.decode('latin-1')};")
    i = j
print(f"# {len(d)} bytes, {rows} raster rows")
for l in out: print(l)

# Each raster row must decompress to exactly the width ESC*r<n>S declared.
width, bad, total = None, 0, 0
for m in re.finditer(rb'\x1b\*r(\d+)S|\x1b\*b(\d+)W', d):
    if m.group(1): width = int(m.group(1)); continue
    ln = int(m.group(2)); total += 1
    try:
        row, used = unrle(d[m.end():m.end() + ln])
        if used != ln or len(row) != (width + 7) // 8: bad += 1
    except Exception: bad += 1
print(f"# verification : {total} lignes raster, {bad} incorrecte(s)")
