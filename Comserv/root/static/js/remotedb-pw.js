// remotedb-pw.js — generate / reveal DB password fields on the change_password form.
// Loaded only on /remotedb/* (see root/js_load.tt). No framework, no globals pollution.
(function () {
    'use strict';

    function ready(fn) {
        if (document.readyState !== 'loading') { fn(); }
        else { document.addEventListener('DOMContentLoaded', fn); }
    }

    function generatePassword(len) {
        len = len || 20;
        // Avoid ambiguous chars (no 0O1lI|`'") and keep it shell/db-safe.
        var alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*-_=+';
        var out = '';
        var cryptoObj = window.crypto || window.msCrypto;
        if (cryptoObj && cryptoObj.getRandomValues) {
            var buf = new Uint32Array(len);
            cryptoObj.getRandomValues(buf);
            for (var i = 0; i < len; i++) {
                out += alphabet[buf[i] % alphabet.length];
            }
        } else {
            for (var j = 0; j < len; j++) {
                out += alphabet[Math.floor(Math.random() * alphabet.length)];
            }
        }
        return out;
    }

    function setVal(el, val) {
        if (!el) return;
        el.value = val;
        // Fire input so any validation listeners see the change.
        try {
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        } catch (e) { /* noop */ }
    }

    function build() {
        var np = document.getElementById('new_password');
        var cf = document.getElementById('new_password_confirm');
        if (!np || !cf) return;

        // --- Generate button + length ---
        var row = np.closest ? np.closest('.form-row') : null;
        if (!row) return;
        var field = np.closest ? np.closest('.form-field') : null;
        if (!field) return;

        var genWrap = document.createElement('div');
        genWrap.style.marginTop = '6px';
        genWrap.style.display = 'flex';
        genWrap.style.gap = '6px';
        genWrap.style.alignItems = 'center';
        genWrap.style.flexWrap = 'wrap';

        var genBtn = document.createElement('button');
        genBtn.type = 'button';
        genBtn.className = 'btn btn-secondary btn-sm';
        genBtn.textContent = 'Generate new password';
        genBtn.addEventListener('click', function () {
            var len = parseInt(document.getElementById('gen_len').value, 10) || 20;
            var pw = generatePassword(len);
            setVal(np, pw);
            setVal(cf, pw);
            // Show so the user can read/copy it immediately.
            setType('text');
            var note = document.getElementById('gen_note');
            if (note) { note.textContent = 'Generated ' + pw.length + ' chars — copy it now, it is shown in plain text until you reload.'; }
        });

        var lenInput = document.createElement('input');
        lenInput.type = 'number';
        lenInput.id = 'gen_len';
        lenInput.min = '12';
        lenInput.max = '64';
        lenInput.value = '20';
        lenInput.style.width = '64px';
        lenInput.style.marginLeft = '8px';

        var lenLabel = document.createElement('label');
        lenLabel.style.fontSize = '0.85em';
        lenLabel.style.marginLeft = '4px';
        lenLabel.appendChild(document.createTextNode('length'));
        lenLabel.appendChild(lenInput);

        var note = document.createElement('span');
        note.id = 'gen_note';
        note.style.fontSize = '0.8em';
        note.style.marginLeft = '10px';
        note.style.color = 'var(--warning-color, #b8860b)';

        genWrap.appendChild(genBtn);
        genWrap.appendChild(lenLabel);
        genWrap.appendChild(note);
        field.appendChild(genWrap);

        // --- Reveal / hide toggle for all three password inputs ---
        var inputs = [
            document.getElementById('current_password'),
            np, cf
        ];
        var toggleWrap = document.createElement('div');
        toggleWrap.style.marginTop = '10px';
        var toggle = document.createElement('label');
        toggle.style.fontSize = '0.85em';
        toggle.style.cursor = 'pointer';
        var cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.id = 'pw_reveal';
        cb.addEventListener('change', function () {
            setType(this.checked ? 'text' : 'password');
        });
        toggle.appendChild(cb);
        toggle.appendChild(document.createTextNode(' Show passwords (read them before submitting)'));
        toggleWrap.appendChild(toggle);
        // Place the reveal under the confirm field's row.
        var cfField = cf.closest('.form-field');
        if (cfField) { cfField.appendChild(toggleWrap); }
        else { field.appendChild(toggleWrap); }

        function setType(type) {
            inputs.forEach(function (el) { if (el) { el.type = type; } });
        }
    }

    ready(build);
})();
