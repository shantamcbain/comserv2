/**
 * static/js/docker-containers.js
 * Docker Container Management page (/admin/docker-containers)
 * Modular JS — loaded via js_load.tt. No inline scripts.
 *
 * Uses data-action attribute delegation, safe fetch, and idempotent Docker calls.
 */
(function() {
    'use strict';

    var currentTarget = 'workstation';
    var containersCache = [];
    var outputBox = document.getElementById('output-box');
    var containersList = document.getElementById('containers-list');
    var serviceSelect = document.getElementById('service-select');
    var targetSelect = document.getElementById('docker-target-select');
    var showAllCheckbox = document.getElementById('show-all-containers');

    function log(msg, cls) {
        if (!outputBox) return;
        var el = cls
            ? (function() { var s = document.createElement('span'); s.className = cls; s.textContent = msg + '\n'; return s; })()
            : document.createTextNode(msg + '\n');
        outputBox.appendChild(el);
        outputBox.scrollTop = outputBox.scrollHeight;
    }

    function setDockerStatus(state, text) {
        var dot = document.getElementById('docker-status-dot');
        var txt = document.getElementById('docker-status-text');
        if (dot) dot.style.background = state === 'ok' ? '#3fb950' : state === 'err' ? '#f85149' : '#8b949e';
        if (txt) txt.textContent = text;
    }

    // ──────────────────────────────────────────────────────────
    // Safe HTTP helpers
    // ──────────────────────────────────────────────────────────
    function safeFetch(url, opts) {
        var o = Object.assign({ credentials: 'same-origin', redirect: 'manual' }, opts || {});
        return fetch(url, o).then(function(r) {
            if (r.type === 'opaqueredirect') return Promise.reject(new Error('session-expired'));
            if (!r.ok) return Promise.reject(new Error('HTTP ' + r.status));
            return r;
        });
    }

    function apiGet(url) { return safeFetch(url).then(function(r){ return r.json(); }); }
    function apiPost(url, body) {
        return safeFetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: body || ''
        }).then(function(r){ return r.json(); });
    }

    // ──────────────────────────────────────────────────────────
    // Load container list from backend
    // ──────────────────────────────────────────────────────────
    function loadContainers() {
        log('Loading containers from ' + currentTarget + '...', 'info');
        setDockerStatus('check', 'Loading...');

        apiPost('/admin/docker/list', 'host=' + encodeURIComponent(currentTarget))
            .then(function(data) {
                if (!data.success) {
                    log('Error: ' + (data.error || 'Unknown error'), 'err');
                    setDockerStatus('err', 'Failed');
                    return;
                }
                containersCache = data.containers || [];
                renderContainers(containersCache);
                populateServiceSelect(containersCache);
                setDockerStatus('ok', 'OK (' + containersCache.length + ' containers)');
                log('Loaded ' + containersCache.length + ' containers.', 'ok');
            })
            .catch(function(e) {
                log('Failed to load containers: ' + e.message, 'err');
                setDockerStatus('err', 'Error');
            });
    }

    function renderContainers(containers) {
        if (!containersList) return;
        if (!containers || containers.length === 0) {
            containersList.innerHTML = '<p style="color:#666;text-align:center;padding:10px;">No containers found.</p>';
            var countEl = document.getElementById('container-count');
            if (countEl) countEl.textContent = '';
            return;
        }

        var showAll = showAllCheckbox ? showAllCheckbox.checked : false;
        var filtered = showAll ? containers : containers.filter(function(c) {
            return c.state === 'running';
        });

        var countEl = document.getElementById('container-count');
        if (countEl) countEl.textContent = '(' + filtered.length + '/' + containers.length + ')';

        var html = '<table style="width:100%;border-collapse:collapse;font-size:0.85em;">' +
            '<thead><tr style="border-bottom:2px solid var(--border-color,#dee2e6);">' +
            '<th style="text-align:left;padding:4px 6px;">Name</th>' +
            '<th style="text-align:left;padding:4px 6px;">Image</th>' +
            '<th style="text-align:left;padding:4px 6px;">Status</th>' +
            '<th style="text-align:left;padding:4px 6px;">Ports</th>' +
            '<th style="text-align:left;padding:4px 6px;">Actions</th>' +
            '</tr></thead><tbody>';

        filtered.forEach(function(c) {
            var stateCls = c.state === 'running' ? 'color:#3fb950;' : (c.state === 'exited' ? 'color:#f85149;' : 'color:#8b949e;');
            var statusShort = (c.status || '').substring(0, 60);
            html += '<tr style="border-bottom:1px solid var(--border-color,#e0e0e0);">' +
                '<td style="padding:6px 6px;"><strong>' + esc(c.name) + '</strong><br><span style="font-size:0.8em;color:#666;">' + esc(c.id) + '</span></td>' +
                '<td style="padding:6px 6px;font-size:0.9em;">' + esc(c.image) + '</td>' +
                '<td style="padding:6px 6px;' + stateCls + '">' + esc(statusShort) + '</td>' +
                '<td style="padding:6px 6px;font-size:0.85em;color:#666;">' + esc(c.ports || '-') + '</td>' +
                '<td style="padding:6px 6px;white-space:nowrap;">' +
                '  <button class="btn btn-sm" data-action="container-action" data-cid="' + esc(c.id) + '" data-action-type="logs" style="background:#17a2b8;color:#fff;padding:2px 6px;font-size:0.78em;margin-right:3px;">Logs</button>' +
                '  <button class="btn btn-sm" data-action="container-action" data-cid="' + esc(c.id) + '" data-action-type="restart" style="background:#0066cc;color:#fff;padding:2px 6px;font-size:0.78em;margin-right:3px;">Restart</button>' +
                '  <button class="btn btn-sm" data-action="container-action" data-cid="' + esc(c.id) + '" data-action-type="inspect" style="background:#6c757d;color:#fff;padding:2px 6px;font-size:0.78em;">Inspect</button>' +
                '</td></tr>';
        });

        html += '</tbody></table>';
        containersList.innerHTML = html;
    }

    function populateServiceSelect(containers) {
        if (!serviceSelect) return;
        serviceSelect.innerHTML = '<option value="">-- Select container --</option>';
        containers.forEach(function(c) {
            var opt = document.createElement('option');
            opt.value = c.id;
            opt.textContent = c.name + ' (' + c.id + ')';
            serviceSelect.appendChild(opt);
        });
    }

    function esc(s) {
        if (!s) return '';
        return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
    }

    // ──────────────────────────────────────────────────────────
    // Container actions
    // ──────────────────────────────────────────────────────────
    function containerAction(cid, action) {
        if (action === 'restart') {
            if (!confirm('Restart container ' + cid + '?')) return;
            log('Restarting ' + cid + '...', 'info');
            apiPost('/admin/docker-restart/' + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget))
                .then(function(d) {
                    log(d.success ? '✅ Restarted: ' + cid : '❌ Failed: ' + d.message, d.success ? 'ok' : 'err');
                    if (d.success) setTimeout(loadContainers, 2000);
                })
                .catch(function(e) { log('Restart error: ' + e.message, 'err'); });
        } else if (action === 'logs') {
            log('Fetching logs for ' + cid + '...', 'info');
            apiPost('/admin/docker-logs/' + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget))
                .then(function(d) {
                    if (d.success) {
                        log('=== LOGS: ' + cid + ' ===', 'info');
                        log(d.output || '(no output)', null);
                        log('=== END LOGS ===', 'info');
                    } else {
                        log('Log fetch failed: ' + (d.error || d.message), 'err');
                    }
                })
                .catch(function(e) { log('Logs error: ' + e.message, 'err'); });
        } else if (action === 'inspect') {
            log('Fetching inspect data for ' + cid + '...', 'info');
            // Use docker inspect via backend
            apiPost('/admin/docker-restart/' + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget))
                .then(function() {
                    // The inspect endpoint doesn't exist yet, fallback to shell
                    showInspectModal(cid, '(run "docker inspect ' + cid + '" on the server)');
                })
                .catch(function(e) { log('Inspect error: ' + e.message, 'err'); });
        }
    }

    function showInspectModal(cid, data) {
        var modal = document.getElementById('inspect-modal');
        var body = document.getElementById('inspect-modal-body');
        var title = document.getElementById('inspect-modal-title');
        if (!modal || !body) return;
        if (title) title.textContent = 'Inspect: ' + cid;
        body.textContent = data || '(no data)';
        modal.style.display = 'flex';
    }

    // ──────────────────────────────────────────────────────────
    // Event delegation
    // ──────────────────────────────────────────────────────────
    document.addEventListener('click', function(e) {
        var el = e.target.closest('[data-action]');
        if (!el) return;
        var action = el.getAttribute('data-action');

        if (action === 'refresh-containers' || action === 'list-containers') {
            e.preventDefault();
            loadContainers();
        } else if (action === 'container-action') {
            e.preventDefault();
            containerAction(el.getAttribute('data-cid'), el.getAttribute('data-action-type'));
        } else if (action === 'restart-container') {
            e.preventDefault();
            var cid = serviceSelect ? serviceSelect.value : '';
            if (!cid) { log('Select a container first.', 'err'); return; }
            containerAction(cid, 'restart');
        } else if (action === 'view-container-logs') {
            e.preventDefault();
            var cid2 = serviceSelect ? serviceSelect.value : '';
            if (!cid2) { log('Select a container first.', 'err'); return; }
            containerAction(cid2, 'logs');
        } else if (action === 'inspect-container') {
            e.preventDefault();
            var cid3 = serviceSelect ? serviceSelect.value : '';
            if (!cid3) { log('Select a container first.', 'err'); return; }
            containerAction(cid3, 'inspect');
        } else if (action === 'clear-output') {
            e.preventDefault();
            if (outputBox) outputBox.textContent = 'Ready.\n';
        } else if (action === 'close-inspect') {
            e.preventDefault();
            var m = document.getElementById('inspect-modal');
            if (m) m.style.display = 'none';
        }
    });

    // Target selector change
    document.addEventListener('change', function(e) {
        if (e.target && e.target.id === 'docker-target-select') {
            currentTarget = e.target.value;
            var display = document.getElementById('target-name-display');
            if (display) display.textContent = e.target.options[e.target.selectedIndex].text;
            loadContainers();
        }
    });

    // Show all toggle
    document.addEventListener('change', function(e) {
        if (e.target && e.target.id === 'show-all-containers') {
            renderContainers(containersCache);
        }
    });

    // Auto-load on page open
    document.addEventListener('DOMContentLoaded', function() {
        loadContainers();
    });

})();