// ai-chat/feature-invoice.js — supplier/kind picker for Chat-with-AI invoice
// drafts. The server returns invoice_action.candidates; this draws the buttons
// the chat bubble used to omit, then posts /ai2/action create_invoice.
(function () {
    'use strict';
    window.ComservChat = window.ComservChat || {};

    function escapeHtml(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    function postAction(params) {
        return fetch('/ai2/action', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'create_invoice', params: params || {} })
        }).then(function (r) { return r.json(); });
    }

    function hostEl(opts) {
        if (opts && opts.host) return opts.host;
        return document.getElementById('chat-messages') || document.body;
    }

    function card(host, title) {
        var existing = host.querySelector && host.querySelector('#ai-invoice-card');
        if (existing && existing.parentNode) existing.parentNode.removeChild(existing);
        var wrap = document.createElement('div');
        wrap.id = 'ai-invoice-card';
        wrap.className = 'msg-wrapper msg-wrapper-ai';
        var box = document.createElement('div');
        box.className = 'message system-message';
        box.setAttribute('role', 'dialog');
        box.style.maxWidth = '520px';
        var h = document.createElement('div');
        h.style.fontWeight = 'bold';
        h.style.marginBottom = '8px';
        h.textContent = title || 'Invoice';
        box.appendChild(h);
        wrap.appendChild(box);
        host.appendChild(wrap);
        if (host.scrollTop !== undefined) host.scrollTop = host.scrollHeight;
        return box;
    }

    function btn(label, kind) {
        var b = document.createElement('button');
        b.type = 'button';
        b.className = kind === 'primary' ? 'btn btn-primary' : 'btn';
        b.textContent = label;
        b.style.marginRight = '6px';
        b.style.marginTop = '6px';
        return b;
    }

    function showResult(host, data) {
        var box = card(host, data.appended ? 'Items added' : (data.success ? 'Draft invoice' : 'Invoice'));
        var p = document.createElement('p');
        p.className = 'doc-body';
        if (data.success && data.invoice_url) {
            p.innerHTML = escapeHtml(data.message || 'Draft saved') +
                ' <a class="doc-link" href="' + escapeHtml(data.invoice_url) +
                '" target="_blank" rel="noopener">Open invoice #' +
                escapeHtml(String(data.invoice_id || '')) + '</a>';
        } else {
            p.textContent = data.error || data.message || 'Could not create the invoice';
        }
        box.appendChild(p);
    }

    function createInvoice(params, host) {
        return postAction(params).then(function (data) {
            if (!data) throw new Error('empty response');
            handleServerResult(data, { host: host });
            return data;
        }).catch(function (err) {
            showResult(host, { success: false, error: err.message });
        });
    }

    function askPick(host, data, draft) {
        var box = card(host, 'Which supplier?');
        var p = document.createElement('p');
        p.style.whiteSpace = 'pre-wrap';
        p.textContent = data.message || ('Several suppliers on ' + (data.sitename || 'this site') + ' could fit.');
        box.appendChild(p);
        var cands = data.candidates || [];
        if (!cands.length) {
            var none = document.createElement('p');
            none.textContent = 'No supplier names were returned. Say the supplier name on its own line: supplier: Caroline';
            box.appendChild(none);
        }
        cands.forEach(function (cand) {
            var label = (cand.name || ('#' + cand.id)) + (cand.id ? ' (#' + cand.id + ')' : '');
            var b = btn(label, 'primary');
            b.addEventListener('click', function () {
                var params = Object.assign({}, draft || {}, { supplier_id: cand.id });
                createInvoice(params, host);
            });
            box.appendChild(b);
        });
        var cancel = btn('Cancel');
        cancel.addEventListener('click', function () {
            if (box.parentNode && box.parentNode.parentNode) box.parentNode.parentNode.removeChild(box.parentNode);
        });
        box.appendChild(cancel);
    }

    function askKind(host, data, draft) {
        var box = card(host, 'What kind of record?');
        var p = document.createElement('p');
        p.textContent = data.message || 'Which should I record this as?';
        box.appendChild(p);
        (data.options || []).forEach(function (opt) {
            var b = btn(opt.label || opt.id, 'primary');
            b.addEventListener('click', function () {
                var params = Object.assign({}, draft || {}, { record_kind: opt.id });
                createInvoice(params, host);
            });
            box.appendChild(b);
        });
    }

    function askItem(host, data, draft) {
        var box = card(host, data.supplier_mismatch ? 'Same product?' : (data.need_pick_item ? 'Which item?' : 'Add inventory item?'));
        var p = document.createElement('p');
        p.style.whiteSpace = 'pre-wrap';
        p.textContent = data.message || 'No matching inventory item.';
        box.appendChild(p);
        var price = document.createElement('input');
        price.type = 'text';
        price.className = 'form-control';
        price.value = (draft && draft.line_unit_cost) || '';
        price.style.width = '8em';
        price.style.margin = '6px 0';
        var priceLabel = document.createElement('label');
        priceLabel.textContent = 'Unit cost on this invoice (catalog price changes only when you Post) ';
        priceLabel.appendChild(price);
        box.appendChild(priceLabel);
        function withPrice(extra) {
            var params = Object.assign({}, draft || {}, extra || {});
            if (price.value && /^\d+(\.\d{1,2})?$/.test(price.value)) {
                params.line_unit_cost = price.value;
            }
            return params;
        }
        (data.candidates || []).forEach(function (cand) {
            var who = cand.supplier_name ? ' — ' + cand.supplier_name : '';
            var label = 'Same product: ' + (cand.name || ('#' + cand.id)) + who;
            var b = btn(label, 'primary');
            b.addEventListener('click', function () {
                createInvoice(withPrice({ item_id: cand.id }), host);
            });
            box.appendChild(b);
        });
        var add = btn('New item for this supplier', 'primary');
        add.addEventListener('click', function () {
            createInvoice(withPrice({
                create_item: 1,
                item_id: '',
                item_name: data.item_name || (draft && draft.line_item) || ''
            }), host);
        });
        box.appendChild(add);
        var skip = btn('Save invoice without an inventory item');
        skip.addEventListener('click', function () {
            createInvoice(withPrice({ skip_item: 1, item_id: '' }), host);
        });
        box.appendChild(skip);
    }

    function handleServerResult(data, opts) {
        opts = opts || {};
        var host = hostEl(opts);
        if (!data) return;
        if (data.need_pick) {
            askPick(host, data, data.draft || {});
            return;
        }
        if (data.need_item || data.need_pick_item) {
            askItem(host, data, data.draft || {});
            return;
        }
        if (data.need_kind) {
            askKind(host, data, data.draft || {});
            return;
        }
        if (data.success || data.error) {
            showResult(host, data);
        }
    }

    window.ComservChat.featureInvoice = {
        handleServerResult: handleServerResult
    };
})();
