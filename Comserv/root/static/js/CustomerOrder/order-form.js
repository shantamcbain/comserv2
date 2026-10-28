/* CustomerOrder/new — line items. Items come from form[data-items] JSON. */
(function () {
    'use strict';

    var lineIndex = 0;
    var items = [];

    function parseJsonAttr(el, name) {
        if (!el) return [];
        var raw = el.getAttribute(name) || '[]';
        try {
            var v = JSON.parse(raw);
            return Array.isArray(v) ? v : [];
        } catch (err) {
            return [];
        }
    }

    function esc(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    function itemById(id) {
        var sid = String(id || '');
        for (var i = 0; i < items.length; i++) {
            if (String(items[i].id) === sid) return items[i];
        }
        return null;
    }

    function buildItemSelect(idx, selectedId) {
        var sel = document.createElement('select');
        sel.name = 'item_id_' + idx;
        sel.id = 'item_sel_' + idx;
        sel.setAttribute('data-role', 'item-select');
        sel.style.maxWidth = '280px';
        var blank = document.createElement('option');
        blank.value = '';
        blank.textContent = '— select item —';
        sel.appendChild(blank);
        for (var i = 0; i < items.length; i++) {
            var it = items[i];
            var opt = document.createElement('option');
            opt.value = it.id;
            opt.textContent = (it.name || '') + ' [' + (it.sku || '') + ']';
            opt.setAttribute('data-price', it.price || '0.00');
            opt.setAttribute('data-desc', it.description || '');
            if (selectedId && String(it.id) === String(selectedId)) opt.selected = true;
            sel.appendChild(opt);
        }
        return sel;
    }

    function updateLine(idx) {
        var qtyEl = document.getElementById('qty_' + idx);
        var sel = document.getElementById('item_sel_' + idx);
        var qty = qtyEl ? (parseFloat(qtyEl.value) || 0) : 0;
        var opt = sel && sel.options[sel.selectedIndex];
        var price = opt ? (parseFloat(opt.getAttribute('data-price')) || 0) : 0;
        var priceEl = document.getElementById('unit_price_' + idx);
        var ltEl = document.getElementById('lt_' + idx);
        if (priceEl) priceEl.textContent = price.toFixed(2);
        if (ltEl) ltEl.textContent = (qty * price).toFixed(2);
        recalcTotal();
    }

    function recalcTotal() {
        var total = 0;
        var nodes = document.querySelectorAll('[id^="lt_"]');
        for (var i = 0; i < nodes.length; i++) {
            total += parseFloat(nodes[i].textContent) || 0;
        }
        var el = document.getElementById('order-total');
        if (el) el.textContent = total.toFixed(2);
    }

    function itemChanged(idx) {
        var sel = document.getElementById('item_sel_' + idx);
        var opt = sel && sel.options[sel.selectedIndex];
        var descEl = document.getElementById('description_' + idx);
        var desc = opt ? (opt.getAttribute('data-desc') || '') : '';
        if (descEl && !descEl.value) descEl.value = desc;
        updateLine(idx);
    }

    function addLine(prefill) {
        prefill = prefill || {};
        var idx = lineIndex++;
        var tbody = document.getElementById('lines-body');
        if (!tbody) return idx;

        var tr = document.createElement('tr');
        tr.id = 'row_' + idx;

        var tdNum = document.createElement('td');
        tdNum.textContent = String(idx + 1);

        var tdItem = document.createElement('td');
        var sel = buildItemSelect(idx, prefill.item_id);
        tdItem.appendChild(sel);

        var tdDesc = document.createElement('td');
        var desc = document.createElement('input');
        desc.type = 'text';
        desc.name = 'description_' + idx;
        desc.id = 'description_' + idx;
        desc.style.width = '160px';
        desc.value = prefill.description || '';
        tdDesc.appendChild(desc);

        var tdQty = document.createElement('td');
        var qty = document.createElement('input');
        qty.type = 'number';
        qty.name = 'quantity_' + idx;
        qty.id = 'qty_' + idx;
        qty.value = prefill.quantity || 1;
        qty.min = '1';
        qty.style.width = '55px';
        qty.addEventListener('input', function () { updateLine(idx); });
        tdQty.appendChild(qty);

        var tdPrice = document.createElement('td');
        tdPrice.innerHTML = '$<span id="unit_price_' + idx + '">0.00</span>';

        var tdLt = document.createElement('td');
        tdLt.innerHTML = '$<span id="lt_' + idx + '">0.00</span>';

        var tdNotes = document.createElement('td');
        var notes = document.createElement('input');
        notes.type = 'text';
        notes.name = 'notes_line_' + idx;
        notes.style.width = '120px';
        notes.value = prefill.notes || '';
        tdNotes.appendChild(notes);

        var tdRm = document.createElement('td');
        var rm = document.createElement('button');
        rm.type = 'button';
        rm.setAttribute('data-action', 'remove-line');
        rm.setAttribute('data-idx', String(idx));
        rm.textContent = '✕';
        tdRm.appendChild(rm);

        tr.appendChild(tdNum);
        tr.appendChild(tdItem);
        tr.appendChild(tdDesc);
        tr.appendChild(tdQty);
        tr.appendChild(tdPrice);
        tr.appendChild(tdLt);
        tr.appendChild(tdNotes);
        tr.appendChild(tdRm);
        tbody.appendChild(tr);

        sel.addEventListener('change', function () { itemChanged(idx); });
        if (prefill.item_id) itemChanged(idx);
        else updateLine(idx);
        return idx;
    }

    function filterSelects(q) {
        q = String(q || '').toLowerCase().trim();
        var selects = document.querySelectorAll('select[data-role="item-select"]');
        for (var s = 0; s < selects.length; s++) {
            var opts = selects[s].options;
            for (var i = 0; i < opts.length; i++) {
                if (!opts[i].value) {
                    opts[i].hidden = false;
                    continue;
                }
                var text = (opts[i].textContent || '').toLowerCase();
                opts[i].hidden = q ? (text.indexOf(q) === -1) : false;
            }
        }
    }

    function init() {
        var form = document.getElementById('order-form');
        if (!form) return;
        items = parseJsonAttr(form, 'data-items');
        var initial = parseJsonAttr(form, 'data-initial-lines');

        form.addEventListener('click', function (e) {
            var btn = e.target.closest('[data-action]');
            if (!btn || !form.contains(btn)) return;
            var action = btn.getAttribute('data-action');
            if (action === 'add-line') {
                e.preventDefault();
                addLine();
            } else if (action === 'remove-line') {
                e.preventDefault();
                var row = document.getElementById('row_' + btn.getAttribute('data-idx'));
                if (row) row.remove();
                recalcTotal();
            }
        });

        var filter = document.getElementById('item-filter');
        if (filter) {
            filter.addEventListener('input', function () {
                filterSelects(filter.value);
            });
        }

        if (initial.length) {
            for (var i = 0; i < initial.length; i++) addLine(initial[i]);
        } else {
            addLine();
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
