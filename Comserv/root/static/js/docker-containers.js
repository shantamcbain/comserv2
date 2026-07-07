/**
 * static/js/docker-containers.js
 * Docker Servers page (/admin/docker-containers)
 * Modular JS — loaded via js_load.tt. No inline scripts.
 *
 * Cards-based container & volume view with per-card action buttons.
 * Uses data-action delegation, safe fetch, idempotent Docker calls.
 */
(function() {
    'use strict';

    var currentTarget = 'workstation';
    var containersCache = [];
    var volumesCache = [];
    var outputBox = document.getElementById('output-box');
    var containersEl = document.getElementById('containers-list');
    var volumesEl = document.getElementById('volumes-list');
    var targetSelect = document.getElementById('docker-target-select');
    var showAllCheckbox = document.getElementById('show-all-containers');

    // ──────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────
    function esc(s) {
        if (!s) return '';
        return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
    }

    function formatDate(isoStr) {
        if (!isoStr) return '';
        // Docker dates: "2026-07-06T23:18:14.59875699Z" or similar
        var d = new Date(isoStr);
        if (isNaN(d.getTime())) return isoStr.substring(0, 10);
        return d.toLocaleDateString() + ' ' + d.toLocaleTimeString();
    }

    function log(msg, cls) {
        if (!outputBox) return;
        var el = cls
            ? (function() { var s = document.createElement('span'); s.className = cls; s.textContent = msg + '\n'; return s; })()
            : document.createTextNode((msg || '') + '\n');
        outputBox.appendChild(el);
        outputBox.scrollTop = outputBox.scrollHeight;
    }

    function setStatus(state, text) {
        var dot = document.getElementById('docker-status-dot');
        var txt = document.getElementById('docker-status-text');
        if (dot) dot.style.background = state === 'ok' ? '#3fb950' : state === 'err' ? '#f85149' : '#8b949e';
        if (txt) txt.textContent = text;
    }

    function safeFetch(url, opts) {
        var o = Object.assign({ credentials: 'same-origin', redirect: 'manual' }, opts || {});
        return fetch(url, o).then(function(r) {
            if (r.type === 'opaqueredirect') return Promise.reject(new Error('session-expired'));
            if (!r.ok) return Promise.reject(new Error('HTTP ' + r.status));
            return r;
        });
    }

    function apiPost(url, body) {
        return safeFetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: body || ''
        }).then(function(r){ return r.json(); });
    }

    // ──────────────────────────────────────────────────────────
    // Load containers + volumes from backend
    // ──────────────────────────────────────────────────────────
    function loadAll() {
        log('Loading ' + currentTarget + '...', 'info');
        setStatus('check', 'Loading...');

        apiPost('/admin/docker/list', 'host=' + encodeURIComponent(currentTarget))
            .then(function(data) {
                if (!data.success) {
                    log('Error: ' + (data.error || 'Unknown error') + ' — Docker may not be available on this host.', 'err');
                    setStatus('err', 'Failed');
                    containersCache = [];
                    volumesCache = [];
                    renderContainers();
                    renderVolumes();
                    return;
                }
                containersCache = data.containers || [];
                // Collect unique volumes from container mounts and fetch full volume list
                loadVolumes(containersCache);
                renderContainers();
                setStatus('ok', containersCache.length + ' containers');
                log('Loaded ' + containersCache.length + ' containers from ' + currentTarget + '.', 'ok');
            })
            .catch(function(e) {
                log('Connection failed: ' + e.message, 'err');
                setStatus('err', 'Error');
            });
    }

    function loadVolumes(containers) {
        // Gather volume names from container mounts, then docker volume ls
        apiPost('/admin/docker/list', 'host=' + encodeURIComponent(currentTarget) + '&type=volumes')
            .then(function(data) {
                volumesCache = data.volumes || [];
                renderVolumes();
            })
            .catch(function() {
                // Fallback: parse from container mount paths
                var names = [];
                containers.forEach(function(c) {
                    if (c.mounts) {
                        c.mounts.split(',').forEach(function(m) {
                            if (m =~ /comserv/) {
                                var parts = m.split(':');
                                if (parts[0] && names.indexOf(parts[0]) === -1) names.push(parts[0]);
                            }
                        });
                    }
                });
                volumesCache = names.map(function(n) { return { name: n, driver: 'local', status: 'present' }; });
                renderVolumes();
            });
    }

    // ──────────────────────────────────────────────────────────
    // Render containers as cards
    // ──────────────────────────────────────────────────────────
    function renderContainers() {
        if (!containersEl) return;
        if (!containersCache || containersCache.length === 0) {
            containersEl.innerHTML = '<p style="color:#666;text-align:center;padding:10px;font-size:0.85em;">No containers found.</p>';
            var cntEl = document.getElementById('container-count');
            if (cntEl) cntEl.textContent = '';
            return;
        }

        var showAll = showAllCheckbox ? showAllCheckbox.checked : false;
        var filtered = showAll ? containersCache : containersCache.filter(function(c) {
            return c.state === 'running' || c.is_backup_container;
        });

        var cntEl = document.getElementById('container-count');
        if (cntEl) cntEl.textContent = '(' + filtered.length + '/' + containersCache.length + ')';

        var isLocal = currentTarget === 'workstation' || currentTarget === 'localhost';
        var html = '';
        filtered.forEach(function(c) {
            var running = c.state === 'running';
            var unhealthy = running && (c.status || '').match(/unhealthy/i);
            var borderColor = unhealthy ? '#f0883e' : (running ? '#3fb950' : (c.is_backup_container ? '#6a0dad' : '#f85149'));
            var statusColor = unhealthy ? '#f0883e' : (running ? '#3fb950' : (c.is_backup_container ? '#6a0dad' : '#f85149'));
            var statusIcon = unhealthy ? '!' : (running ? '●' : (c.is_backup_container ? '↩' : '○'));
            var created = c.created ? new Date(c.created).toLocaleDateString() : '';
            var backupBadge = c.is_backup_container ? '<span style="display:inline-block;background:#6a0dad;color:#fff;font-size:0.65em;padding:1px 6px;border-radius:3px;margin-left:6px;font-weight:bold;letter-spacing:0.5px;">BACKUP</span>' : '';

            html += '<div style="border:1px solid ' + borderColor + ';border-radius:6px;padding:10px 12px;background:var(--bg-color,#fff);display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px;">' +
                '<div style="flex:2;min-width:200px;">' +
                '  <div style="display:flex;align-items:center;gap:6px;">' +
                '    <span style="color:' + statusColor + ';font-size:1em;">' + statusIcon + '</span>' +
                '    <strong style="font-size:0.9em;">' + esc(c.name) + '</strong>' + backupBadge +
                '    <span style="font-size:0.75em;color:#666;">' + esc(c.id) + '</span>' +
                '  </div>' +
                '  <div style="font-size:0.82em;color:#666;margin-top:2px;">' +
                '    Image: ' + esc(c.image) +
                (c.image_created ? ' <span style="font-size:0.75em;color:#888;">[' + formatDate(c.image_created) + ']</span>' : '') +
                (c.ports ? ' &middot; Ports: ' + esc(c.ports) : '') +
                '  </div>' +
                '  <div style="font-size:0.8em;color:#888;margin-top:1px;">' +
                '    ' + esc(c.status) +
                '  </div>' +
                '</div>' +
                '<div style="display:flex;gap:4px;flex-wrap:wrap;align-items:center;">' +
                '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.id) + '" data-act="logs" style="background:#17a2b8;color:#fff;padding:2px 8px;font-size:0.78em;">Logs</button>' +
                (running
                    ? '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.id) + '" data-act="stop" style="background:#dc3545;color:#fff;padding:2px 8px;font-size:0.78em;">Stop</button>' +
                      '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.id) + '" data-act="restart" style="background:#0066cc;color:#fff;padding:2px 8px;font-size:0.78em;">Restart</button>'
                    : '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.id) + '" data-act="start" style="background:#28a745;color:#fff;padding:2px 8px;font-size:0.78em;">Start</button>'
                ) +
                '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.id) + '" data-act="deploy-log" style="background:#6c757d;color:#fff;padding:2px 8px;font-size:0.78em;">Deploy Log</button>' +
                (isLocal && c.image && c.image.match(/comserv/)
                    ? '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.name) + '" data-act="rebuild" style="background:#ffc107;color:#333;padding:2px 8px;font-size:0.78em;">Rebuild</button>'
                    : '') +
                (c.is_backup_container
                    ? '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.name) + '" data-act="restore-backup" data-host="' + esc(currentTarget) + '" style="background:#6a0dad;color:#fff;padding:2px 8px;font-size:0.78em;font-weight:bold;">↩ Restore as Active</button>'
                    : '') +
                '</div>' +
            '</div>';
        });
        containersEl.innerHTML = html;
    }

    // ──────────────────────────────────────────────────────────
    // Render volumes as cards
    // ──────────────────────────────────────────────────────────
    function renderVolumes() {
        if (!volumesEl) return;
        if (!volumesCache || volumesCache.length === 0) {
            volumesEl.innerHTML = '<p style="color:#666;text-align:center;padding:10px;font-size:0.85em;">No volumes found.</p>';
            var vc = document.getElementById('volume-count');
            if (vc) vc.textContent = '';
            return;
        }
        var vc = document.getElementById('volume-count');
        if (vc) vc.textContent = '(' + volumesCache.length + ')';

        var html = '';
        volumesCache.forEach(function(v) {
            var name = v.name || v;
            var driver = v.driver || 'local';
            html += '<div style="border:1px solid var(--border-color,#dee2e6);border-radius:6px;padding:8px 12px;background:var(--bg-color,#fff);display:flex;align-items:center;justify-content:space-between;gap:8px;">' +
                '<div>' +
                '  <span style="font-size:0.85em;font-weight:bold;">' + esc(name) + '</span>' +
                '  <span style="font-size:0.75em;color:#666;margin-left:8px;">' + esc(driver) + '</span>' +
                '</div>' +
                '<div style="display:flex;gap:4px;">' +
                '  <button class="btn btn-sm" data-action="volume-act" data-vname="' + esc(name) + '" data-act="inspect" style="background:#6c757d;color:#fff;padding:2px 8px;font-size:0.78em;">Inspect</button>' +
                '</div>' +
            '</div>';
        });
        volumesEl.innerHTML = html;
    }

    // ──────────────────────────────────────────────────────────
    // Container actions
    // ──────────────────────────────────────────────────────────
    function containerAction(cid, act) {
        if (act === 'logs') {
            log('Fetching logs for ' + cid + '...', 'info');
            apiPost('/admin/docker/logs/' + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget) + '&lines=200')
                .then(function(d) {
                    if (d.success) {
                        log('=== LOGS: ' + cid + ' ===', 'info');
                        var output = d.output || d.logs || '(no output)';
                        // Split into lines and show last 200
                        var lines = output.split('\n');
                        if (lines.length > 200) {
                            log('... (showing last 200 of ' + lines.length + ' lines)', 'dim');
                            output = lines.slice(-200).join('\n');
                        }
                        log(output, null);
                        log('=== END LOGS ===', 'info');
                    } else {
                        log('Logs failed: ' + (d.error || d.message || 'unknown'), 'err');
                    }
                })
                .catch(function(e) { log('Logs error: ' + e.message, 'err'); });
        } else if (act === 'deploy-log') {
            log('Fetching deploy log for ' + cid + '...', 'info');
            // cid is the container ID - we need the container name. Look it up in the cache.
            var container = containersCache.filter(function(c) { return c.id === cid; })[0];
            var cname = container ? container.name : cid;
            apiPost('/admin/docker/deploy-logs/' + encodeURIComponent(cname) + '')
                .then(function(d) {
                    if (d.success && d.logs && d.logs.length > 0) {
                        var latest = d.logs[0]; // newest first
                        log('=== DEPLOY LOG: ' + cname + ' (' + latest.file + ') ===', 'info');
                        // Fetch the actual file content
                        return apiPost('/admin/docker/deploy-logs/' + encodeURIComponent(cname) + '?file=' + encodeURIComponent(latest.file) + '')
                            .then(function(fd) {
                                if (fd.success) {
                                    log(fd.output || '(empty)', null);
                                } else {
                                    log('Deploy log read failed: ' + (fd.error || 'unknown'), 'err');
                                }
                                log('=== END DEPLOY LOG ===', 'info');
                            });
                    } else {
                        log('No deploy logs found for ' + cname + '.', 'info');
                    }
                })
                .catch(function(e) { log('Deploy log error: ' + e.message, 'err'); });
        } else if (act === 'restart') {
            if (!confirm('Restart container ' + cid + ' on ' + currentTarget + '?')) return;
            // For local, avoid restarting the container we're running in
            if (currentTarget === 'workstation' && cid === window._ourContainerId) {
                if (!confirm('This is the container the web app is running in. Restart may cause a brief outage. Continue?')) return;
            }
            log('Restarting ' + cid + '...', 'info');
            apiPost('/admin/docker/restart/' + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget))
                .then(function(d) {
                    log(d.success ? '✅ Restarted ' + cid : '❌ Restart failed: ' + (d.message || d.stderr || 'unknown'), d.success ? 'ok' : 'err');
                    if (d.success) setTimeout(loadAll, 3000);
                })
                .catch(function(e) { log('Restart error: ' + e.message, 'err'); });
        } else if (act === 'stop') {
            if (!confirm('Stop container ' + cid + ' on ' + currentTarget + '?')) return;
            if (currentTarget === 'workstation' && cid === window._ourContainerId) {
                if (!confirm('This is the container we are running in. Stopping it will crash this page. Continue?')) return;
            }
            log('Stopping ' + cid + '...', 'info');
            apiPost('/admin/docker/stop/' + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget))
                .then(function(d) {
                    log(d.success ? '✅ Stopped ' + cid : '❌ Stop failed: ' + (d.message || d.stderr || 'unknown'), d.success ? 'ok' : 'err');
                    if (d.success) setTimeout(loadAll, 2000);
                })
                .catch(function(e) { log('Stop error: ' + e.message, 'err'); });
        } else if (act === 'start') {
            log('Starting ' + cid + '...', 'info');
            apiPost('/admin/docker/start/' + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget))
                .then(function(d) {
                    log(d.success ? '✅ Started ' + cid : '❌ Start failed: ' + (d.message || d.stderr || 'unknown'), d.success ? 'ok' : 'err');
                    if (d.success) setTimeout(loadAll, 3000);
                })
                .catch(function(e) { log('Start error: ' + e.message, 'err'); });
        } else if (act === 'rebuild') {
            if (!confirm('Rebuild container ' + cid + ' on ' + currentTarget + '? This runs docker compose build + up --force-recreate.')) return;
            log('Rebuilding ' + cid + '...', 'info');
            apiPost('/admin/docker/rebuild/' + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget))
                .then(function(d) {
                    log(d.success ? '✅ Rebuild started for ' + cid : '❌ Rebuild failed: ' + (d.message || d.stderr || 'unknown'), d.success ? 'ok' : 'err');
                    setTimeout(loadAll, 5000);
                })
                .catch(function(e) { log('Rebuild error: ' + e.message, 'err'); });
        } else if (act === 'restore-backup') {
            if (!confirm('Restore backup container "' + cid + '" as the active container on ' + currentTarget + '?\n\nThe current running container will be stopped and preserved as a backup. Continue?')) return;
            log('Restoring backup ' + cid + '...', 'info');
            apiPost('/admin/docker/restore_backup', 'host=' + encodeURIComponent(currentTarget) + '&backup_name=' + encodeURIComponent(cid))
                .then(function(d) {
                    if (d.success) {
                        log('✅ ' + d.message, 'ok');
                    } else {
                        log('❌ Restore failed: ' + (d.message || d.error || 'unknown'), 'err');
                    }
                    if (d.output) {
                        log('--- Details ---', 'info');
                        log(d.output, null);
                    }
                    setTimeout(loadAll, 3000);
                })
                .catch(function(e) { log('Restore error: ' + e.message, 'err'); });
        }
    }

    // ──────────────────────────────────────────────────────────
    // Event delegation
    // ──────────────────────────────────────────────────────────
    document.addEventListener('click', function(e) {
        var el = e.target.closest('[data-action]');
        if (!el) return;
        var action = el.getAttribute('data-action');

        if (action === 'refresh-all') {
            e.preventDefault();
            loadAll();
        } else if (action === 'container-act') {
            e.preventDefault();
            containerAction(el.getAttribute('data-cid'), el.getAttribute('data-act'));
        } else if (action === 'volume-act') {
            e.preventDefault();
            var vname = el.getAttribute('data-vname');
            log('Volume inspect for ' + vname + ' coming soon.', 'info');
        } else if (action === 'clear-output') {
            e.preventDefault();
            if (outputBox) outputBox.textContent = 'Ready.\n';
        }
    });

    // Target change
    document.addEventListener('change', function(e) {
        if (e.target && e.target.id === 'docker-target-select') {
            currentTarget = e.target.value;
            var display = document.getElementById('target-name-display');
            if (display) display.textContent = e.target.options[e.target.selectedIndex].text;
            loadAll();
        }
    });

    // Show all toggle
    document.addEventListener('change', function(e) {
        if (e.target && e.target.id === 'show-all-containers') {
            renderContainers();
        }
    });

    // Try to detect if we are inside a Docker container
    (function() {
        try {
            // Check for /.dockerenv or /proc/1/cgroup
            var xhr = new XMLHttpRequest();
            xhr.open('GET', '/admin/docker/self', false);
            xhr.send();
            if (xhr.status === 200) {
                var d = JSON.parse(xhr.responseText);
                if (d.container_id) window._ourContainerId = d.container_id;
            }
        } catch(e) {}
    })();

    // Auto-load
    document.addEventListener('DOMContentLoaded', function() {
        loadAll();
    });

})();