"""comserv2-openscad — thin HTTP wrapper around headless OpenSCAD.

Stateless render service:
  POST /render     {template_name | scad_source, params{}, format} -> STL bytes
  GET  /healthz    liveness + openscad version
  GET  /templates  baked-in template names

No persistent storage: each render runs in a throwaway temp dir with a
wall-clock timeout. Params are passed via openscad -D with proper literal
encoding (no shell involved; argv list only).
"""

import asyncio
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, Field

TEMPLATE_DIR = Path(os.environ.get("TEMPLATE_DIR", "templates"))
RENDER_TIMEOUT = int(os.environ.get("RENDER_TIMEOUT", "120"))
MAX_CONCURRENT = int(os.environ.get("MAX_CONCURRENT_RENDERS", "2"))

ALLOWED_FORMATS = {"stl", "off", "amf", "3mf", "csg", "dxf", "svg"}
_TEMPLATE_NAME_RE = re.compile(r"^[A-Za-z0-9_\-]+$")

app = FastAPI(title="comserv2-openscad", version="1.0")
_render_sem = asyncio.Semaphore(MAX_CONCURRENT)


class RenderRequest(BaseModel):
    template_name: str | None = None
    scad_source: str | None = None
    params: dict[str, object] = Field(default_factory=dict)
    format: str = "stl"
    qr_data: str | None = None  # when set, a QR matrix is injected as qr_bits/qr_n params


def _qr_matrix_params(data: str) -> dict[str, object]:
    """Generate a QR code and return template params (qr_bits string + qr_n)."""
    import qrcode

    qr = qrcode.QRCode(
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        border=0,
        box_size=1,
    )
    qr.add_data(data)
    qr.make(fit=True)
    matrix = qr.get_matrix()
    n = len(matrix)
    bits = "".join("1" if cell else "0" for row in matrix for cell in row)
    return {"qr_bits": bits, "qr_n": n}


def _openscad_version() -> str:
    try:
        out = subprocess.run(
            ["openscad", "--version"],
            capture_output=True, text=True, timeout=15,
        )
        return (out.stdout + out.stderr).strip()
    except Exception as exc:  # noqa: BLE001
        return f"unavailable: {exc}"


def _scad_literal(value: object) -> str:
    """Encode a python value as an OpenSCAD -D literal."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(_scad_literal(v) for v in value) + "]"
    # string: escape backslash and double quote
    text = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{text}"'


@app.get("/healthz")
def healthz():
    return {"status": "ok", "openscad_version": _openscad_version()}


@app.get("/templates")
def templates():
    names = sorted(p.stem for p in TEMPLATE_DIR.glob("*.scad"))
    return {"templates": names}


@app.get("/qr")
def qr_matrix(data: str):
    """Return the QR matrix for `data` as JSON (n + row-major bits string).
    Used by the app's live sign preview to draw a truly scannable QR."""
    if not data or len(data) > 500:
        raise HTTPException(400, "data required (max 500 chars)")
    return _qr_matrix_params(data)


class PdfRequest(BaseModel):
    params: dict[str, object] = Field(default_factory=dict)
    qr_data: str | None = None


@app.post("/render_pdf")
def render_pdf(req: PdfRequest):
    """Render the sign as a true-size vector PDF (the universal sign document:
    paper printers, laser engravers, and archival/fix-up source).
    Same layout math as herb_sign_v1.scad."""
    from io import BytesIO

    from reportlab.lib.colors import HexColor
    from reportlab.lib.units import mm
    from reportlab.pdfgen import canvas as pdfcanvas

    p = req.params
    w = float(str(p.get("sign_w", 120)))
    h = float(str(p.get("sign_h", 80)))
    title = str(p.get("title", ""))
    subtitle = str(p.get("subtitle", ""))
    body1 = str(p.get("body1", ""))
    body2 = str(p.get("body2", ""))
    url_text = str(p.get("url_text", ""))
    plate = str(p.get("plate_color") or "#d8cfa8")
    textc = str(p.get("text_color") or "#4a3b18")
    qr_on = bool(req.qr_data)

    qr_size = 24.0
    margin = h * 0.08
    usable_w = w - h * 0.16 - (qr_size + margin if qr_on else 0)
    text_shift = -(qr_size / 2 + margin / 2) if qr_on else 0.0

    def fit(sz: float, s: str) -> float:
        return sz if not s else min(sz, usable_w / (len(s) * 0.72))

    buf = BytesIO()
    c = pdfcanvas.Canvas(buf, pagesize=(w * mm, h * mm))

    # plate + border (rounded)
    c.setFillColor(HexColor(plate))
    c.setStrokeColor(HexColor(textc))
    c.setLineWidth(1.2 * mm)
    c.roundRect(0.6 * mm, 0.6 * mm, (w - 1.2) * mm, (h - 1.2) * mm,
                4 * mm, stroke=1, fill=1)

    c.setFillColor(HexColor(textc))
    cx = (w / 2 + text_shift) * mm

    def line(text: str, size_mm_v: float, y_frac: float, font: str):
        if not text:
            return
        size_pt = size_mm_v * mm  # reportlab: 1pt units via mm factor
        c.setFont(font, size_pt)
        # y_frac measured from center, matching the SCAD template
        y = (h / 2 + y_frac * h) * mm - size_pt * 0.35
        c.drawCentredString(cx, y, text)

    line(title, fit(h * 0.16, title), 0.30, "Helvetica-Bold")
    line(subtitle, fit(h * 0.085, subtitle), 0.12, "Helvetica-Oblique")
    line(body1, fit(h * 0.075, body1), -0.05, "Helvetica")
    line(body2, fit(h * 0.075, body2), -0.18, "Helvetica")
    line(url_text, fit(h * 0.065, url_text), -0.34, "Helvetica")

    if qr_on:
        q = _qr_matrix_params(req.qr_data or "")
        n = int(str(q["qr_n"]))
        bits = str(q["qr_bits"])
        cell = qr_size / n
        ox = (w - qr_size - margin) * mm
        oy = margin * mm
        c.setFillColor(HexColor("#ffffff"))
        c.rect(ox - 1 * mm, oy - 1 * mm, (qr_size + 2) * mm, (qr_size + 2) * mm,
               stroke=0, fill=1)
        c.setFillColor(HexColor("#000000"))
        for row in range(n):
            for col in range(n):
                if bits[row * n + col] == "1":
                    c.rect(ox + col * cell * mm,
                           oy + (qr_size - (row + 1) * cell) * mm,
                           cell * mm + 0.1, cell * mm + 0.1, stroke=0, fill=1)

    c.showPage()
    c.save()
    data = buf.getvalue()
    return Response(
        content=data,
        media_type="application/pdf",
        headers={"Content-Disposition": 'attachment; filename="sign.pdf"'},
    )


@app.post("/render_3mf")
async def render_3mf(req: RenderRequest):
    """Build a single multi-object 3MF that carries ALL of the sign's colour
    parts as separate objects, each tagged with the user's picked colour.

    Why: STL cannot represent multiple objects/filaments in one file — a single
    STL always imports as ONE filament, and the old base/text split-STL trick
    still reads as one filament when loaded into the Anycubic slicer (the user
    reported only one filament). 3MF stores multiple <item> entries inside one
    archive, so the slicer sees N objects and lets you assign a filament/colour
    to each. This is the format the 4-colour Anycubic wants.

    Pipeline: render each requested part to OFF (OpenSCAD's native mesh format),
    then assemble them as separate <item>s in ONE 3MF. The separate objects are
    what actually let the slicer assign a different filament to each part; a
    production <metadata name="color"> also pre-tints each object where the
    reader honours it (PrusaSlicer, Anycubic's fork).
    """
    if bool(req.template_name) == bool(req.scad_source):
        raise HTTPException(400, "provide exactly one of template_name or scad_source")

    # Params that are NOT OpenSCAD variables (they are used here, in Python):
    #   plate_color / text_color              -> per-part colours (hex)
    #   plate_filament_type / text_filament_type
    #   plate_filament_color / text_filament_color  -> human names (PLA / Green)
    #   _parts                                -> which parts to include
    # Strip them before building the -D argv so they never reach openscad.
    raw = dict(req.params)
    plat = str(raw.pop("plate_color", None) or "#d8cfa8")
    textc = str(raw.pop("text_color", None) or "#4a3b18")
    plat_type = str(raw.pop("plate_filament_type", None) or "").strip()
    text_type = str(raw.pop("text_filament_type", None) or "").strip()
    plat_name = str(raw.pop("plate_filament_color", None) or "").strip()
    text_name = str(raw.pop("text_filament_color", None) or "").strip()
    _parts_raw = raw.pop("_parts", None)
    parts = (list(_parts_raw)
             if isinstance(_parts_raw, (list, tuple)) else ["base", "text"])

    params = dict(raw)
    if req.qr_data:
        params.update(_qr_matrix_params(req.qr_data))
        params["qr_enable"] = True

    def _obj_name(part: str, ftype: str, cname: str) -> str:
        bits = [part] + [b for b in (ftype, cname) if b]
        return " ".join(bits)

    part_meta = {
        "base": {
            "color": plat,
            "filament_type": plat_type,
            "filament_color": plat_name,
            "name": _obj_name("base", plat_type, plat_name),
        },
        "text": {
            "color": textc,
            "filament_type": text_type,
            "filament_color": text_name,
            "name": _obj_name("text", text_type, text_name),
        },
    }
    valid = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

    async with _render_sem:
        workdir = tempfile.mkdtemp(prefix="render3mf_")
        try:
            scad_text = _resolve_scad_text(req)
            if scad_text is None:
                raise HTTPException(404, "unknown template or no source")
            scad_file = Path(workdir) / "model.scad"
            scad_file.write_text(scad_text)

            items = []
            for part in parts:
                off_path = Path(workdir) / f"{part}.off"
                argv = ["openscad", "-o", str(off_path), "--export-format", "off"]
                for key, value in params.items():
                    if not valid.match(str(key)):
                        raise HTTPException(400, f"invalid param name '{key}'")
                    argv += ["-D", f"{key}={_scad_literal(value)}"]
                argv += ["-D", f"part={_scad_literal(part)}"]
                argv.append(str(scad_file))
                proc = await asyncio.create_subprocess_exec(
                    *argv, cwd=workdir,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                try:
                    _, stderr = await asyncio.wait_for(
                        proc.communicate(), timeout=RENDER_TIMEOUT)
                except asyncio.TimeoutError:
                    proc.kill()
                    raise HTTPException(504, f"render of '{part}' exceeded {RENDER_TIMEOUT}s")
                if proc.returncode != 0 or not off_path.is_file():
                    detail = stderr.decode(errors="replace")[-2000:]
                    raise HTTPException(422, f"openscad part '{part}' failed: {detail}")
                meta = part_meta.get(part, {"color": "#cccccc", "name": part})
                items.append({
                    "path": str(off_path),
                    "color": meta.get("color", "#cccccc"),
                    "name": meta.get("name") or part,
                    "filament_type": meta.get("filament_type") or "",
                    "filament_color": meta.get("filament_color") or "",
                })

            if not items:
                raise HTTPException(422, "no parts rendered")

            try:
                data = _build_3mf(items)
            except Exception as exc:  # noqa: BLE001
                raise HTTPException(500, f"3MF assembly failed: {exc}")
        finally:
            shutil.rmtree(workdir, ignore_errors=True)

    return Response(
        content=data,
        media_type="application/vnd.ms-package.3dmanufacturing-3dmodel+xml",
        headers={"Content-Disposition": 'attachment; filename="model.3mf"'},
    )


def _resolve_scad_text(req: RenderRequest):
    """Return SCAD source for a render request (template_name | scad_source)."""
    if req.template_name:
        if not _TEMPLATE_NAME_RE.match(req.template_name):
            return None
        src_path = TEMPLATE_DIR / f"{req.template_name}.scad"
        if not src_path.is_file():
            return None
        return src_path.read_text()
    return req.scad_source or ""


def _safe_color(hex_color: str) -> str:
    """Return an sRGB hex (no leading #) sanity-checked for 3MF metadata."""
    c = (hex_color or "").lstrip("#").strip()
    return c if re.match(r"^[0-9A-Fa-f]{6}$", c) else "cccccc"


def _build_3mf(items: list[dict]) -> bytes:
    """Assemble a multi-object 3MF from OFF mesh files.

    Each item becomes a separate <item> referring to its own <mesh>, tagged
    with a production <metadata name="color"> so the slicer pre-tints the part
    and (more importantly) presents each object as a distinct filament slot.
    """
    import xml.etree.ElementTree as ET
    from io import BytesIO
    import zipfile

    NS = "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
    P_NS = "http://schemas.microsoft.com/3dmanufacturing/production/2015/06"
    ET.register_namespace("", NS)
    ET.register_namespace("p", P_NS)

    meshes = []
    for it in items:
        verts, tris = _parse_off(it["path"])
        meshes.append({
            "verts": verts,
            "tris": tris,
            "color": it.get("color") or "#cccccc",
            "name": it.get("name") or "",
            "filament_type": it.get("filament_type") or "",
            "filament_color": it.get("filament_color") or "",
        })

    def mesh_xml(verts, tris):
        mesh = ET.Element(f"{{{NS}}}mesh")
        vels = ET.SubElement(mesh, f"{{{NS}}}vertices")
        for (x, y, z) in verts:
            v = ET.SubElement(vels, f"{{{NS}}}vertex")
            v.set("x", repr(float(x)))
            v.set("y", repr(float(y)))
            v.set("z", repr(float(z)))
        tris_el = ET.SubElement(mesh, f"{{{NS}}}triangles")
        for (a, b, c) in tris:
            t = ET.SubElement(tris_el, f"{{{NS}}}triangle")
            t.set("v1", str(int(a)))
            t.set("v2", str(int(b)))
            t.set("v3", str(int(c)))
        return mesh

    objects = ET.Element(f"{{{NS}}}objects")
    item_ids = []
    for idx, mesh in enumerate(meshes, start=1):
        obj = ET.SubElement(objects, f"{{{NS}}}object")
        obj.set("id", str(idx))
        obj.set("type", "model")
        if mesh["name"]:
            obj.set("name", mesh["name"])
        obj.set(f"{{{P_NS}}}uuid", f"00000000-0000-0000-0000-{idx:012d}")
        meta = ET.SubElement(obj, f"{{{P_NS}}}metadata")
        meta.set("name", "color")
        meta.set("type", "http://schemas.microsoft.com/3dmanufacturing/material/color")
        meta.text = "#" + _safe_color(mesh["color"])
        if mesh["filament_type"]:
            mt = ET.SubElement(obj, f"{{{P_NS}}}metadata")
            mt.set("name", "filament_type")
            mt.text = mesh["filament_type"]
        if mesh["filament_color"]:
            mc = ET.SubElement(obj, f"{{{P_NS}}}metadata")
            mc.set("name", "filament_color")
            mc.text = mesh["filament_color"]
        obj.append(mesh_xml(mesh["verts"], mesh["tris"]))
        item_ids.append(idx)

    build = ET.Element(f"{{{NS}}}build")
    for iid in item_ids:
        item = ET.SubElement(build, f"{{{NS}}}item")
        item.set("objectid", str(iid))

    model = ET.Element(f"{{{NS}}}model")
    model.set("unit", "millimeter")
    model.set("xml:lang", "en-US")
    model.set(f"{{{P_NS}}}requiredext", "p")
    model.append(objects)
    model.append(build)

    model_xml = ET.tostring(model, encoding="unicode")
    # ElementTree won't emit the xml:lang namespace unless we declare it.
    model_xml = model_xml.replace(
        "<model ", '<model xmlns:xml="http://www.w3.org/XML/1998/namespace" ', 1)
    model_xml = '<?xml version="1.0" encoding="UTF-8"?>\n' + model_xml

    buf = BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml",
                   '<?xml version="1.0" encoding="UTF-8"?>\n'
                   '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                   '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                   '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>'
                   '</Types>')
        z.writestr("_rels/.rels",
                   '<?xml version="1.0" encoding="UTF-8"?>\n'
                   '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   '<Relationship Target="/3D/3dmodel.model" '
                   'Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>'
                   '</Relationships>')
        z.writestr("3D/3dmodel.model", model_xml)
    return buf.getvalue()


def _parse_off(path: str):
    """Parse an OpenSCAD OFF file -> (list[(x,y,z)], list[(a,b,c)]).

    Handles both header styles:
        OFF\n<v> <f> <e>\n...
        OFF <v> <f> <e>\n...
    and skips colour/normal attributes on face lines (COFF).
    """
    with open(path) as fh:
        lines = fh.readlines()
    if not lines or not lines[0].strip().upper().startswith("OFF"):
        raise ValueError(f"not an OFF file: {path}")

    first = lines[0].split()
    if len(first) >= 3:           # counts on the first line
        nverts = int(first[1])
    else:                          # counts on the second non-empty line
        i = 1
        while i < len(lines) and lines[i].strip() == "":
            i += 1
        nverts = int(lines[i].split()[0])

    # Flatten into tokens so blank lines and wrapping don't matter.
    tokens = []
    for ln in lines[1:]:
        tokens.extend(ln.split())

    ti = 0
    # skip the count triple if it appeared on the second line
    if len(first) < 3:
        ti = 3
    verts = []
    for _ in range(nverts):
        verts.append((float(tokens[ti]), float(tokens[ti + 1]), float(tokens[ti + 2])))
        ti += 3
    faces = []
    while ti < len(tokens):
        cnt = int(tokens[ti]); ti += 1
        # face entries: vertex indices, then optional colour (3 floats) / normal
        ids = [int(tokens[ti + k]) for k in range(cnt)]; ti += cnt
        if cnt < 3:
            continue
        for k in range(1, cnt - 1):
            faces.append((ids[0], ids[k], ids[k + 1]))
    return verts, faces


@app.post("/render")
async def render(req: RenderRequest):
    fmt = req.format.lower()
    if fmt not in ALLOWED_FORMATS:
        raise HTTPException(400, f"format must be one of {sorted(ALLOWED_FORMATS)}")

    if bool(req.template_name) == bool(req.scad_source):
        raise HTTPException(400, "provide exactly one of template_name or scad_source")

    if req.template_name:
        if not _TEMPLATE_NAME_RE.match(req.template_name):
            raise HTTPException(400, "invalid template_name")
        src_path = TEMPLATE_DIR / f"{req.template_name}.scad"
        if not src_path.is_file():
            raise HTTPException(404, f"unknown template '{req.template_name}'")
        scad_text = src_path.read_text()
    else:
        scad_text = req.scad_source or ""

    async with _render_sem:
        workdir = tempfile.mkdtemp(prefix="render_")
        try:
            scad_file = Path(workdir) / "model.scad"
            out_file = Path(workdir) / f"model.{fmt}"
            scad_file.write_text(scad_text)

            params = dict(req.params)
            if req.qr_data:
                params.update(_qr_matrix_params(req.qr_data))
                params["qr_enable"] = True

            argv = ["openscad", "-o", str(out_file)]
            if fmt == "stl":
                # Binary STL: ASCII STL from OpenSCAD is rejected by some
                # slicers (e.g. Anycubic Slicer Next); binary is universal.
                argv += ["--export-format", "binstl"]
            for key, value in params.items():
                if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", str(key)):
                    raise HTTPException(400, f"invalid param name '{key}'")
                argv += ["-D", f"{key}={_scad_literal(value)}"]
            argv.append(str(scad_file))

            proc = await asyncio.create_subprocess_exec(
                *argv,
                cwd=workdir,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                _, stderr = await asyncio.wait_for(
                    proc.communicate(), timeout=RENDER_TIMEOUT
                )
            except asyncio.TimeoutError:
                proc.kill()
                raise HTTPException(504, f"render exceeded {RENDER_TIMEOUT}s")

            if proc.returncode != 0:
                detail = stderr.decode(errors="replace")[-2000:]
                raise HTTPException(422, f"openscad failed: {detail}")
            if not out_file.is_file() or out_file.stat().st_size == 0:
                raise HTTPException(422, "openscad produced no output")

            data = out_file.read_bytes()
        finally:
            shutil.rmtree(workdir, ignore_errors=True)

    media = "model/stl" if fmt == "stl" else "application/octet-stream"
    return Response(
        content=data,
        media_type=media,
        headers={"Content-Disposition": f'attachment; filename="model.{fmt}"'},
    )
