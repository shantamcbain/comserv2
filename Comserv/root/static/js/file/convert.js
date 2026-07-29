// File Manager audio conversion UI.
// Loaded by root/file/FileList.tt and root/file/FileView.tt.
// Declared as top-level functions so inline onclick handlers can call them.

function flToggleMove(idx) {
    var el = document.getElementById('fl-move-' + idx);
    if (el) { el.style.display = el.style.display === 'none' ? 'block' : 'none'; }
}

function flToggleConvert(idx) {
    var el = document.getElementById('fl-convert-' + idx);
    if (el) { el.style.display = el.style.display === 'none' ? 'block' : 'none'; }
}

// Submit a convert form via fetch, show inline status, then reload the list
// so the newly-converted file (a new File row) appears immediately.
function flConfirmConvert(form, idx) {
    var statusEl = document.getElementById('fl-convert-status-' + idx);
    if (statusEl) { statusEl.style.display = 'block'; statusEl.textContent = 'Converting…'; statusEl.style.color = '#555'; }
    var fd = new FormData(form);
    fetch(form.action, { method: 'POST', body: fd, credentials: 'same-origin' })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            if (data && data.success) {
                if (statusEl) { statusEl.textContent = 'Converted → ' + data.new_name + ' (file #' + data.new_id + '). Reloading…'; statusEl.style.color = 'green'; }
                setTimeout(function() { window.location.reload(); }, 900);
            } else {
                if (statusEl) { statusEl.textContent = 'Error: ' + ((data && data.error) || 'conversion failed'); statusEl.style.color = 'red'; }
            }
        })
        .catch(function(e) {
            if (statusEl) { statusEl.textContent = 'Error: ' + e; statusEl.style.color = 'red'; }
        });
    return false; // prevent native form submit
}

// FileView single-file convert form binding. This script is included at the
// bottom of the template (after the form markup), so the element exists.
(function() {
    var form = document.getElementById('fv-convert-form');
    if (!form) return;
    form.addEventListener('submit', function(e) {
        e.preventDefault();
        var statusEl = document.getElementById('fv-convert-status');
        statusEl.style.display = 'block';
        statusEl.textContent = 'Converting…';
        statusEl.style.color = '#555';
        var fd = new FormData(form);
        fetch(form.action, { method: 'POST', body: fd, credentials: 'same-origin' })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data && data.success) {
                    statusEl.textContent = 'Converted → ' + data.new_name + ' (file #' + data.new_id + '). Reloading…';
                    statusEl.style.color = 'green';
                    setTimeout(function() { window.location.reload(); }, 900);
                } else {
                    statusEl.textContent = 'Error: ' + ((data && data.error) || 'conversion failed');
                    statusEl.style.color = 'red';
                }
            })
            .catch(function(err) { statusEl.textContent = 'Error: ' + err; statusEl.style.color = 'red'; });
    });
})();
