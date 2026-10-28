#!/usr/bin/env python3
"""Parse STL files -> volume (cm3), bbox, triangle count. Ground truth for the HDRY audit."""
import struct, os, sys, json, glob, re

def parse_binary(data, ntri):
    vol = 0.0
    lo = [float('inf')]*3
    hi = [float('-inf')]*3
    off, count = 84, 0
    while off + 50 <= len(data) and count < ntri:
        vals = struct.unpack('<12f', data[off:off+48])
        v0, v1, v2 = vals[3:6], vals[6:9], vals[9:12]
        vol += (v0[0]*(v1[1]*v2[2]-v1[2]*v2[1])
              - v0[1]*(v1[0]*v2[2]-v1[2]*v2[0])
              + v0[2]*(v1[0]*v2[1]-v1[1]*v2[0])) / 6.0
        for v in (v0, v1, v2):
            for i in range(3):
                lo[i] = min(lo[i], v[i]); hi[i] = max(hi[i], v[i])
        off += 50; count += 1
    return count, abs(vol), [round(hi[i]-lo[i], 1) for i in range(3)]

def parse_ascii(text):
    verts = re.findall(r'vertex\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)', text)
    n = len(verts)//3
    vol = 0.0
    lo = [float('inf')]*3
    hi = [float('-inf')]*3
    for i in range(n):
        v0 = [float(x) for x in verts[i*3]]
        v1 = [float(x) for x in verts[i*3+1]]
        v2 = [float(x) for x in verts[i*3+2]]
        vol += (v0[0]*(v1[1]*v2[2]-v1[2]*v2[1])
              - v0[1]*(v1[0]*v2[2]-v1[2]*v2[0])
              + v0[2]*(v1[0]*v2[1]-v1[1]*v2[0])) / 6.0
        for v in (v0, v1, v2):
            for k in range(3):
                lo[k] = min(lo[k], v[k]); hi[k] = max(hi[k], v[k])
    return n, abs(vol), [round(hi[k]-lo[k], 1) for k in range(3)]

def parse_stl(path):
    with open(path, 'rb') as f:
        data = f.read()
    if len(data) < 84:
        return None
    head = data[:80]
    is_ascii = False
    try:
        t = head.decode('ascii')
        is_ascii = t.lstrip().lower().startswith('solid') and b'\x00' not in head
    except Exception:
        pass
    if is_ascii:
        n, v, bb = parse_ascii(data.decode('ascii', errors='ignore'))
        return dict(binary=False, tris=n, vol_mm3=v, bbox=bb)
    ntri = struct.unpack('<I', data[80:84])[0]
    expected = 84 + ntri*50
    if abs(len(data) - expected) > 100:   # size mismatch -> try ascii
        if b'facet normal' in data[:3000].lower():
            n, v, bb = parse_ascii(data.decode('ascii', errors='ignore'))
            return dict(binary=False, tris=n, vol_mm3=v, bbox=bb)
    n, v, bb = parse_binary(data, ntri)
    return dict(binary=True, tris=n, vol_mm3=v, bbox=bb)

out = {}
for d in sys.argv[1:]:
    for p in sorted(glob.glob(os.path.join(d, '**', '*.stl'), recursive=True)):
        if '/_thumbs/' in p:
            continue
        try:
            r = parse_stl(p)
            if r:
                r['vol_cm3'] = round(r['vol_mm3']/1000.0, 4)
                r['path'] = p
                out.setdefault(os.path.basename(p), []).append(r)
        except Exception as e:
            out.setdefault(os.path.basename(p), []).append(dict(error=str(e), path=p))
json.dump(out, open('/tmp/stl_vols.json', 'w'), indent=1)
print("parsed %d files -> /tmp/stl_vols.json" % len(out))
