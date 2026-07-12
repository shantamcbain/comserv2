/**
 * static/js/docker-containers.js
 * Docker Servers page (/admin/docker-containers)
 * Modular JS — loaded via js_load.tt. No inline scripts.
 *
 * Cards-based container & volume view with per-card action buttons.
 * Uses data-action delegation, safe fetch, idempotent Docker calls.
 *
 * CV: 20260712a — bumped for deploy-form + registry + polling changes
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
    var rebuildPollingTimer = null;
    var lastKnownLineCount = 0;
    var pollingElapsedTimer = null;
    var pollingStartTime = null;
    var deployFormVisible = false;

    // ──────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────
    function esc(s) {
        if (!s) return '';
        return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\"/g,'&quot;');
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
    // Known container/target mapping for deploy form
    // ──────────────────────────────────────────────────────────
    var KNOWN_CONTAINERS = [
        { name: 'comserv-web-prod',       label: 'Production (port 5000)' },
        { name: 'comserv2-web-staging',   label: 'Staging (port 4000)' },
        { name: 'comserv2-web-dev',       label: 'Web Dev (port 3000)' },
    ];

    // ──────────────────────────────────────────────────────────
    // Rebuild polling — improved with line-based diff, elapsed time, timeout
    // ──────────────────────────────────────────────────────────
    function startRebuildPolling(target) {
        if (rebuildPollingTimer) clearInterval(rebuildPollingTimer);
        if (pollingElapsedTimer) clearInterval(pollingElapsedTimer);
        lastKnownLineCount = 0;
        pollingStartTime = Date.now();
        setStatus('check', 'Deploying ' + target + '…');

        // Update elapsed time every second
        pollingElapsedTimer = setInterval(function() {
            if (!pollingStartTime) return;
            var sec = Math.floor((Date.now() - pollingStartTime) / 1000);
            var min = Math.floor(sec / 60);
            sec = sec % 60;
            var elapsed = min > 0 ? min + 'm ' + sec + 's' : sec + 's';
            setStatus('check', 'Deploying ' + target + ' (' + elapsed + ')');
        }, 1000);

        var maxDuration = 30 * 60 * 1000; // 30 minutes max

        rebuildPollingTimer = setInterval(function() {
            // Timeout check
            if (pollingStartTime && (Date.now() - pollingStartTime > maxDuration)) {
                clearInterval(rebuildPollingTimer);
                rebuildPollingTimer = null;
                clearInterval(pollingElapsedTimer);
                pollingElapsedTimer = null;
                setStatus('err', 'Deploy timed out (30 min)');
                log('⏰ DEPLOY TIMED OUT after 30 minutes — check server logs.', 'err');
                return;
            }

            apiPost('/admin/docker-deploy-status')
                .then(function(data) {
                    if (data.success) {
                        // Line-based diffing: only log lines we haven't seen yet
                        var newOutput = data.output || '';
                        var lines = newOutput.split('\n');
                        if (lines.length > lastKnownLineCount) {
                            var delta = lines.slice(lastKnownLineCount);
                            delta.forEach(function(line) {
                                if (line.trim()) log(line, null);
                            });
                            lastKnownLineCount = lines.length;
                        }

                        if (!data.is_running) {
                            clearInterval(rebuildPollingTimer);
                            rebuildPollingTimer = null;
                            clearInterval(pollingElapsedTimer);
                            pollingElapsedTimer = null;
                            // Determine success/failure from last output line
                            var finalLine = lines.filter(Boolean).pop() || '';
                            if (finalLine.match(/SUCCESS/)) {
                                setStatus('ok', 'Deploy done ✓');
                                log('✅ DEPLOY COMPLETE', 'ok');
                            } else if (finalLine.match(/FAIL|CRASH|ERROR|FAILED/)) {
                                setStatus('err', 'Deploy failed ✗');
                                log('❌ DEPLOY FAILED', 'err');
                            } else {
                                setStatus('ok', 'Deploy done');
                                log('Deploy finished.', 'ok');
                            }
                            // Reload container list to reflect changes
                            setTimeout(loadAll, 2000);
                        }
                    }
                })
                .catch(function(e) {
                    if (e.message !== 'session-expired') {
                        log('Deploy status poll error: ' + e.message, 'err');
                    }
                });
        }, 1500);
    }

    function stopRebuildPolling() {
        if (rebuildPollingTimer) {
            clearInterval(rebuildPollingTimer);
            rebuildPollingTimer = null;
        }
        if (pollingElapsedTimer) {
            clearInterval(pollingElapsedTimer);
            pollingElapsedTimer = null;
        }
        pollingStartTime = null;
    }

    // ──────────────────────────────────────────────────────────
    // Deploy form (standalone new-container deploy + registry auth)
    // ──────────────────────────────────────────────────────────
    function showDeployForm() {
        // If a rebuild is already running, don't show the form
        if (rebuildPollingTimer) {
            log('A deploy is already in progress. Wait for it to finish.', 'err');
            return;
        }

        deployFormVisible = true;
        var knownOpts = '';
        KNOWN_CONTAINERS.forEach(function(kc) {
            var selected = kc.name === 'comserv-web-prod' ? ' selected' : '';
            knownOpts += '<option value="' + esc(kc.name) + '"' + selected + '>' + esc(kc.label) + '</option>';
        });

        var html =
            '<div id="deploy-form-card" style="border:2px solid #28a745;border-radius:8px;padding:14px;margin-bottom:12px;background:#f0fdf4;">' +
            '  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px;">' +
            '    <strong style="font-size:0.95em;color:#166534;"><i class="fas fa-rocket"></i> Deploy New Container</strong>' +
            '    <button class="btn btn-sm" id="btn-close-deploy-form" style="background:#6c757d;color:#fff;padding:2px 10px;font-size:0.78em;">✕ Close</button>' +
            '  </div>' +

            '  <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px 14px;margin-bottom:10px;">' +

            // Row 1: Container name + Deploy mode
            '    <div>' +
            '      <label style="font-size:0.82em;font-weight:bold;display:block;margin-bottom:2px;">Container:</label>' +
            '      <select id="deploy-container-select" style="width:100%;padding:4px 6px;font-size:0.85em;border:1px solid #ccc;border-radius:4px;">' +
            knownOpts +
            '      </select>' +
            '    </div>' +

            '    <div>' +
            '      <label style="font-size:0.82em;font-weight:bold;display:block;margin-bottom:2px;">Target Host:</label>' +
            '      <select id="deploy-target-select" style="width:100%;padding:4px 6px;font-size:0.85em;border:1px solid #ccc;border-radius:4px;">' +
            '        <option value="workstation">Workstation (Local)</option>' +
            '        <option value="production1">Production 1 (192.168.1.126)</option>' +
            '        <option value="production2">Production 2 (192.168.1.127)</option>' +
            '      </select>' +
            '    </div>' +

            // Row 2: Mode + No Cache
            '    <div>' +
            '      <label style="font-size:0.82em;font-weight:bold;display:block;margin-bottom:2px;">Mode:</label>' +
            '      <select id="deploy-mode-select" style="width:100%;padding:4px 6px;font-size:0.85em;border:1px solid #ccc;border-radius:4px;">' +
            '        <option value="pull-deploy">Pull &amp; Deploy (from registry)</option>' +
            '        <option value="full">Full Rebuild (build + push + deploy)</option>' +
            '        <option value="build-push">Build &amp; Push only (no deploy)</option>' +
            '      </select>' +
            '    </div>' +

            '    <div style="display:flex;align-items:flex-end;padding-bottom:4px;">' +
            '      <label style="display:inline-flex;align-items:center;gap:5px;font-size:0.82em;cursor:pointer;">' +
            '        <input type="checkbox" id="deploy-no-cache" style="width:14px;height:14px;cursor:pointer;">' +
            '        <span style="color:#d97706;">No Cache</span>' +
            '      </label>' +
            '    </div>' +
            '  </div>' +

            // Registry auth fields (collapsible)
            '  <details style="margin-bottom:10px;font-size:0.85em;">' +
            '    <summary style="cursor:pointer;color:#0066cc;font-weight:bold;">Custom Registry Auth (optional)</summary>' +
            '    <div style="display:grid;grid-template-columns:1fr 1fr;gap:6px 10px;margin-top:6px;padding:8px;background:#e8f4fd;border-radius:4px;">' +
            '      <div>' +
            '        <label style="font-size:0.82em;display:block;margin-bottom:1px;">Registry URL:</label>' +
            '        <input type="text" id="deploy-registry-url" placeholder="ghcr.io / docker.io / …" style="width:100%;padding:3px 6px;border:1px solid #ccc;border-radius:3px;font-size:0.9em;">' +
            '      </div>' +
            '      <div>' +
            '        <label style="font-size:0.82em;display:block;margin-bottom:1px;">Image Tag (optional):</label>' +
            '        <input type="text" id="deploy-image-tag" placeholder="latest (default)" style="width:100%;padding:3px 6px;border:1px solid #ccc;border-radius:3px;font-size:0.9em;">' +
            '      </div>' +
            '      <div>' +
            '        <label style="font-size:0.82em;display:block;margin-bottom:1px;">Username:</label>' +
            '        <input type="text" id="deploy-registry-user" placeholder="(leave blank if none)" style="width:100%;padding:3px 6px;border:1px solid #ccc;border-radius:3px;font-size:0.9em;">' +
            '      </div>' +
            '      <div>' +
            '        <label style="font-size:0.82em;display:block;margin-bottom:1px;">Password / Token:</label>' +
            '        <input type="password" id="deploy-registry-pass" placeholder="(masked)" style="width:100%;padding:3px 6px;border:1px solid #ccc;border-radius:3px;font-size:0.9em;">' +
            '      </div>' +
            '    </div>' +
            '  </details>' +

            '  <div style="display:flex;gap:8px;">' +
            '    <button class="btn btn-sm" id="btn-start-deploy" style="background:#28a745;color:#fff;padding:6px 20px;font-size:0.85em;font-weight:bold;">▶ Deploy</button>' +
            '    <button class="btn btn-sm" id="btn-cancel-deploy" style="background:#dc3545;color:#fff;padding:6px 12px;font-size:0.85em;">Cancel</button>' +
            '  </div>' +
            '</div>';

        // Insert deploy form at the top of containers section
        if (containersEl) {
            containersEl.insertAdjacentHTML('afterbegin', html);
        }
    }

    function hideDeployForm() {
        var card = document.getElementById('deploy-form-card');
        if (card) card.parentNode.removeChild(card);
        deployFormVisible = false;
    }

    function submitDeployForm() {
        var cname = document.getElementById('deploy-container-select');
        var targetEl = document.getElementById('deploy-target-select');
        var modeEl = document.getElementById('deploy-mode-select');
        var noCacheEl = document.getElementById('deploy-no-cache');
        var registryUrlEl = document.getElementById('deploy-registry-url');
        var registryUserEl = document.getElementById('deploy-registry-user');
        var registryPassEl = document.getElementById('deploy-registry-pass');
        var imageTagEl = document.getElementById('deploy-image-tag');

        if (!cname || !targetEl) return;

        var containerName = cname.value;
        var target = targetEl.value;
        var mode = modeEl ? modeEl.value : 'pull-deploy';
        var noCache = noCacheEl ? noCacheEl.checked : false;
        var registryUrl = registryUrlEl ? registryUrlEl.value.trim() : '';
        var registryUser = registryUserEl ? registryUserEl.value.trim() : '';
        var registryPass = registryPassEl ? registryPassEl.value : '';
        var imageTag = imageTagEl ? imageTagEl.value.trim() : '';

        // Confirm
        var confirmMsg = 'Deploy ' + containerName + ' to ' + target + '?';
        if (mode === 'full') confirmMsg = 'Full rebuild + deploy ' + containerName + ' on ' + target + '? This builds, pushes to Docker Hub, and deploys with zero-downtime handover.';
        if (mode === 'build-push') confirmMsg = 'Build and push ' + containerName + ' to Docker Hub (no deploy)?';
        if (registryUrl) confirmMsg += '\n\nRegistry: ' + registryUrl;
        if (!confirm(confirmMsg)) return;

        // Build POST body
        var parts = [];
        if (mode !== 'full') parts.push('mode=' + encodeURIComponent(mode));
        if (noCache) parts.push('no_cache=1');
        if (registryUrl) parts.push('registry_url=' + encodeURIComponent(registryUrl));
        if (registryUser) parts.push('registry_user=' + encodeURIComponent(registryUser));
        if (registryPass) parts.push('registry_pass=' + encodeURIComponent(registryPass));
        if (imageTag) parts.push('image_tag=' + encodeURIComponent(imageTag));

        var postBody = parts.join('&');

        hideDeployForm();
        stopRebuildPolling();
        log('=== DEPLOY: ' + containerName + ' on ' + target + ' ===', 'info');
        log('Mode: ' + mode + (registryUrl ? ', Registry: ' + registryUrl : '') + (imageTag ? ', Tag: ' + imageTag : ''), 'info');

        apiPost('/admin/docker/rebuild/' + encodeURIComponent(containerName) + '?host=' + encodeURIComponent(target), postBody)
            .then(function(d) {
                if (d.success) {
                    log('Deploy process started in background. Streaming output below:', 'dim');
                    startRebuildPolling(containerName);
                } else {
                    log('❌ Deploy failed to start: ' + (d.message || d.stderr || 'unknown'), 'err');
                    setStatus('err', 'Deploy failed');
                    setTimeout(loadAll, 5000);
                }
            })
            .catch(function(e) {
                stopRebuildPolling();
                log('❌ Deploy request error: ' + e.message, 'err');
                setStatus('err', 'Network error');
                setTimeout(loadAll, 5000);
            });
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
                            if (m.indexOf('comserv') !== -1) {
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

        // If deploy form is visible, preserve it by not clearing innerHTML directly
        var deployCard = document.getElementById('deploy-form-card');
        var deployHtml = '';
        if (deployCard) {
            deployHtml = deployCard.outerHTML;
        }

        if (!containersCache || containersCache.length === 0) {
            containersEl.innerHTML = deployHtml +
                '<div style="text-align:center;padding:16px;border:1px dashed #28a745;border-radius:8px;margin-top:6px;">' +
                '<p style="color:#666;font-size:0.88em;margin:0 0 10px 0;">No containers found on <strong>' + esc(currentTarget) + '</strong>.</p>' +
                '<button class="btn btn-sm" data-action="show-deploy-form" style="background:#28a745;color:#fff;padding:6px 16px;font-size:0.88em;font-weight:bold;">' +
                '<i class="fas fa-rocket"></i> Deploy New Container</button>' +
                '</div>';
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
            var hostBadge = '<span style="font-size:0.7em;background:#e2e8f0;color:#475569;padding:1px 5px;border-radius:3px;margin-left:4px;white-space:nowrap;">' + esc(currentTarget) + '</span>';

            html += '<div style="border:1px solid ' + borderColor + ';border-radius:6px;padding:10px 12px;background:var(--bg-color,#fff);display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px;">' +
                '<div style="flex:2;min-width:200px;">' +
                '  <div style="display:flex;align-items:center;gap:6px;">' +
                '    <span style="color:' + statusColor + ';font-size:1em;">' + statusIcon + '</span>' +
                '    <strong style="font-size:0.9em;">' + esc(c.name) + '</strong>' + hostBadge + backupBadge +
                '    <span style="font-size:0.75em;color:#666;">' + esc(c.id) + '</span>' +
                '  </div>' +
                '  <div style="font-size:0.82em;color:#666;margin-top:2px;">' +
                '    Image: ' + esc(c.image) +
                (c.image_created ? ' <span style="font-size:0.75em;color:#888;">[' + formatDate(c.image_created) + ']</span>' : '') +
                (c.ports ? ' &middot; Ports: ' + esc(c.ports) : '') +
                '  </div>' +
                '  <div style="font-size:0.8em;color:#888;margin-top:1px;">' +
                '    ' + esc(c.status) +
                (c.running_for && c.running_for !== c.status ? ' &middot; Created ' + esc(c.running_for) : '') +
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
                (c.name && c.name.match(/comserv/)
                    ? '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.name) + '" data-act="rebuild" style="background:#ffc107;color:#333;padding:2px 8px;font-size:0.78em;">Rebuild</button>'
                    : '') +
                // Build & Push: only on workstation for comserv-web-prod
                (c.name && c.name.match(/^comserv-web-prod/) && isLocal
                    ? '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.name) + '" data-act="build-push" style="background:#17a2b8;color:#fff;padding:2px 8px;font-size:0.78em;">Build &amp; Push</button>'
                    : '') +
                // Push Image (no-build): just push the existing image, workstation only
                (c.name && c.name.match(/^comserv-web-prod/) && isLocal
                    ? '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.name) + '" data-act="push-only" style="background:#0056b3;color:#fff;padding:2px 8px;font-size:0.78em;">Push Image</button>'
                    : '') +
                // Pull & Deploy: only on production targets for comserv-web-prod
                (c.name && c.name.match(/^comserv-web-prod/) && !isLocal
                    ? '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.name) + '" data-act="pull-deploy" style="background:#28a745;color:#fff;padding:2px 8px;font-size:0.78em;">Pull &amp; Deploy</button>'
                    : '') +
                (c.is_backup_container
                    ? '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.name) + '" data-act="restore-backup" data-host="' + esc(currentTarget) + '" style="background:#6a0dad;color:#fff;padding:2px 8px;font-size:0.78em;font-weight:bold;">↩ Restore as Active</button>' +
                      '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.name) + '" data-act="rm" style="background:#8b0000;color:#fff;padding:2px 8px;font-size:0.78em;">Delete</button>'
                    : '') +
                (!running && !c.is_backup_container
                    ? '  <button class="btn btn-sm" data-action="container-act" data-cid="' + esc(c.name) + '" data-act="rm" style="background:#8b0000;color:#fff;padding:2px 8px;font-size:0.78em;">Delete</button>'
                    : '') +
                '</div>' +
            '</div>';
        });

        // If we had a deploy form card, preserve it
        if (deployHtml) {
            html = deployHtml + html;
        }
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
    // Container actions — shared fetch helper
    // ──────────────────────────────────────────────────────────
    function _containerActionFetch(cid, act, endpoint, confirmMsg) {
        // Shared logic: confirm (optional), POST to endpoint, log result, reload
        if (confirmMsg && !confirm(confirmMsg)) return;
        log((act.charAt(0).toUpperCase() + act.slice(1)) + 'ing ' + cid + '...', 'info');
        apiPost(endpoint)
            .then(function(d) {
                if (d.success) {
                    log('✅ ' + (d.message || act + ' ' + cid), 'ok');
                    setTimeout(loadAll, 2000);
                } else {
                    log('❌ ' + (d.message || d.stderr || (act + ' failed on ' + cid)), 'err');
                }
            })
            .catch(function(e) { log(act + ' error: ' + e.message, 'err'); });
    }

    function containerAction(cid, act) {
        var actionMap = {
            'restart': '/admin/docker/restart/',
            'stop':    '/admin/docker/stop/',
            'start':   '/admin/docker/start/',
            'rm':      '/admin/docker/delete/'
        };

        if (actionMap[act]) {
            var endpoint = actionMap[act] + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget);
            var confirmMsg = null;
            if (act === 'restart') {
                confirmMsg = 'Restart container ' + cid + ' on ' + currentTarget + '?';
                if (currentTarget === 'workstation' && cid === window._ourContainerId) {
                    confirmMsg = 'This is the container the web app is running in. Restart may cause a brief outage. Continue?';
                }
            } else if (act === 'stop') {
                confirmMsg = 'Stop container ' + cid + ' on ' + currentTarget + '?';
                if (currentTarget === 'workstation' && cid === window._ourContainerId) {
                    confirmMsg = 'This is the container we are running in. Stopping it will crash this page. Continue?';
                }
            } else if (act === 'rm') {
                confirmMsg = 'Permanently delete container "' + cid + '" on ' + currentTarget + '?\n\nThis cannot be undone. The container will be removed entirely.';
            }
            _containerActionFetch(cid, act, endpoint, confirmMsg);
            return;
        }

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
        } else if (act === 'rebuild') {
            if (!confirm('Rebuild container ' + cid + ' on ' + currentTarget + '? This runs the full deploy pipeline: volume check, build, backup, health check, and zero-downtime handover.')) return;
            // Stop any previous polling that might still be running
            stopRebuildPolling();
            log('=== REBUILD STARTED: ' + cid + ' ===', 'info');
            log('Starting rebuild on ' + currentTarget + '...', 'info');
            var noCacheCheckbox = document.getElementById('no-cache-rebuild');
            var noCache = noCacheCheckbox ? noCacheCheckbox.checked : false;
            var postBody = noCache ? 'no_cache=1' : '';
            apiPost('/admin/docker/rebuild/' + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget), postBody)
                .then(function(d) {
                    if (d.success) {
                        log('Build process started in background. Streaming output below:', 'dim');
                        // Start polling the deploy status endpoint for live output
                        startRebuildPolling(cid);
                    } else {
                        log('❌ Rebuild failed to start: ' + (d.message || d.stderr || 'unknown'), 'err');
                        setStatus('err', 'Rebuild failed');
                        setTimeout(loadAll, 5000);
                    }
                })
                .catch(function(e) {
                    stopRebuildPolling();
                    log('❌ Rebuild request error: ' + e.message, 'err');
                    setStatus('err', 'Network error');
                    setTimeout(loadAll, 5000);
                });
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
        } else if (act === 'build-push') {
            if (!confirm('Build and push ' + cid + ' to Docker Hub on ' + currentTarget + '?\n\nThis will build the image locally and push to Docker Hub.\nThe running container is NOT restarted.\n\nUse "Pull & Deploy" on the production server to deploy this image.')) return;
            stopRebuildPolling();
            log('=== BUILD & PUSH: ' + cid + ' ===', 'info');
            log('Building and pushing to Docker Hub (running container untouched)...', 'info');
            var noCacheCheckbox = document.getElementById('no-cache-rebuild');
            var noCache = noCacheCheckbox ? noCacheCheckbox.checked : false;
            var postBody = 'mode=build-push' + (noCache ? '&no_cache=1' : '');
            apiPost('/admin/docker/rebuild/' + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget), postBody)
                .then(function(d) {
                    if (d.success) {
                        log('Build & Push started in background. Streaming output below:', 'dim');
                        startRebuildPolling(cid);
                    } else {
                        log('❌ Build & Push failed to start: ' + (d.message || d.stderr || 'unknown'), 'err');
                        setStatus('err', 'Build & Push failed');
                        setTimeout(loadAll, 5000);
                    }
                })
                .catch(function(e) {
                    stopRebuildPolling();
                    log('❌ Build & Push request error: ' + e.message, 'err');
                    setStatus('err', 'Network error');
                    setTimeout(loadAll, 5000);
                });
        } else if (act === 'pull-deploy') {
            if (!confirm('Pull and deploy ' + cid + ' on ' + currentTarget + '?\n\nThis will pull the latest image from Docker Hub, rename the old container to a date-stamped backup, and start the new container with zero-downtime handover.\n\nThe image must have been pushed first (use "Build & Push" on the workstation).')) return;
            stopRebuildPolling();
            log('=== PULL & DEPLOY: ' + cid + ' ===', 'info');
            log('Pulling from Docker Hub and deploying on ' + currentTarget + '...', 'info');
            apiPost('/admin/docker/rebuild/' + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget), 'mode=pull-deploy')
                .then(function(d) {
                    if (d.success) {
                        log('Pull & Deploy started in background. Streaming output below:', 'dim');
                        startRebuildPolling(cid);
                    } else {
                        log('❌ Pull & Deploy failed to start: ' + (d.message || d.stderr || 'unknown'), 'err');
                        setStatus('err', 'Pull & Deploy failed');
                        setTimeout(loadAll, 5000);
                    }
                })
                .catch(function(e) {
                    stopRebuildPolling();
                    log('❌ Pull & Deploy request error: ' + e.message, 'err');
                    setStatus('err', 'Network error');
                    setTimeout(loadAll, 5000);
                });
        } else if (act === 'push-only') {
            if (!confirm('Push image for ' + cid + ' to Docker Hub?\n\nThis will push the current local image without rebuilding. Use this when the container is already working and you just need to push the image for production deployment.')) return;
            stopRebuildPolling();
            log('=== PUSH IMAGE: ' + cid + ' ===', 'info');
            log('Pushing image to Docker Hub (no rebuild)...', 'info');
            apiPost('/admin/docker/rebuild/' + encodeURIComponent(cid) + '?host=' + encodeURIComponent(currentTarget), 'mode=push-only')
                .then(function(d) {
                    if (d.success) {
                        log('Push started in background. Streaming output below:', 'dim');
                        startRebuildPolling(cid);
                    } else {
                        log('❌ Push failed to start: ' + (d.message || d.stderr || 'unknown'), 'err');
                        setStatus('err', 'Push failed');
                        setTimeout(loadAll, 5000);
                    }
                })
                .catch(function(e) {
                    stopRebuildPolling();
                    log('❌ Push request error: ' + e.message, 'err');
                    setStatus('err', 'Network error');
                    setTimeout(loadAll, 5000);
                });
        }
    }

    // ──────────────────────────────────────────────────────────
    // Docker disk cleanup — show usage, confirm, then prune
    // ──────────────────────────────────────────────────────────
    function dockerPrune() {
        log('Checking Docker disk usage on ' + currentTarget + '...', 'info');
        setStatus('check', 'Checking disk...');

        // First, show current usage
        apiPost('/admin/docker/prune', 'host=' + encodeURIComponent(currentTarget) + '&action=df')
            .then(function(data) {
                if (!data.success) {
                    log('❌ Failed to check disk usage: ' + (data.error || 'unknown'), 'err');
                    setStatus('err', 'Check failed');
                    return;
                }

                // Show current usage
                log('--- Current Docker Disk Usage ---', 'info');
                var lines = (data.output || '').split('\n');
                lines.forEach(function(l) { if (l.trim()) log(l, null); });
                log('', null);

                // Ask user to confirm pruning
                if (!confirm('Clean up Docker disk space on ' + currentTarget + '?\n\n' +
                    'This will:\n' +
                    '  • Remove ALL build cache (docker builder prune -a)\n' +
                    '  • Remove unused/dangling images (docker image prune -a)\n\n' +
                    'Volumes are NOT touched — backup data is safe.\n\n' +
                    'Proceed?')) {
                    log('Cleanup cancelled.', 'dim');
                    setStatus('ok', 'Cancelled');
                    return;
                }

                // Run the actual prune
                log('=== PRUNING DOCKER DISK SPACE ===', 'info');
                setStatus('check', 'Pruning...');

                apiPost('/admin/docker/prune', 'host=' + encodeURIComponent(currentTarget) + '&action=prune')
                    .then(function(pruneData) {
                        if (!pruneData.success) {
                            log('❌ Prune failed: ' + (pruneData.error || 'unknown'), 'err');
                            setStatus('err', 'Prune failed');
                            return;
                        }

                        // Show all output
                        var pruneLines = (pruneData.output || '').split('\n');
                        pruneLines.forEach(function(l) { if (l.trim()) log(l, null); });

                        // Try to extract final reclaim info
                        var finalLine = pruneLines.filter(function(l) { return l.match(/Total/i); }).pop() || '';
                        if (finalLine) {
                            log('✅ Disk cleanup complete!', 'ok');
                            log('Final: ' + finalLine, 'dim');
                        } else {
                            log('✅ Disk cleanup complete.', 'ok');
                        }
                        setStatus('ok', 'Cleanup done');
                        // Reload to reflect changes
                        setTimeout(loadAll, 3000);
                    })
                    .catch(function(e) {
                        log('❌ Prune error: ' + e.message, 'err');
                        setStatus('err', 'Prune error');
                    });
            })
            .catch(function(e) {
                log('❌ Disk check error: ' + e.message, 'err');
                setStatus('err', 'Check error');
            });
    }

    // ──────────────────────────────────────────────────────────
    // Event delegation
    // ──────────────────────────────────────────────────────────
    document.addEventListener('click', function(e) {
        var el = e.target.closest('[data-action]');
        if (!el) {
            // Also check for non-data-action buttons by id
            if (e.target.id === 'btn-start-deploy') {
                e.preventDefault();
                submitDeployForm();
                return;
            }
            if (e.target.id === 'btn-cancel-deploy' || e.target.id === 'btn-close-deploy-form') {
                e.preventDefault();
                hideDeployForm();
                return;
            }
            return;
        }
        var action = el.getAttribute('data-action');

        if (action === 'refresh-all') {
            e.preventDefault();
            loadAll();
        } else if (action === 'show-deploy-form') {
            e.preventDefault();
            showDeployForm();
        } else if (action === 'container-act') {
            e.preventDefault();
            containerAction(el.getAttribute('data-cid'), el.getAttribute('data-act'));
        } else if (action === 'volume-act') {
            e.preventDefault();
            var vname = el.getAttribute('data-vname');
            log('Volume inspect for ' + vname + ' coming soon.', 'info');
        } else if (action === 'clear-output') {
            e.preventDefault();
            if (outputBox) {
                outputBox.textContent = 'Ready.\n';
                // Reset status to current container count if not rebuilding
                if (!rebuildPollingTimer) {
                    setStatus('ok', containersCache.length + ' containers');
                }
            }
        } else if (action === 'docker-prune') {
            e.preventDefault();
            dockerPrune();
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

    // Clean up polling timer on page unload
    window.addEventListener('beforeunload', function() {
        stopRebuildPolling();
    });

})();