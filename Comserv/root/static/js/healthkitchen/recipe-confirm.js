/* Health Kitchen: after Done on a recipe-linked day-slot card, show an
 * in-place panel (no navigation) with the recipe's ingredients and
 * "Mark made" -> POST /healthkitchen/recipe_make/<id> (ajax=1, consume_recipe).
 * "Not now" just closes. Works in /todo/day and the /healthkitchen embed. */
(function () {
    'use strict';
    function el(tag, cls, text) {
        var e = document.createElement(tag);
        if (cls) e.className = cls;
        if (text != null) e.textContent = text;
        return e;
    }
    function fmt(list, withReason) {
        return (list || []).map(function (x) {
            var s = x.name || '?';
            if (!withReason && x.qty != null) s += ' ' + x.qty + (x.unit ? ' ' + x.unit : '');
            if (withReason && x.reason) s += ' (' + x.reason + ')';
            return s;
        }).join(', ');
    }
    function open(card, onClose) {
        var id = card.getAttribute('data-hk-recipe-id');
        if (!id) { if (onClose) onClose(); return; }
        var name = card.getAttribute('data-hk-recipe-name') || 'recipe';
        var old = card.querySelector('.hk-recipe-confirm');
        if (old) old.parentNode.removeChild(old);
        var panel = el('div', 'hk-recipe-confirm');
        panel.setAttribute('role', 'dialog');
        panel.style.cssText = 'position:absolute;z-index:50;left:0;right:0;top:100%;background:#fff;' +
            'border:1px solid #9c6;border-radius:6px;padding:8px;box-shadow:0 4px 12px rgba(0,0,0,.2);font-size:.85rem;';
        panel.appendChild(el('strong', null, 'Made "' + name + '"?'));
        var ul = el('ul', 'hk-recipe-confirm-list');
        ul.style.margin = '4px 0 6px 1.1em';
        card.querySelectorAll('.hk-recipe-ingredients li').forEach(function (li) {
            ul.appendChild(el('li', null, li.textContent));
        });
        panel.appendChild(ul);
        var msg = el('div', 'hk-recipe-confirm-msg');
        var make = el('button', 'btn btn-sm btn-success', 'Mark made');
        var later = el('button', 'btn btn-sm btn-outline-secondary', 'Not now');
        make.type = later.type = 'button';
        later.style.marginLeft = '6px';
        panel.appendChild(make); panel.appendChild(later); panel.appendChild(msg);
        panel.addEventListener('click', function (e) { e.stopPropagation(); }, true);
        function close() {
            if (panel.parentNode) panel.parentNode.removeChild(panel);
            if (onClose) onClose();
        }
        later.addEventListener('click', function (e) { e.preventDefault(); close(); });
        make.addEventListener('click', function (e) {
            e.preventDefault();
            make.disabled = true;
            msg.textContent = 'Deducting…';
            var body = new URLSearchParams({ ajax: '1', batches: '1' });
            fetch('/healthkitchen/recipe_make/' + encodeURIComponent(id), {
                method: 'POST', credentials: 'same-origin',
                headers: { 'Accept': 'application/json' }, body: body
            }).then(function (r) { return r.json(); }).then(function (d) {
                msg.textContent = '';
                if (d && (d.deducted || []).length) msg.appendChild(el('div', 'text-success', 'Deducted: ' + fmt(d.deducted)));
                if (d && (d.skipped || []).length) msg.appendChild(el('div', 'text-muted', 'Skipped: ' + fmt(d.skipped, true)));
                if (!d || !d.ok) {
                    // All-or-nothing: a failed make deducts nothing.
                    msg.textContent = '';
                    msg.appendChild(el('div', 'text-danger', (d && d.error) || 'Nothing deducted — could not mark made'));
                    make.disabled = false;
                    return;
                }
                if (d && d.ok && !(d.deducted || []).length && !(d.skipped || []).length) msg.textContent = 'Marked made.';
                make.style.display = 'none';
                later.textContent = 'Close';
            }).catch(function () {
                msg.textContent = 'Could not mark made';
                make.disabled = false;
            });
        });
        if (getComputedStyle(card).position === 'static') card.style.position = 'relative';
        card.style.overflow = 'visible';
        card.style.zIndex = '40';
        card.appendChild(panel);
        make.focus();
    }
    window.HkRecipeConfirm = { open: open };
})();
