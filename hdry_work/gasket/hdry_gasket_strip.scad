// HDRY TPU gasket strip — printable substitute for channel gasket
// Cross-section default: 3 mm wide × 3 mm thick (fills both sides of channel)
// (kit tape is 6×3; channel fit: 3 wide; depth 3 so both faces seal)
//
// Modes:
//   straight  — one bar, length_mm must fit bed
//   coil      — serpentine pack for long runs on bed_mm square
//   segments  — export one bed-sized piece; set which_seg 0..n-1
//
// Print: TPU, 2–3 walls, 0–15% gyroid, no supports, flat on bed (thick_mm = Z).

length_mm   = 215;
width_mm    = 3;     // across channel (Y)
thick_mm    = 3;     // depth / print Z — fills both sides
mode        = "straight"; // straight | coil | segments
bed_mm      = 220;
coil_gap    = 2;
segment_mm  = 220;
which_seg   = 0;
width_extra = 0.0;
thick_extra = 0.0;

w = width_mm + width_extra;
t = thick_mm + thick_extra;

module strip_straight(L) {
    cube([max(L, 0.01), w, t], center = false);
}

// Serpentine folds a long strip onto the bed
module strip_serpentine(L) {
    pitch = w + coil_gap;
    usable = bed_mm - 2;
    row_len = usable;
    n_rows = max(1, ceil(L / row_len));
    for (r = [0 : n_rows - 1]) {
        remain_start = r * row_len;
        this_len = min(row_len, max(0, L - remain_start));
        if (this_len > 0.01) {
            y = r * pitch;
            if (r % 2 == 0) {
                translate([0, y, 0]) cube([this_len, w, t]);
            } else {
                translate([row_len - this_len, y, 0]) cube([this_len, w, t]);
            }
            if (r > 0) {
                xj = (r % 2 == 0) ? 0 : (row_len - w);
                translate([xj, (r - 1) * pitch + w - 0.01, 0])
                    cube([w, pitch - w + 0.02, t]);
            }
        }
    }
}

n_seg = max(1, ceil(length_mm / segment_mm));
seg_L = (which_seg >= n_seg - 1)
    ? length_mm - segment_mm * (n_seg - 1)
    : segment_mm;

if (mode == "straight") {
    strip_straight(length_mm);
} else if (mode == "coil") {
    strip_serpentine(length_mm);
} else { // segments
    strip_straight(max(seg_L, 0.01));
}
