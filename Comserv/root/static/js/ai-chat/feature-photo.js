// ai-chat/feature-photo.js — the ONE web view of the shared photo / barcode reader.
// Chat-with-AI cards, the /Inventory/invoice "Read a photo" panel and the admin
// /Inventory/photo_reads page all call the same /api/app/photo/* endpoints the
// Android app uses (Comserv::Util::Inventory::PhotoRead). No logic lives here
// beyond drawing the result and posting what the person chose.
(function () {
    'use strict';
    window.ComservChat = window.ComservChat || {};

    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, function (ch) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch];
        });
    }
    function api(path, body) {
        var opt = { credentials: 'same-origin' };
        if (body instanceof FormData) { opt.method = 'POST'; opt.body = body; }
        else if (body) { opt.method = 'POST'; opt.headers = { 'Content-Type': 'application/json' }; opt.body = JSON.stringify(body); }
        return fetch(path, opt).then(function (r) { return r.json(); });
    }
    function hostEl(opts) {
        return (opts && opts.host) || document.getElementById('chat-messages') || document.body;
    }
    function card(host, title) {
        var wrap = document.createElement('div');
        wrap.className = 'msg-wrapper msg-wrapper-ai photo-card';
        var box = document.createElement('div');
        box.className = 'message system-message';
        box.style.maxWidth = '680px';
        box.innerHTML = '<div style="font-weight:bold;margin-bottom:6px">' + esc(title) + '</div>' +
            '<div class="pc-status" style="margin:4px 0"></div><div class="pc-body"></div>';
        wrap.appendChild(box);
        host.appendChild(wrap);
        if (host.scrollHeight) host.scrollTop = host.scrollHeight;
        var st = box.querySelector('.pc-status');
        return { box: box, body: box.querySelector('.pc-body'),
                 say: function (t, bad) { st.textContent = t; st.style.color = bad ? '#b00' : ''; } };
    }
    function num(v) { var n = parseFloat(v); return isNaN(n) ? '' : n; }

    var INVOICE_STEPS = [
        '1. Take or pick a photo of the supplier invoice, packing slip, or receipt.',
        '2. The photo goes to the server. A vision model reads the supplier name, the invoice number and date, and every product line: name, printed code, quantity, and unit price. This can take several minutes. A barcode is not required. If no code is printed, a SKU is made from the name. That SKU is not a barcode, and the barcode field is left empty.',
        '3. You check the lines before anything is saved. Skip a line you do not want. Edit a SKU if the invented one is wrong. A line that already matches an inventory item is attached to that item. It does not create a second item.',
        '4. Confirm creates a missing supplier, creates the new items, and writes a draft supplier invoice. Stock does not change at this step.',
        '5. Stock moves only when that draft invoice is accepted. Each line\'s whole quantity goes to one location: the location on that invoice line, or the site\'s Default location if the line has none.',
        '6. One item can be in more than one place. The chest freezer and the fridge are two stock rows on the same item, not two items. This photo does not split a line between them. After the invoice is accepted, move part of the quantity from one location to the other.',
        '7. Scanning a barcode later looks the code up. If this item was created without that barcode, the scan will not find it and will offer to create another item. Attach the barcode to the existing item before you rely on scan.'
    ];
    function showInvoiceSteps() {
        var old = document.getElementById('invoice-photo-steps');
        if (old) old.parentNode.removeChild(old);
        var wrap = document.createElement('div');
        wrap.id = 'invoice-photo-steps';
        wrap.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:10000;display:flex;align-items:center;justify-content:center;padding:16px;';
        var box = document.createElement('div');
        box.style.cssText = 'background:#fff;color:#111;max-width:640px;width:100%;max-height:80vh;overflow:auto;padding:16px 18px;border-radius:8px;';
        box.innerHTML = '<h3 style="margin:0 0 10px">What the invoice photo does</h3>' +
            INVOICE_STEPS.map(function (s) { return '<p style="margin:0 0 8px">' + esc(s) + '</p>'; }).join('') +
            '<p style="text-align:right;margin:12px 0 0"><button type="button" class="pc-steps-close">Close</button></p>';
        wrap.appendChild(box);
        function close() { if (wrap.parentNode) wrap.parentNode.removeChild(wrap); }
        wrap.addEventListener('click', function (e) { if (e.target === wrap) close(); });
        box.querySelector('.pc-steps-close').onclick = close;
        document.body.appendChild(wrap);
    }

    // ---------------------------------------------------------------- photo read
    function mountRead(host, readId, opts) {
        var invoice = !opts || opts.mode !== 'items';
        var k = card(host, (opts && opts.title) || (invoice ? 'Invoice photo' : 'Photo read'));
        if (invoice) {
            var stepsBtn = document.createElement('button');
            stepsBtn.type = 'button';
            stepsBtn.textContent = 'Steps';
            stepsBtn.style.marginLeft = '8px';
            k.box.querySelector('div').appendChild(stepsBtn);
            stepsBtn.onclick = function () { showInvoiceSteps(); };
            showInvoiceSteps();
        }
        var current = null;
        var locs = [];
        function poll() {
            api('/api/app/photo/read/' + readId).then(function (d) {
                if (!d.success) { k.say(d.error || 'Read failed', 1); return; }
                current = d;
                if (d.status === 'reading') { k.say('Reading the photo... (a cold model can take a few minutes)'); setTimeout(poll, 4000); return; }
                if (d.mode !== 'invoice' && (!d.locations || !d.locations.length)) {
                    api('/api/inventory/locations').then(function (g) { if (g && g.locations) { d.locations = g.locations; locs = g.locations; } render(d); },
                                                          function () { render(d); });
                    return;
                }
                render(d);
            }).catch(function (e) { k.say('Network error: ' + e, 1); });
        }
        function supplierHtml(s) {
            if (!s) return '';
            var h = '<p><b>Supplier on the invoice:</b> ' + esc(s.name || '(not read)') + '<br>';
            h += '<label><input type="radio" name="pc-sup-' + readId + '" value="pick" ' + (s.match_id || (s.candidates || []).length ? 'checked' : '') + '> Use </label>' +
                 '<select class="pc-sup-id">';
            var seen = {};
            if (s.match_id) { h += '<option value="' + s.match_id + '" selected>#' + s.match_id + ' (matched)</option>'; seen[s.match_id] = 1; }
            (s.candidates || []).forEach(function (cnd) {
                if (seen[cnd.id]) return;
                h += '<option value="' + cnd.id + '">' + esc(cnd.name) + ' (#' + cnd.id + ')</option>';
            });
            h += '</select><br>';
            var p = s.proposed || { name: s.name || '' };
            h += '<label><input type="radio" name="pc-sup-' + readId + '" value="create" ' + (!s.match_id && !(s.candidates || []).length ? 'checked' : '') + '> Add new supplier </label>' +
                 ['name', 'phone', 'email', 'address', 'website'].map(function (f) {
                     return '<input class="pc-sc-' + f + '" placeholder="' + f + '" size="12" value="' + esc(p[f]) + '">';
                 }).join(' ') + '</p>';
            return h;
        }
        function totalsHtml(inv) {
            if (!inv) return '';
            var f = function (v) { return v == null ? '-' : Number(v).toFixed(2); };
            return '<p>Invoice # <input class="pc-no" size="12" value="' + esc(inv.number) + '"> Date <input class="pc-date" size="10" value="' + esc(inv.date) + '"><br>' +
                'Lines sum <b>' + f(inv.lines_sum) + '</b> &middot; subtotal ' + f(inv.subtotal) + ' &middot; tax ' + f(inv.tax) +
                ' &middot; shipping ' + f(inv.shipping) + ' &middot; total ' + f(inv.total) +
                (inv.mismatch ? ' <span style="color:#b00;font-weight:bold">&#9888; lines do not add up to the invoice totals - check qty and prices</span>' : ' <span style="color:green">&#10003; adds up</span>') + '</p>';
        }
        function render(d) {
            var inv = d.mode === 'invoice';
            k.say(d.status === 'failed' ? ('Could not read lines: ' + (d.error || '') + ' Edit the text and Re-parse.') :
                  d.status === 'confirmed' ? 'Already confirmed.' : 'Read by ' + (d.engine || '?') + '. Check the text and every line, then Confirm.', d.status === 'failed');
            if (!inv && d.locations && !q('.pc-container')) {
                var picks = '<p><b>Container / location:</b> <select class="pc-container">' +
                    (d.location_id ? '' : '<option value="">-- pick the container --</option>') +
                    (d.locations || []).map(function (l) {
                        return '<option value="' + l.id + '"' + (d.location_id === l.id ? ' selected' : '') + '>' +
                               esc(l.name) + (l.code ? ' (' + esc(l.code) + ')' : '') + '</option>';
                    }).join('') + '</select></p>';
                var pre = document.createElement('div'); pre.innerHTML = picks;
                k.body.insertBefore(pre.firstChild, k.body.firstChild);
            }
            var h = '<details' + (d.status === 'failed' ? ' open' : '') + '><summary>Text read from the photo (edit, then Re-parse)</summary>' +
                    '<textarea class="pc-raw" rows="8" style="width:100%">' + esc(d.raw_text) + '</textarea>' +
                    '<button type="button" class="pc-reparse">Re-parse</button> ' +
                    (d.has_photo && d.status !== 'confirmed' ? '<button type="button" class="pc-rerun">Re-read photo</button>' : '') + '</details>';
            if (d.status === 'confirmed') { k.body.innerHTML = h; bind(); return; }
            h += supplierHtml(d.supplier) + totalsHtml(d.invoice);
            if ((d.lines || []).length) {
                h += '<table border="1" cellpadding="3" style="border-collapse:collapse;width:100%"><tr><th>#</th><th>Read</th><th>Qty</th>' +
                     (inv ? '<th>Unit price</th>' : '<th>Photo</th>') + '<th>Inventory</th><th>Action</th><th>New item name / SKU</th></tr>';
                d.lines.forEach(function (l) {
                    var m = l.match, p = l.proposed_sku || {};
                    h += '<tr data-ix="' + l.index + '"><td>' + l.index + '</td><td>' + esc(l.name) + (l.sku ? ' <small>(' + esc(l.sku) + ')</small>' : '') + '</td>' +
                        '<td><input class="pc-qty" size="4" value="' + esc(l.qty) + '"></td>' +
                        (inv ? '<td><input class="pc-price" size="6" value="' + esc(l.unit_price) + '"></td>'
                             : '<td><input type="radio" name="pc-att-' + readId + '" class="pc-att" value="' + l.index + '" title="Use this photo as the item picture"></td>') +
                        '<td>' + (m ? '#' + m.item_id + ' ' + esc(m.name) + ' <small>' + esc(m.sku) + '</small>' : '<i>not in inventory</i>') +
                        '<input type="hidden" class="pc-item" value="' + (m ? m.item_id : '') + '"></td>' +
                        '<td><select class="pc-act">' +
                        (inv ? '<option value="match"' + (m ? ' selected' : ' disabled') + '>attach to this item</option>' :
                               '<option value="count" selected>counted</option><option value="receive">new stock (receive)</option>' +
                               '<option value="use">consumed</option><option value="move">moved somewhere else</option><option value="skip">skip</option>') +
                        '<option value="create"' + (m ? '' : ' selected') + '>create new item</option><option value="skip">skip</option></select>' +
                        (!inv ? ' <select class="pc-to"><option value="">- moved to -</option>' : '') +
                        ((!inv && (d.locations || [])) ? (d.locations || []).map(function (l) {
                            return '<option value="' + l.id + '">' + esc(l.name) + '</option>';
                        }).join('') : '') + (!inv ? '</select>' : '') + '</td>' +
                        '<td><input class="pc-name" size="18" value="' + esc(p.name || l.name) + '"> <input class="pc-sku" size="9" placeholder="SKU" value="' + esc(p.sku) + '"></td></tr>';
                });
                h += '</table><p>' + (inv ? '<label><input type="checkbox" class="pc-inv" checked> create draft invoice</label> ' +
                     '<label><input type="checkbox" class="pc-keep"> keep the photo (debug backup)</label> ' :
                     '<b>What happened to each line?</b> (a count sets the on-hand to the number you checked) ') +
                     '<button type="button" class="pc-confirm">Confirm</button></p>';
            }
            k.body.innerHTML = h;
            bind();
        }
        function q(sel) { return k.body.querySelector(sel); }
        function bind() {
            var rp = q('.pc-reparse');
            if (rp) rp.onclick = function () {
                k.say('Re-parsing the text...');
                api('/api/app/photo/reparse', { read_id: readId, raw_text: q('.pc-raw').value }).then(function (r) {
                    if (!r.success) { k.say(r.error || 'Re-parse failed', 1); return; }
                    poll();
                });
            };
            var rr = q('.pc-rerun');
            if (rr) rr.onclick = function () {
                api('/api/app/photo/rerun', { read_id: readId }).then(function (r) {
                    if (!r.success) { k.say(r.error || 'Re-read failed', 1); return; } poll();
                });
            };
            var cb = q('.pc-confirm');
            if (cb) cb.onclick = confirmRead;
        }
        function confirmRead() {
            var d = current, lines = [], body = { read_id: readId, lines: lines, create_invoice: 0 };
            var cont = k.body.querySelector('.pc-container');
            var containerId = cont ? cont.value : (d.location_id || '');
            var isCount = d.mode !== 'invoice';
            k.body.querySelectorAll('tr[data-ix]').forEach(function (tr) {
                var act = tr.querySelector('.pc-act').value, ln = { index: +tr.dataset.ix, action: act, qty: num(tr.querySelector('.pc-qty').value) };
                var pr = tr.querySelector('.pc-price'); if (pr) ln.unit_price = num(pr.value);
                if (act === 'match') ln.item_id = +tr.querySelector('.pc-item').value;
                if (isCount) {
                    ln.location_id = containerId ? +containerId : undefined;
                    if (act === 'move') {
                        var to = tr.querySelector('.pc-to');
                        ln.to_location_id = (to && to.value) ? +to.value : undefined;
                    }
                }
                if (act === 'create') { ln.name = tr.querySelector('.pc-name').value; ln.sku = tr.querySelector('.pc-sku').value; }
                var at = tr.querySelector('.pc-att'); if (at && at.checked) ln.attach_photo = 1;
                lines.push(ln);
            });
            if (d.mode === 'invoice') {
                body.create_invoice = q('.pc-inv') && q('.pc-inv').checked ? 1 : 0;
                body.keep_photo = q('.pc-keep') && q('.pc-keep').checked ? 1 : 0;
                body.invoice_number = q('.pc-no') ? q('.pc-no').value : '';
                body.invoice_date = q('.pc-date') ? q('.pc-date').value : '';
                var mode = k.body.querySelector('input[name="pc-sup-' + readId + '"]:checked');
                if (mode && mode.value === 'create') {
                    body.supplier_create = {};
                    ['name', 'phone', 'email', 'address', 'website'].forEach(function (f) { body.supplier_create[f] = q('.pc-sc-' + f).value; });
                } else if (q('.pc-sup-id') && q('.pc-sup-id').value) {
                    body.supplier_id = +q('.pc-sup-id').value;
                }
            }
            var n = lines.filter(function (l) { return l.action === 'create'; }).length;
            var msg;
            if (isCount) {
                if (!containerId) { k.say('Pick the container this photo is of first.', 1); return; }
                msg = 'Count ' + lines.length + ' line(s) into ' +
                      (cont ? cont.options[cont.selectedIndex].text : 'that location') +
                      (n ? ', create ' + n + ' new item(s)' : '') + '?';
            } else {
                msg = 'Create ' + n + ' new item(s)' + (body.supplier_create ? ', a new supplier' : '') +
                      (body.create_invoice ? ' and a DRAFT invoice' : '') + '?';
            }
            if (!window.confirm(msg)) return;
            var path = isCount ? '/api/app/photo/count/confirm'
                               : '/api/app/photo/confirm';
            if (isCount) body = { read_id: readId, decisions: lines };
            api(path, body).then(function (r) {
                if (!r.success) { k.say(r.error || (isCount ? 'Count failed' : 'Confirm failed'), 1); return; }
                if (isCount) {
                    k.say('Counted ' + (r.confirmed || 0) + ' line(s). Stock updated.');
                    return;
                }
                k.say('Done: ' + r.created_items.length + ' item(s) created, ' + r.matched.length + ' attached' +
                      (r.supplier_created ? ', supplier #' + r.supplier_created + ' added' : '') +
                      (r.invoice_id ? ', draft invoice #' + r.invoice_id : '') + '.');
                k.body.innerHTML = r.invoice_id ? '<a href="/Inventory/invoice/view/' + r.invoice_id + '">Open the draft invoice</a>' : '';
            }).catch(function (e) { k.say('Network error: ' + e, 1); });
        }
        poll();
        return k;
    }

    function upload(host, file, mode) {
        var fd = new FormData();
        fd.append('photo', file);
        fd.append('mode', mode || 'invoice');
        return api('/api/app/photo/read', fd).then(function (d) {
            if (!d.success) { var k = card(host, 'Photo read'); k.say(d.error || 'Upload failed', 1); return; }
            mountRead(host, d.read_id, { title: (mode === 'items' ? 'Items' : 'Invoice') + ' photo', mode: mode || 'invoice' });
        });
    }

    // ---------------------------------------------------------------- barcode scan
    function scanCard(host, s) {
        var k = card(host, 'Barcode / item scan');
        var it = s.item, locs = s.locations || [];
        function locSel(cls) {
            return '<select class="' + cls + '">' + locs.map(function (l) { return '<option value="' + l.id + '">' + esc(l.name) + '</option>'; }).join('') + '</select>';
        }
        var h = '';
        if (it) {
            h += '<p><b>' + esc(it.name) + '</b> <small>' + esc(it.sku) + '</small>' + (it.image_url ? '<br><img src="' + esc(it.image_url) + '" style="max-height:80px">' : '') + '</p>';
            h += '<p>On hand: ' + ((it.stock || []).map(function (x) { return esc(x.location_name) + ' ' + x.qty; }).join(', ') || 'none') + '</p>';
        } else {
            h += '<p>Not in inventory.</p>';
            if ((s.candidates || []).length) {
                h += '<p>Is it one of these? <select class="sc-cand"><option value="">-- new item --</option>' +
                     s.candidates.map(function (c2) { return '<option value="' + c2.item_id + '">' + esc(c2.name) + ' (' + esc(c2.sku) + ')</option>'; }).join('') + '</select></p>';
            }
            var p = s.proposed_sku || {};
            h += '<p>New item: <input class="sc-name" placeholder="name" value="' + esc(p.name) + '"> <input class="sc-sku" size="9" placeholder="SKU" value="' + esc(p.sku) + '"> <input class="sc-bc" size="13" placeholder="barcode" value="' + esc(p.barcode) + '"></p>';
        }
        h += '<p>What is this? <select class="sc-act">' + (s.actions || []).map(function (a) {
                 return '<option value="' + a + '">' + ({ receive: 'new stock (receive)', count: 'a count', use: 'a use-up', move: 'a move' }[a] || a) + '</option>'; }).join('') + '</select> ' +
             'qty <input class="sc-qty" size="4" value="1"> at ' + locSel('sc-loc') +
             ' <span class="sc-to" style="display:none">to ' + locSel('sc-toloc') + '</span>' +
             ' <span class="sc-cost">unit cost <input class="sc-ucost" size="6"></span> <button type="button" class="sc-go">Save</button></p>';
        k.body.innerHTML = h;
        var q = function (c3) { return k.body.querySelector(c3); };
        q('.sc-act').onchange = function () {
            q('.sc-to').style.display = this.value === 'move' ? '' : 'none';
            q('.sc-cost').style.display = this.value === 'receive' ? '' : 'none';
        };
        q('.sc-go').onclick = function () {
            var body = { action: q('.sc-act').value, qty: num(q('.sc-qty').value), location_id: +q('.sc-loc').value };
            if (body.action === 'move') body.to_location_id = +q('.sc-toloc').value;
            if (body.action === 'receive' && q('.sc-ucost').value) body.unit_cost = num(q('.sc-ucost').value);
            if (it) body.item_id = it.item_id;
            else if (q('.sc-cand') && q('.sc-cand').value) body.item_id = +q('.sc-cand').value;
            else body.create = { name: q('.sc-name').value, sku: q('.sc-sku').value, barcode: q('.sc-bc').value };
            if (!window.confirm('Save ' + body.action + ' of ' + body.qty + (body.create ? ' and create the item' : '') + '?')) return;
            api('/api/app/photo/scan/apply', body).then(function (r) {
                if (!r.success) { k.say(r.error || 'Save failed', 1); return; }
                k.say('Saved ' + r.action + (r.created ? ' (new item #' + r.item_id + ')' : '') + '. On hand: ' +
                      ((r.item.stock || []).map(function (x) { return x.location_name + ' ' + x.qty; }).join(', ') || 'none'));
            }).catch(function (e) { k.say('Network error: ' + e, 1); });
        };
        return k;
    }

    function scan(host, barcode, description) {
        return api('/api/app/photo/scan', { barcode: barcode || '', description: description || '' }).then(function (r) {
            if (!r.success) { card(host, 'Scan').say(r.error || 'Scan failed', 1); return; }
            scanCard(host, r);
        });
    }

    // ---------------------------------------------------------------- admin list
    function mountReadsList(host) {
        var k = card(host, 'Kept photo reads');
        function load() {
            api('/api/app/photo/reads').then(function (r) {
                if (!r.success) { k.say(r.error || 'Not allowed', 1); return; }
                k.say(r.reads.length + ' read(s).');
                k.body.innerHTML = '<table border="1" cellpadding="3" style="border-collapse:collapse"><tr><th>Date</th><th>Site</th><th>User</th><th>Mode</th><th>Status</th><th>Photo</th><th></th></tr>' +
                    r.reads.map(function (x) {
                        return '<tr data-id="' + x.read_id + '" data-site="' + esc(x.sitename) + '"><td>' + esc(x.created_at) + '</td><td>' + esc(x.sitename) + '</td><td>' + esc(x.username) +
                            '</td><td>' + esc(x.mode) + '</td><td>' + esc(x.status) + '</td><td>' + (x.has_photo ? 'kept' : '-') + '</td><td>' +
                            (x.has_photo ? '<button class="rl-rerun">Re-run</button> <button class="rl-del">Delete photo</button>' : '') + '</td></tr>';
                    }).join('') + '</table>';
                k.body.querySelectorAll('tr[data-id]').forEach(function (tr) {
                    var b = { read_id: tr.dataset.id, sitename: tr.dataset.site };
                    var rr = tr.querySelector('.rl-rerun'), dl = tr.querySelector('.rl-del');
                    if (rr) rr.onclick = function () { api('/api/app/photo/rerun', b).then(function (r2) { k.say(r2.success ? 'Re-reading ' + b.read_id : r2.error, !r2.success); load(); }); };
                    if (dl) dl.onclick = function () { if (window.confirm('Delete this photo?')) api('/api/app/photo/delete', b).then(function () { load(); }); };
                });
            });
        }
        load();
    }

    function handleServerResult(action, opts) {
        if (!action) return;
        var host = hostEl(opts);
        if (action.kind === 'read' && action.read_id) mountRead(host, action.read_id, { title: (action.mode === 'items' ? 'Items' : 'Invoice') + ' photo', mode: action.mode || 'invoice' });
        else if (action.kind === 'scan' && action.scan) scanCard(host, action.scan);
    }

    window.ComservChat.featurePhoto = {
        handleServerResult: handleServerResult,
        mountRead: mountRead,
        upload: upload,
        scan: scan,
        scanCard: scanCard,
        mountReadsList: mountReadsList
    };
})();
