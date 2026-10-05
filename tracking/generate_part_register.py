#!/usr/bin/env python3
"""
Generate a generic PART VERSION REGISTER (CSV) for any project that has a BOM.

The register is a flat, spreadsheet-friendly table that lets a human maintain
accurate part design across manufacturer version drift. It is intentionally
NON-3D-specific: any BOM project drops a manifest.json describing where its
source model files live and how filenames map to canonical part codes, and this
script emits one CSV with geometry + location + version/change tracking columns.

Design/version "rotation" columns (the point of the tool):
  - upstream_url      : where the original creator publishes revisions
  - upstream_version  : latest version the creator has published
  - change_found      : Y/N  - did a web search reveal a new/changed feature?
  - change_notes      : what changed, when found, source
  - action_needed     : e.g. "flag BOM for update", "re-verify STL", "none"

Geometry is measured from the actual file (never trusted from filename), so a
row whose measured dimension disagrees with expected_dim_mm is flagged
CONSISTENCY ERROR - exactly the provider-version-drift problem this tracks.

Usage:
  python3 generate_part_register.py <manifest.json> [output.csv]

If output omitted, writes <manifest-dir>/part_version_register.csv
"""
import struct, os, re, sys, json, glob, csv

DENSITY_G_PER_CM3 = 1.24  # PETG-ish default; override per-project in manifest


def geometry(path):
    """Return dict with bbox(x,y,z), vol_cm3, tris, or None."""
    try:
        data = open(path, 'rb').read()
    except Exception:
        return None
    if len(data) < 84:
        return None
    head = data[:80]
    is_ascii = False
    try:
        t = head.decode('ascii')
        is_ascii = t.lstrip().lower().startswith('solid') and b'\x00' not in head
    except Exception:
        pass
    verts = []
    if is_ascii:
        for m in re.finditer(r'vertex\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)',
                             data.decode('ascii', errors='ignore')):
            verts.append((float(m.group(1)), float(m.group(2)), float(m.group(3))))
    else:
        n = struct.unpack('<I', data[80:84])[0]
        off = 84
        for _ in range(n):
            if off + 50 > len(data):
                break
            v = struct.unpack('<12f', data[off:off + 48])
            verts += [tuple(v[3:6]), tuple(v[6:9]), tuple(v[9:12])]
            off += 50
    if not verts:
        return None
    lo = [min(p[i] for p in verts) for i in range(3)]
    hi = [max(p[i] for p in verts) for i in range(3)]
    vol = 0.0
    for i in range(0, len(verts) - 2, 3):
        a, b, c = verts[i], verts[i + 1], verts[i + 2]
        vol += (a[0] * (b[1] * c[2] - b[2] * c[1])
                - a[1] * (b[0] * c[2] - b[2] * c[0])
                + a[2] * (b[0] * c[1] - b[1] * c[0])) / 6.0
    bbox = [round(hi[i] - lo[i], 1) for i in range(3)]
    return dict(bbox=bbox, vol_cm3=round(abs(vol) / 1000.0, 4),
                tris=len(verts) // 3)


def main():
    if len(sys.argv) < 2:
        print("usage: generate_part_register.py <manifest.json> [out.csv]")
        sys.exit(1)
    manifest_path = sys.argv[1]
    manifest = json.load(open(manifest_path))
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(os.path.abspath(manifest_path)), 'part_version_register.csv')

    proj = manifest.get('project', 'UNNAMED')
    density = manifest.get('density_g_per_cm3', DENSITY_G_PER_CM3)
    # part_map: basename (or regex) -> {code,name,category,level,expected_dim_mm,bom,link_status}
    part_map = manifest.get('part_map', {})
    dirs = manifest.get('dirs', [])

    # collect every file first, then dedup by geometry so identical copies
    # (e.g. BR03.stl in top dir + Mod1/ + model2/) collapse to ONE row whose
    # source_path lists all locations.
    seen_paths = set()
    collected = []
    for d in dirs:
        for p in sorted(glob.glob(os.path.join(d, '**', '*.stl'), recursive=True)):
            if p in seen_paths:
                continue
            seen_paths.add(p)
            g = geometry(p)
            if not g:
                continue
            collected.append((p, g))

    # geometry identity: volume(0.1%) + per-axis bbox(0.5mm) + triangle count
    def gkey(g):
        return (round(g['vol_cm3'], 2), tuple(round(b, 1) for b in g['bbox']), g['tris'])

    groups = {}
    for p, g in collected:
        groups.setdefault(gkey(g), []).append(p)

    rows = []
    for key, paths in sorted(groups.items(), key=lambda kv: sorted(kv[1])[0]):
        p = sorted(paths)[0]
        fn = os.path.basename(p)
        g = next(gg for pp, gg in collected if pp == p)
        meta = part_map.get(fn) or part_map.get(re.sub(r'\s*\(.*\)', '', fn)) or {}
        code = meta.get('code', re.sub(r'\.stl$', '', fn, flags=re.I))
        exp = meta.get('expected_dim_mm')
        status = meta.get('link_status', 'UNMAPPED - verify')
        flag = ''
        if exp is not None:
            # A part's design height may be X, Y or Z depending on orientation.
            # The file is consistent when ANY axis matches expected_dim_mm.
            best = min(abs(b - exp) for b in g['bbox'])
            if best > 12:
                flag = 'CONSISTENCY ERROR: no axis within 12mm of expected %gmm (bbox %s)' % (
                    exp, 'x%g y%g z%g' % tuple(g['bbox']))
                if not status.startswith('CONSISTENCY'):
                    status = 'CONSISTENCY ERROR'
        locs = ' | '.join(sorted(paths))
        rows.append({
            'project': proj,
            'part_code': code,
            'part_name': meta.get('name', code),
            'category': meta.get('category', ''),
            'level': meta.get('level', ''),
            'expected_dim_mm': exp if exp is not None else '',
            'source_filename': fn,
            'source_path': locs,
            'module_plate': meta.get('module', ''),
            'volume_cm3': g['vol_cm3'],
            'bbox_mm': 'x%s y%s z%s' % tuple(g['bbox']),
            'triangles': g['tris'],
            'est_weight_g': round(g['vol_cm3'] * density, 1),
            'linked_bom': meta.get('bom', ''),
            'link_status': status,
            'verified': meta.get('verified', 'N'),
            'upstream_url': '',
            'upstream_version': '',
            'change_found': 'N',
            'change_notes': flag,
            'action_needed': meta.get('action_needed', 'review'),
        })

    cols = ['project', 'part_code', 'part_name', 'category', 'level',
            'expected_dim_mm', 'source_filename', 'source_path', 'module_plate',
            'volume_cm3', 'bbox_mm', 'triangles', 'est_weight_g', 'linked_bom',
            'link_status', 'verified', 'upstream_url', 'upstream_version',
            'change_found', 'change_notes', 'action_needed']
    with open(out, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    print("wrote %d rows -> %s" % (len(rows), out))


if __name__ == '__main__':
    main()
