/**
 * sign-preview.js — live WYSIWYG preview for the Herb Sign Generator
 * (/signgenerator/preview). Draws the sign on a <canvas> using the same
 * proportional layout math as services/openscad/templates/herb_sign_v1.scad,
 * so what you see closely matches the rendered STL.
 *
 * Also scales each text field's maxlength with the sign width so wording
 * cannot overflow the physical sign.
 *
 * Wired via js_load.tt (route match /signgenerator). No inline scripts.
 */
(function () {
    'use strict';

    function init() {
        initPrintPage();
        var canvas = document.getElementById('sign-preview-canvas');
        var form = document.querySelector('form.app-form[action="/signgenerator/generate"]');
        if (!canvas || !form) return; // not the preview page

        var ctx = canvas.getContext('2d');
        var fields = {};
        ['title', 'subtitle', 'body1', 'body2', 'url_text', 'sign_w', 'sign_h']
            .forEach(function (n) { fields[n] = form.querySelector('[name="' + n + '"]'); });

        var qrOn = true; // controller always sends qr_data
        var BED_W = 230, BED_H = 230; // printer bed mm
        var qrMatrix = null; // {qr_bits, qr_n} fetched from the service

        // Fetch the REAL QR matrix (same one used in the STL) so the
        // on-screen preview is scannable.
        var qrData = canvas.getAttribute('data-qr-data') || '';
        if (qrData) {
            fetch('/signgenerator/qr_matrix?data=' + encodeURIComponent(qrData))
                .then(function (r) { return r.json(); })
                .then(function (j) {
                    if (j && j.qr_bits && j.qr_n) { qrMatrix = j; draw(); }
                })
                .catch(function () { /* placeholder stays */ });
        }

        function val(n, dflt) {
            var el = fields[n];
            if (!el) return dflt;
            var v = el.value;
            return (v === '' || v === null) ? dflt : v;
        }

        // Approximate chars that fit a line: sign width (mm) minus margins,
        // divided by average glyph width (~0.55 * font size in mm).
        function maxChars(signW, signH, fontMm, qrPad) {
            var usable = signW - signH * 0.16 - (qrPad || 0);
            return Math.max(8, Math.floor(usable / (fontMm * 0.55)));
        }

        function applyLimits() {
            var w = parseFloat(val('sign_w', 120));
            var h = parseFloat(val('sign_h', 80));
            var qrPad = qrOn ? 24 + h * 0.08 : 0;
            var limits = {
                title:    maxChars(w, h, h * 0.16, qrPad),
                subtitle: maxChars(w, h, h * 0.085, qrPad),
                body1:    maxChars(w, h, h * 0.075, qrPad),
                body2:    maxChars(w, h, h * 0.075, qrPad),
                url_text: maxChars(w, h, h * 0.065, qrPad)
            };
            Object.keys(limits).forEach(function (n) {
                var el = fields[n];
                if (!el) return;
                // NEVER truncate or block existing/typed content — the limit
                // is advisory. Over-limit text will render squeezed/overflow
                // on the physical sign; the counter turns red to warn.
                el.removeAttribute('maxlength');
                var hint = document.getElementById(n + '-limit-hint');
                if (hint) {
                    hint.textContent = el.value.length + '/' + limits[n];
                    hint.style.color = el.value.length > limits[n]
                        ? 'var(--error-color, #c00)' : '';
                    hint.title = el.value.length > limits[n]
                        ? 'Text longer than fits this sign size — it will be shrunk or overflow'
                        : '';
                }
            });
        }

        function drawQr(x, y, size) {
            if (qrMatrix) {
                // real modules — scannable on screen
                var n = qrMatrix.qr_n;
                var cell = size / n;
                ctx.fillStyle = '#fff';
                ctx.fillRect(x - cell, y - cell, size + 2 * cell, size + 2 * cell);
                ctx.fillStyle = '#000';
                for (var row = 0; row < n; row++)
                    for (var col = 0; col < n; col++)
                        if (qrMatrix.qr_bits[row * n + col] === '1')
                            ctx.fillRect(x + col * cell, y + row * cell,
                                cell + 0.5, cell + 0.5);
                return;
            }
            // fallback placeholder until the matrix arrives
            ctx.fillStyle = 'rgba(60,60,60,0.85)';
            var pcell = size / 21;
            function finder(fx, fy) {
                ctx.fillRect(fx, fy, pcell * 7, pcell * 7);
            }
            finder(x, y);
            finder(x + size - pcell * 7, y);
            finder(x, y + size - pcell * 7);
        }

        function draw() {
            var w = parseFloat(val('sign_w', 120));
            var h = parseFloat(val('sign_h', 80));
            if (!(w > 0) || !(h > 0)) return;

            // Canvas shows the whole BED, as large as the screen allows.
            // Target: ACTUAL SIZE (1 mm = 96/25.4 CSS px) so the on-screen
            // sign matches its physical size; shrinks only if the window
            // is narrower than the bed.
            var PX_PER_MM = 96 / 25.4; // CSS reference pixel ≈ actual size
            var boxW = canvas.parentElement.clientWidth || 720;
            var maxH = Math.max(300, (window.innerHeight || 800) - 160);
            var scale = Math.min(PX_PER_MM, boxW / BED_W, maxH / BED_H);
            canvas.width = Math.round(BED_W * scale);
            canvas.height = Math.round(BED_H * scale);

            var mm = scale; // px per mm
            ctx.clearRect(0, 0, canvas.width, canvas.height);

            // bed outline
            ctx.strokeStyle = 'rgba(128,128,128,0.6)';
            ctx.lineWidth = 1;
            ctx.setLineDash([6, 4]);
            ctx.strokeRect(0.5, 0.5, canvas.width - 1, canvas.height - 1);
            ctx.setLineDash([]);
            ctx.fillStyle = 'rgba(128,128,128,0.6)';
            ctx.font = (10) + 'px sans-serif';
            ctx.textAlign = 'left';
            ctx.fillText(BED_W + ' x ' + BED_H + ' mm bed', 6, 14);

            // sign plate, centered on the bed
            var signW = w * mm, signH = h * mm;
            var ox = (canvas.width - signW) / 2;
            var oy = (canvas.height - signH) / 2;
            var oversize = (w > BED_W || h > BED_H);

            var r = 4 * mm;
            var plateCol = (fields.plate_color && fields.plate_color.value) || '#d8cfa8';
            var textCol = (fields.text_color && fields.text_color.value) || '#4a3b18';
            ctx.fillStyle = oversize ? 'rgba(220,120,120,0.85)' : plateCol;
            ctx.strokeStyle = 'rgba(0,0,0,0.35)';
            ctx.lineWidth = 1;
            roundRect(ox, oy, signW, signH, r, true, true);

            // border frame
            ctx.strokeStyle = textCol;
            ctx.globalAlpha = 0.8;
            ctx.lineWidth = 1.2 * mm;
            roundRect(ox + ctx.lineWidth / 2, oy + ctx.lineWidth / 2,
                signW - ctx.lineWidth, signH - ctx.lineWidth,
                r, false, true);
            ctx.globalAlpha = 1;

            var margin = h * 0.08 * mm;
            var qrSize = 24 * mm;
            var textShift = qrOn ? -(24 / 2 + h * 0.08 / 2) * mm : 0;
            var cx = ox + signW / 2 + textShift;

            // usable text width in mm — same formula as the SCAD template
            var usableW = w - h * 0.16 - (qrOn ? 24 + h * 0.08 : 0);
            function fitSize(szMm, text) {
                if (!text) return szMm;
                return Math.min(szMm, usableW / (text.length * 0.72));
            }

            ctx.fillStyle = textCol;
            ctx.textAlign = 'center';

            line(val('title', ''), fitSize(h * 0.16, val('title', '')), 'bold', cx, oy + (0.5 - 0.30) * signH);
            line(val('subtitle', ''), fitSize(h * 0.085, val('subtitle', '')), 'italic', cx, oy + (0.5 - 0.12) * signH);
            line(val('body1', ''), fitSize(h * 0.075, val('body1', '')), '', cx, oy + (0.5 + 0.05) * signH);
            line(val('body2', ''), fitSize(h * 0.075, val('body2', '')), '', cx, oy + (0.5 + 0.18) * signH);
            line(val('url_text', ''), fitSize(h * 0.065, val('url_text', '')), '', cx, oy + (0.5 + 0.34) * signH);

            if (qrOn) {
                drawQr(
                    ox + signW - qrSize - margin,
                    oy + signH - qrSize - margin,
                    qrSize);
            }

            if (oversize) {
                ctx.fillStyle = 'var(--error-color, #c00)';
                ctx.fillStyle = '#c00000';
                ctx.textAlign = 'center';
                ctx.font = 'bold 14px sans-serif';
                ctx.fillText('SIGN LARGER THAN BED', canvas.width / 2, canvas.height - 10);
            }

            function line(text, sizeMm, style, x, y) {
                if (!text) return;
                ctx.font = (style ? style + ' ' : '') + (sizeMm * mm) + 'px "DejaVu Sans", sans-serif';
                ctx.fillText(text, x, y + sizeMm * mm * 0.35);
            }
        }

        function roundRect(x, y, w2, h2, r, fill, stroke) {
            ctx.beginPath();
            ctx.moveTo(x + r, y);
            ctx.arcTo(x + w2, y, x + w2, y + h2, r);
            ctx.arcTo(x + w2, y + h2, x, y + h2, r);
            ctx.arcTo(x, y + h2, x, y, r);
            ctx.arcTo(x, y, x + w2, y, r);
            ctx.closePath();
            if (fill) ctx.fill();
            if (stroke) ctx.stroke();
        }

        function refresh() { applyLimits(); draw(); }

        Object.keys(fields).forEach(function (n) {
            if (!fields[n]) return;
            fields[n].addEventListener('input', refresh);
            fields[n].addEventListener('change', refresh); // number spinners / pickers
        });
        ['plate_color', 'text_color'].forEach(function (n) {
            var el = form.querySelector('[name="' + n + '"]');
            if (el) {
                fields[n] = el;
                el.addEventListener('input', refresh);
                el.addEventListener('change', refresh);
            }
        });
        window.addEventListener('resize', draw);
        refresh();
    }

    // ---- print view (/signgenerator/print/<id>): real QR + print button ----
    function initPrintPage() {
        var sheet = document.querySelector('.sign-sheet');
        var qrCanvas = document.getElementById('sign-print-qr');
        var btn = document.querySelector('[data-action="sign-print"]');
        if (btn) btn.addEventListener('click', function () { window.print(); });

        // Shrink any text line that overflows the sheet width (uses real
        // font metrics — mirrors the STL's width clamp).
        if (sheet) {
            var pad = qrCanvas ? qrCanvas.offsetWidth + 16 : 8;
            Array.prototype.forEach.call(sheet.children, function (el) {
                if (el === qrCanvas) return;
                var avail = sheet.clientWidth - pad;
                if (avail < 40) return;
                var size = parseFloat(getComputedStyle(el).fontSize);
                var guard = 40;
                while (el.scrollWidth > avail && size > 4 && guard--) {
                    size *= 0.94;
                    el.style.fontSize = size + 'px';
                }
            });
        }

        if (!qrCanvas) return;
        var data = qrCanvas.getAttribute('data-qr-data') || '';
        if (!data) return;
        fetch('/signgenerator/qr_matrix?data=' + encodeURIComponent(data))
            .then(function (r) { return r.json(); })
            .then(function (j) {
                if (!(j && j.qr_bits && j.qr_n)) return;
                var n = j.qr_n, px = 4;
                qrCanvas.width = n * px;
                qrCanvas.height = n * px;
                var qctx = qrCanvas.getContext('2d');
                qctx.fillStyle = '#fff';
                qctx.fillRect(0, 0, qrCanvas.width, qrCanvas.height);
                qctx.fillStyle = '#000';
                for (var row = 0; row < n; row++)
                    for (var col = 0; col < n; col++)
                        if (j.qr_bits[row * n + col] === '1')
                            qctx.fillRect(col * px, row * px, px, px);
            })
            .catch(function () {});
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
