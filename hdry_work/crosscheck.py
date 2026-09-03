#!/usr/bin/env python3
"""Cross-check printing_3d_models rows against real STL geometry on disk.

Ground-truth rule discovered from the data:
  corners + side panels:  L1 => z-height 150mm,  L2 => z-height 215mm
So a model row named "L1" whose file measures 215mm tall is pointed at the L2 part.
"""
import json, os, sys, subprocess

disk = json.load(open('/tmp/stl_vols.json'))
# full-path index
bypath = {}
for name, entries in disk.items():
    for e in entries:
        if 'path' in e:
            bypath[e['path']] = e

db = json.load(open('/tmp/models.json'))

def zheight(e):
    return e['bbox'][2] if e and 'bbox' in e else None

print(f"{'id':<4}{'name':<38}{'file':<24}{'db_vol':>10}{'disk_vol':>10}{'z_mm':>7}  verdict")
print("-"*110)
issues = []
for r in db:
    if not r.get('nfs_path'):
        continue
    # only HDRY extracted parts (ids >=17) are in scope for the extraction audit
    if r['id'] < 17:
        continue
    fn = os.path.basename(r['nfs_path'])
    e = bypath.get(r['nfs_path'])
    name = r['name'] or ''
    dbvol = float(r['stl_volume_cm3']) if r.get('stl_volume_cm3') else None
    dvol = e['vol_cm3'] if e else None
    z = zheight(e)
    verdict = []
    if e is None:
        verdict.append("FILE MISSING ON DISK")
    else:
        if dbvol is not None and dvol is not None and abs(dbvol - dvol) > 0.5:
            verdict.append("VOL MISMATCH")
        elif dbvol is None:
            verdict.append("NO VOLUME STORED")
        # L1/L2 geometry check by z-height
        if z is not None and (' L1' in name or ' L2' in name):
            want = 150.0 if ' L1' in name else 215.0
            if abs(z - want) > 12:
                verdict.append(f"WRONG PART: named L{'1' if ' L1' in name else '2'} but z={z}mm (expect {want:.0f})")
    v = "; ".join(verdict) or "ok"
    if verdict:
        issues.append((r, v))
    print(f"{r['id']:<4}{name[:37]:<38}{fn[:23]:<24}"
          f"{('%10.4f'%dbvol) if dbvol is not None else '         -':>10}"
          f"{('%10.4f'%dvol) if dvol is not None else '         -':>10}"
          f"{('%7.0f'%z) if z is not None else '      -':>7}  {v}")

print("\n=== SUMMARY: %d problem rows out of %d HDRY parts ===" % (len(issues), len([r for r in db if r['id']>=17])))

# duplicate detection: same normalized part code, multiple rows
from collections import defaultdict
import re
groups = defaultdict(list)
for r in db:
    if r['id'] < 17: continue
    m = re.search(r'\(([A-Z]{2,4}\d{2})\)', r['name'] or '')
    key = m.group(1) if m else (r['name'] or '').strip()
    groups[key].append(r['id'])
print("\n=== DUPLICATE model rows (same part code) ===")
for k, ids in sorted(groups.items()):
    if len(ids) > 1:
        print(f"  {k}: ids {ids}")
