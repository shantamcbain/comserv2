#!/usr/bin/env python3
"""
Scan HDRY part STLs that are NOT yet imported into printing_3d_models.
Dedupe by geometry (volume + bbox + triangle count), and propose a clean
part name / SKU for each unique mesh.

Dry-run only: writes /tmp/hdry_candidates.json. Creates nothing.
"""
import struct, os, re, json, hashlib, glob

def parse(path):
    with open(path,'rb') as f: data=f.read()
    head=data[:80]
    try:
        t=head.decode('ascii')
        is_ascii = t.lstrip().lower().startswith('solid') and b'\x00' not in head
    except Exception: is_ascii=False
    verts=[]
    if is_ascii:
        txt=data.decode('ascii',errors='ignore')
        for m in re.finditer(r'vertex\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)',txt):
            verts.append((float(m.group(1)),float(m.group(2)),float(m.group(3))))
    else:
        n=struct.unpack('<I',data[80:84])[0]; off=84
        for i in range(n):
            if off+50>len(data): break
            v=struct.unpack('<12f',data[off:off+48])
            verts += [tuple(v[3:6]),tuple(v[6:9]),tuple(v[9:12])]
            off+=50
    return verts, n if not is_ascii else len(verts)//3

def stats(path):
    vs,tris = parse(path)
    if not vs: return None
    lo=[min(p[i] for p in vs) for i in range(3)]
    hi=[max(p[i] for p in vs) for i in range(3)]
    # signed volume
    vol=0.0
    for i in range(0,len(vs)-2,3):
        a,b,c=vs[i],vs[i+1],vs[i+2]
        vol += (a[0]*(b[1]*c[2]-b[2]*c[1])
              - a[1]*(b[0]*c[2]-b[2]*c[0])
              + a[2]*(b[0]*c[1]-b[1]*c[0]))/6.0
    bbox=[round(hi[i]-lo[i],2) for i in range(3)]
    v=abs(vol)/1000.0
    # Geometry identity. Two meshes are "the same part" when they agree on
    # volume (0.1%), per-axis bbox (0.5mm) AND triangle count. Volume alone
    # collides (many distinct HDRY parts share a volume); tris alone is
    # unreliable (same part re-exported with different tessellation).
    vb="|".join(f"{x:.1f}" for x in bbox)
    key=hashlib.md5(f"{v:.2f}|{vb}|{tris}".encode()).hexdigest()[:12]
    return dict(tris=tris, vol_cm3=round(v,4), bbox=bbox,
                size=[round(x,1) for x in bbox], gkey=key,
                weight_g=round(v*1.24,3))

# dirs to scan
DIRS = {
 'Doors':'/data/nfs/hdry_parts/023037_HDRY_System_V3__Doors',
 'Extras':'/data/nfs/hdry_parts/023113_HDRY_System_V3__Dryer__Extras',
 'Module_1':'/data/nfs/hdry_parts/023022_HDRY_System_V3__Module_1',
 'Module_2':'/data/nfs/hdry_parts/023030_HDRY_System_V3__Module_2',
 'Rollers':'/data/nfs/hdry_parts/110520_HDRY_System_V3__AMS__Hydra__Rollers',
}

# names of files already imported (from DB dump earlier)
imported = json.load(open('/tmp/models_now.json'))
imported_files=set()
for r in imported:
    if r.get('nfs_path'): imported_files.add(os.path.basename(r['nfs_path']))
print(f"already imported: {len(imported)} models, {len(imported_files)} distinct files")

# propose names
def propose(fname, mod):
    base=fname[:-4] if fname.lower().endswith('.stl') else fname
    # strip the BambuStudio duplicate suffixes: __1_, __1___1_, _1_, __2_
    clean=re.sub(r'(_{1,2}\d+)+_{0,2}\d*$','',base)
    clean=re.sub(r'_+','_',clean).strip('_')
    side=''
    m=re.search(r'_(L|R)(?:H|L)?\d*$', clean) or re.search(r'_(LH|RH)$', clean)
    if m:
        tok=m.group(1)
        side='Left' if tok in ('L','LH') else 'Right'
        clean=clean[:m.start()]
    pretty=clean.replace('_',' ').replace('-',' ')
    pretty=re.sub(r'\s+',' ',pretty).strip()
    pretty=' '.join(w.capitalize() for w in pretty.split())
    if side: pretty=f"{pretty} {side}"
    return pretty, clean.upper().replace(' ','-')

rows=[]
for mod,d in DIRS.items():
    if not os.path.isdir(d): continue
    for p in sorted(glob.glob(os.path.join(d,'*.stl'))):
        f=os.path.basename(p)
        if f in imported_files: continue
        s=stats(p)
        if not s: continue
        name, sku = propose(f, mod)
        rows.append(dict(file=f, module=mod, path=p, name=name, sku=sku, **s))

# dedupe by geometry
groups={}
for r in rows: groups.setdefault(r['gkey'],[]).append(r)

cands=[]
for k,g in sorted(groups.items(), key=lambda kv: sorted(x['file'] for x in kv[1])[0]):
    rep=sorted(g,key=lambda x:x['file'])[0]
    cands.append(dict(
        gkey=k, proposed_name=rep['name'], proposed_sku=rep['sku'],
        vol_cm3=rep['vol_cm3'], weight_g=rep['weight_g'], size=rep['size'],
        tris=rep['tris'], module=rep['module'],
        files=[x['file'] for x in sorted(g,key=lambda x:x['file'])],
        paths=[x['path'] for x in sorted(g,key=lambda x:x['file'])],
        copies=len(g),
    ))

print(f"\nun-imported files: {len(rows)}  ->  unique geometries: {len(cands)}")
json.dump(dict(candidates=cands, imported_count=len(imported)),
          open('/tmp/hdry_candidates.json','w'), indent=1)
print("\n=== CANDIDATE PARTS (deduped) ===")
for c in cands:
    print(f"  {c['proposed_name']:<34} vol={c['vol_cm3']:<9} size={c['size']} "
          f"copies={c['copies']}  files={c['files']}")
