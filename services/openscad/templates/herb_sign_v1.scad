// herb_sign_v1.scad — parametric herb sign for FDM printing
// Rendered headless by comserv2-openscad service via -D params.
// All text is raised for single-color or paint-fill printing.

/* [Sign dimensions] */
sign_w = 120;      // width mm (max ~230 for Anycubic bed)
sign_h = 80;       // height mm
base_t = 4;        // base plate thickness mm
text_h = 1.2;      // raised text height mm
corner_r = 4;      // corner radius mm

/* [Content] */
title = "Yarrow";
subtitle = "Achillea millefolium";
body1 = "Attracts bees & butterflies.";
body2 = "Drought tolerant.";
url_text = "forager.com";

/* [Options] */
part = "full";         // "full" | "base" | "text" — for multi-colour printing
border = true;         // raised border frame
qr_enable = false;     // render raised QR code (bottom-right)
qr_bits = "";          // QR matrix as row-major "0101..." string (from service)
qr_n = 0;              // QR matrix side length
qr_size = 24;          // printed QR side mm (raised modules)
qr_recess = false;     // recessed square for QR sticker (legacy option)
qr_depth = 0.6;        // QR recess depth mm
mount_holes = false;   // two screw holes top corners
hole_d = 4;            // hole diameter mm

/* [Fonts] */
title_font = "DejaVu Sans:style=Bold";
subtitle_font = "DejaVu Sans:style=Oblique";
body_font = "DejaVu Sans";

// ---- derived sizes (scale with sign height, clamped to sign width) ----
// usable width for text (border + margins, minus QR block when enabled)
usable_w = sign_w - sign_h * 0.16 - (qr_enable ? qr_size + sign_h * 0.08 : 0);
// clamp a font size so a string of n chars fits usable_w (~0.72*size per glyph
// — conservative for DejaVu Bold so text can never overrun the plate)
function fit(sz, s) = (len(s) == 0) ? sz : min(sz, usable_w / (len(s) * 0.72));

title_size = sign_h * 0.16;
subtitle_size = sign_h * 0.085;
body_size = sign_h * 0.075;
url_size = sign_h * 0.065;
margin = sign_h * 0.08;

// When QR is enabled, text shifts left to clear the QR square
text_shift = qr_enable ? -qr_size / 2 - margin / 2 : 0;

module rounded_plate(w, h, t, r) {
    linear_extrude(t)
        offset(r = r)
            square([w - 2 * r, h - 2 * r], center = true);
}

module sign_text(s, size, font, y) {
    translate([text_shift, y, base_t])
        linear_extrude(text_h)
            text(s, size = size, font = font,
                 halign = "center", valign = "center");
}

// Raised QR code from row-major bit string, bottom-right corner
module qr_code() {
    cell = qr_size / qr_n;
    ox = sign_w / 2 - qr_size - margin;   // left edge of QR
    oy = -sign_h / 2 + margin;            // bottom edge of QR
    translate([ox, oy, base_t])
        for (row = [0 : qr_n - 1])
            for (col = [0 : qr_n - 1])
                if (qr_bits[row * qr_n + col] == "1")
                    // row 0 is top of the QR -> highest y
                    translate([col * cell, qr_size - (row + 1) * cell, 0])
                        cube([cell + 0.001, cell + 0.001, text_h]);
}

// part selection for multi-colour printing:
//   full = base + raised features (single-colour print)
//   base = plate only (filament colour 1)
//   text = border + text + QR only (filament colour 2) — same coordinates,
//          so importing base+text together in the slicer aligns perfectly.
show_base = (part == "full" || part == "base");
show_text = (part == "full" || part == "text");

difference() {
    union() {
        // base plate
        if (show_base)
            rounded_plate(sign_w, sign_h, base_t, corner_r);

        if (show_text) {
            // border frame
            if (border)
                translate([0, 0, base_t])
                    linear_extrude(text_h)
                        difference() {
                            offset(r = corner_r)
                                square([sign_w - 2 * corner_r, sign_h - 2 * corner_r], center = true);
                            offset(r = corner_r - 1.2)
                                square([sign_w - 2 * corner_r, sign_h - 2 * corner_r], center = true);
                        }

            // text stack (top to bottom) — each line clamped to fit the width
            sign_text(title,    fit(title_size, title),       title_font,    sign_h * 0.30);
            sign_text(subtitle, fit(subtitle_size, subtitle), subtitle_font, sign_h * 0.12);
            if (body1 != "") sign_text(body1, fit(body_size, body1), body_font, -sign_h * 0.05);
            if (body2 != "") sign_text(body2, fit(body_size, body2), body_font, -sign_h * 0.18);
            if (url_text != "") sign_text(url_text, fit(url_size, url_text), body_font, -sign_h * 0.34);

            // raised QR code
            if (qr_enable && qr_n > 0) qr_code();
        }
    }

    // QR sticker recess, bottom-right
    if (qr_recess)
        translate([sign_w / 2 - qr_size / 2 - margin,
                   -sign_h / 2 + qr_size / 2 + margin,
                   base_t - qr_depth])
            linear_extrude(qr_depth + text_h + 0.1)
                square([qr_size, qr_size], center = true);

    // mounting holes, top corners
    if (mount_holes)
        for (x = [-1, 1])
            translate([x * (sign_w / 2 - margin - hole_d),
                       sign_h / 2 - margin - hole_d / 2, -0.5])
                cylinder(h = base_t + text_h + 1, d = hole_d, $fn = 32);
}
