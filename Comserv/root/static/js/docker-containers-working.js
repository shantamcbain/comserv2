/**
 * docker-containers-working.js
 * Extracted from docker_containers_working.tt — JS-policy compliant.
 * All functions use event delegation via data-action attributes (no onclick in HTML).
 * Routes use the new /admin/docker/* (slash) pattern from Admin::Docker controller.
 *
 * Requires: xterm.js + xterm-addon-fit (loaded via js_load.tt)
 */
(function() {
    'use strict';

    // ── DOM refs (populated on DOMContentLoaded) ────────────────────
    let outputBox, containersList, containersData = [];
    let _lastDeployContent = '';
    let rebuildPollTimer = null, rebuildLastLen = 0;

    // ── Collapsible Sections ─────────────────────────────────────────
    window.toggleSection = function(sectionId) {
        const content = document.getElementById(sectionId);
        const chevron = document.getElementById('chevron-' + sectionId);
        if (!content) return;

        if (content.style.display === 'none' || content.style.display === '') {
            content.style.display = 'block';
            if (chevron) chevron.classList.add('expanded');
            if (sectionId === 'volumes-status') refreshVolumes();
            else if (sectionId === 'container-status') refreshContainers();
            else if (sectionId === 'docker-diagnostics-card') loadDiagnostics();
        } else {
            content.style.display = 'none';
            if (chevron) chevron.classList.remove('expanded');
        }
    };

    // ── Popup / Output Helpers ───────────────────────────────────────
    function showResultPopup(title, content, isSuccess) {
        const modal = document.getElementById('result-modal');
        const mTitle = document.getElementById('modal-title');
        const mBody = document.getElementById('modal-body');
        if (modal && mTitle && mBody) {
            let prefix = isSuccess === 'loading' ? '⏳ ' : isSuccess ? '🟢 ' : '🔴 ';
            mTitle.innerHTML = prefix + title;
            mBody.textContent = content;
            modal.style.display = 'flex';
        } else {
            alert(title + ':\n' + content);
        }
    }
    window.closeResultModal = function() {
        const modal = document.getElementById('result-modal');
        if (modal) modal.style.display = 'none';
    };

    function appendOutput(message) {
        if (!outputBox) return;
        const timestamp = new Date().toLocaleTimeString();
        outputBox.textContent += '[' + timestamp + '] ' + message + '\n';
        outputBox.scrollTop = outputBox.scrollHeight;
    }
    window.clearOutput = function() {
        if (outputBox) outputBox.textContent = 'Ready for commands...\n';
    };

    // ── Safe Fetch (handles session expiry) ──────────────────────────
    function safeFetch(url, options) {
        const target = document.getElementById('docker-target-select')?.value || 'workstation';
        if (url.indexOf('target=') === -1) {
            url += (url.indexOf('?') === -1 ? '?' : '&') + 'target=' + encodeURIComponent(target);
        }
        const opts = Object.assign({ credentials: 'same-origin', redirect: 'manual' }, options || {});
        return fetch(url, opts).then(function(response) {
            if (response.type === 'opaqueredirect' || response.status === 0 ||
                (response.status >= 300 && response.status < 400)) {
                appendOutput('✗ Session expired — reload the page (Ctrl+Shift+R) and log in again.');
                return Promise.reject(new Error('session-expired'));
            }
            if (!response.ok) {
                appendOutput('✗ Server error (HTTP ' + response.status + ') — check server logs.');
                return Promise.reject(new Error('HTTP ' + response.status));
            }
            return response;
        });
    }

    // ── Target / Host Selection ─────────────────────────────────────
    window.onTargetChange = function() {
        const targetSelect = document.getElementById('docker-target-select');
        const targetText = targetSelect ? targetSelect.options[targetSelect.selectedIndex].text : 'Workstation';
        const display = document.getElementById('target-info-display');
        if (display) display.innerHTML = 'Active System: <strong>' + targetText + '</strong>';

        const targetVal = targetSelect ? targetSelect.value : 'workstation';
        updateEmergencyCommands(targetVal);
        appendOutput('\n📡 Switched active system target to: ' + targetText + '\n');
        refreshContainers();
        loadDiagnostics();

        const volSection = document.getElementById('volumes-status');
        if (volSection && volSection.style.display === 'block') refreshVolumes();
    };

    // ── Refresh & Render ─────────────────────────────────────────────
    window.refreshContainers = function() {
        if (!containersList) return;
        containersList.innerHTML = '<p style="color: var(--text-muted-color, #666); text-align: center;">Loading container information...</p>';
        const target = document.getElementById('docker-target-select')?.value || 'workstation';

        // FIXED: /admin/docker-list → /admin/docker/list
        fetch('/admin/docker/list?host=' + encodeURIComponent(target), { credentials: 'same-origin', redirect: 'manual' })
            .then(function(response) {
                if (response.type === 'opaqueredirect' || response.status === 0 || (response.status >= 300 && response.status < 400)) {
                    containersList.innerHTML = '<p style="color: #dc3545; text-align: center;">Session expired — please <a href="/user/login">log in again</a>.</p>';
                    return null;
                }
                if (!response.ok) throw new Error('HTTP ' + response.status);
                return response.json();
            })
            .then(data => {
                if (!data) return;
                if (!data.success) {
                    containersList.innerHTML = '<p style="color: #dc3545; text-align: center;">Error: ' + (data.error || 'Unknown') + '</p>';
                    return;
                }
                containersData = data.containers;
                displayContainers(data.containers, data.host);
                displayBackups(data.backups);
                updateServiceDropdown(data.containers);
                // Volumes come in the same response — render them too
                if (data.volumes && data.volumes.length) {
                    displayVolumes(data.volumes);
                }
            })
            .catch(error => {
                containersList.innerHTML = '<p style="color: #dc3545; text-align: center;">Error loading containers: ' + error.message + '</p>';
            });
    };

    window.refreshVolumes = function() {
        const volumesList = document.getElementById('volumes-list');
        if (!volumesList) return;
        volumesList.innerHTML = '<p style="color: var(--text-muted-color, #666); text-align: center;">Loading volume information...</p>';
        const target = document.getElementById('docker-target-select')?.value || 'workstation';

        // FIXED: /admin/docker-volumes → /admin/docker/list (volumes come with container data)
        fetch('/admin/docker/list?host=' + encodeURIComponent(target), { credentials: 'same-origin', redirect: 'manual' })
            .then(function(response) {
                if (response.type === 'opaqueredirect' || response.status === 0 || (response.status >= 300 && response.status < 400)) {
                    volumesList.innerHTML = '<p style="color: #dc3545; text-align: center;">Session expired — please <a href="/user/login">log in again</a>.</p>';
                    return null;
                }
                if (!response.ok) throw new Error('HTTP ' + response.status);
                return response.json();
            })
            .then(data => {
                if (!data) return;
                if (!data.success) {
                    volumesList.innerHTML = '<p style="color: #dc3545; text-align: center;">Error: ' + (data.error || 'Unknown') + '</p>';
                    return;
                }
                displayVolumes(data.volumes);
            })
            .catch(error => {
                volumesList.innerHTML = '<p style="color: #dc3545; text-align: center;">Error loading volumes: ' + error.message + '</p>';
            });
    };

    function displayBackups(backups) {
        const backupsList = document.getElementById('backups-list');
        if (!backupsList) return;
        if (!backups || backups.length === 0) {
            backupsList.innerHTML = '<p style="color: var(--text-muted-color, #666); text-align: center; font-size: 11px; margin: 5px 0;">No backups found</p>';
            return;
        }
        let html = '';
        (backups || []).forEach(backup => {
            html +=
                '<div style="border: 1px solid var(--border-color, #ddd); border-radius: 4px; padding: 10px; background-color: rgba(255,255,255,0.88); display: flex; align-items: center; justify-content: space-between; margin-bottom: 6px;">' +
                '<div style="font-size: 12px; color: var(--text-color, #333); font-family: monospace; display: flex; align-items: center; gap: 8px;">' +
                '<i class="fas fa-archive" style="color: #6c757d;"></i>' +
                '<strong>' + backup + '</strong>' +
                '</div></div>';
        });
        backupsList.innerHTML = html;
    }

    function displayVolumes(volumes) {
        const volumesList = document.getElementById('volumes-list');
        if (!volumesList) return;
        if (!volumes || volumes.length === 0) {
            volumesList.innerHTML = '<p style="color: var(--text-muted-color, #666); text-align: center;">No volumes found</p>';
            return;
        }
        let html = '';
        volumes.forEach(vol => {
            const isNfs = vol.is_nfs === true || vol.is_nfs == 1;
            const typeLabel = isNfs ? 'NFS' : (vol.driver || 'local');
            const typeColor = isNfs ? '#17a2b8' : '#6c757d';
            const typeIcon = isNfs ? '🌐' : '💾';

            const mountDisplay = vol.mountpoint
                ? '<div style="font-size: 12px; color: var(--text-muted-color, #666); margin-bottom: 4px;"><strong>Mountpoint:</strong> <code style="font-size: 11px;">' + vol.mountpoint + '</code></div>'
                : '';

            const nfsDetail = isNfs
                ? '<div style="font-size: 12px; color: #17a2b8; margin-bottom: 4px;">' +
                  '<strong>NFS Server:</strong> ' + (vol.nfs_server || 'unknown') +
                  ' &nbsp;|&nbsp; ' +
                  '<strong>Export:</strong> ' + (vol.nfs_device || 'unknown') +
                  '</div>'
                : '';

            const labelsDisplay = vol.labels
                ? '<div style="font-size: 11px; color: #999; margin-bottom: 4px;"><strong>Labels:</strong> ' + vol.labels + '</div>'
                : '';

            html +=
                '<div style="border: 1px solid var(--border-color, #ddd); border-radius: 4px; padding: 12px; background-color: rgba(255,255,255,0.88);">' +
                '<div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px;">' +
                '<strong style="font-size: 14px;">' + typeIcon + ' ' + vol.name + '</strong>' +
                '<span style="background-color: ' + typeColor + '; color: white; padding: 2px 8px; border-radius: 3px; font-size: 11px;">' + typeLabel + '</span>' +
                '</div>' +
                nfsDetail + mountDisplay + labelsDisplay +
                '<div style="font-size: 11px; color: #999;"><strong>Scope:</strong> ' + (vol.scope || 'local') + '</div>' +
                '</div>';
        });
        volumesList.innerHTML = html;
    }

    function displayContainers(containers, host) {
        if (!containersList) return;
        if (!containers || containers.length === 0) {
            containersList.innerHTML = '<p style="color: var(--text-muted-color, #666); text-align: center;">No containers found</p>';
            return;
        }
        const hostLabel = host ? '<div style="margin-bottom:10px;padding:6px 10px;background: var(--bg-secondary, #e9ecef);border-radius:4px;font-size:13px;"><strong>Server:</strong> ' + host + '</div>' : '';
        let html = hostLabel;

        containers.forEach(container => {
            const stateColor = getStateColor(container.state);
            const stateIcon = getStateIcon(container.state);
            const isRunning = ['running', 'up'].includes((container.state || '').toLowerCase());
            const displayName = container.name || container.id || '(unnamed)';
            const healthBadge = container.status && container.status.includes('healthy') && !container.status.includes('unhealthy')
                ? '<span style="background: var(--success-color, #28a745);color:#fff;padding:1px 6px;border-radius:3px;font-size:11px;margin-left:6px;">healthy</span>'
                : container.status && container.status.includes('unhealthy')
                ? '<span style="background: var(--danger-color, #dc3545);color:#fff;padding:1px 6px;border-radius:3px;font-size:11px;margin-left:6px;">unhealthy</span>'
                : '';

            let tagInfo = '';
            if (container.image_tags && container.image_tags.length > 0) {
                const activeTags = container.image_tags.filter(t => t !== '<none>');
                if (activeTags.length > 0) {
                    const backupTags = activeTags.filter(t => t.startsWith('backup-'));
                    if (backupTags.length > 0) {
                        if (activeTags.includes('latest')) {
                            tagInfo = '<div style="font-size: 12px; margin-bottom: 6px;"><span style="background-color: #fff3cd; color: #856404; padding: 4px 10px; border-radius: 4px; font-weight: bold; font-size: 11px; border-left: 4px solid #ff922b; display: inline-flex; align-items: center; gap: 6px;"><i class="fas fa-exclamation-triangle" style="color: #ff922b;"></i> ACTIVE FAILOVER: Running ' + backupTags.join(', ') + ' (tagged as latest)</span></div>';
                        } else {
                            tagInfo = '<div style="font-size: 12px; margin-bottom: 6px;"><span style="background-color: #f8d7da; color: #721c24; padding: 4px 10px; border-radius: 4px; font-weight: bold; font-size: 11px; border-left: 4px solid #dc3545; display: inline-flex; align-items: center; gap: 6px;"><i class="fas fa-history" style="color: #dc3545;"></i> ROLLED BACK: Running ' + backupTags.join(', ') + '</span></div>';
                        }
                    } else {
                        tagInfo = '<div style="font-size: 12px; margin-bottom: 3px;"><span style="background-color: #d4edda; color: #155724; padding: 2px 6px; border-radius: 3px; font-weight: bold; font-size: 11px;"><i class="fas fa-check-circle"></i> Running LATEST image</span></div>';
                    }
                }
            }

            const buildInfoHtml = container.build_info ?
                '<div style="font-size: 12px; color: var(--text-muted-color, #555); margin-bottom: 5px; margin-top: 5px; background-color: #f1f3f5; padding: 4px 8px; border-radius: 4px; border-left: 3px solid #007bff; display: inline-block;">' +
                '<i class="fas fa-code-branch" style="color: #007bff; margin-right: 4px;"></i>' +
                '<strong>Build:</strong> <span>' + (container.build_info.build_date || 'N/A') + '</span>' +
                ' &nbsp;|&nbsp; ' +
                '<strong>Commit:</strong> <code style="font-weight: bold; color: #111;">' + (container.build_info.commit ? container.build_info.commit.substring(0, 8) : 'N/A') + '</code>' +
                (container.build_info.branch ? ' &nbsp;|&nbsp; <strong>Branch:</strong> <span style="color: #28a745;">' + container.build_info.branch + '</span>' : '') +
                (container.build_info.build_host ? ' &nbsp;|&nbsp; <strong>Built On:</strong> <span style="color: #6c757d;">' + container.build_info.build_host + '</span>' : '') +
                '</div>' : '';

            // data-action buttons (no onclick)
            const actionButtons = container.state === 'not_created'
                ? '<button data-action="create" data-service="' + container.name + '" class="compact-btn" style="background-color: var(--success-color, #28a745); color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 12px; padding: 6px 12px;">🚀 Create & Start</button>'
                : isRunning
                ? '<button data-action="stop" data-service="' + container.name + '" class="compact-btn" style="background-color: var(--danger-color, #dc3545); color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 12px; padding: 6px 12px;">■ Stop</button>' +
                  '<button data-action="restart" data-service="' + container.name + '" class="compact-btn" style="background-color: #0066cc; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 12px; padding: 6px 12px;">↻ Restart</button>' +
                  '<button data-action="logs" data-service="' + container.name + '" class="compact-btn" style="background-color: #17a2b8; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 12px; padding: 6px 12px;">📋 Logs</button>'
                : '<button data-action="start" data-service="' + container.name + '" class="compact-btn" style="background-color: var(--success-color, #28a745); color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 12px; padding: 6px 12px;">▶ Start</button>' +
                  '<button data-action="logs" data-service="' + container.name + '" class="compact-btn" style="background-color: #17a2b8; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 12px; padding: 6px 12px;">📋 Logs</button>';

            html +=
                '<div style="border: 1px solid var(--border-color, #ddd); border-radius: 4px; padding: 15px; background-color: rgba(255,255,255,0.88);">' +
                '<div style="display: flex; justify-content: space-between; align-items: start; margin-bottom: 10px;">' +
                '<div style="flex: 1;">' +
                '<h4 style="margin: 0 0 5px 0; color: var(--text-color, #333);">' +
                '<span style="color: ' + stateColor + '; margin-right: 8px;">' + stateIcon + '</span>' + displayName + healthBadge +
                '</h4>' +
                '<div style="font-size: 12px; color: var(--text-muted-color, #666); margin-bottom: 3px;"><strong>Image:</strong> ' + (container.image || '') + '</div>' +
                tagInfo +
                '<div style="font-size: 12px; color: var(--text-muted-color, #666); margin-bottom: 3px;"><strong>ID:</strong> <code>' + (container.id || '') + '</code> &nbsp;|&nbsp; <strong>Status:</strong> ' + (container.status || container.state || '') + '</div>' +
                (container.ports ? '<div style="font-size:12px;color: var(--text-muted-color, #666);margin-bottom:3px;"><strong>Ports:</strong> ' + container.ports + '</div>' : '') +
                buildInfoHtml +
                '<div style="font-size: 12px; margin-top: 3px;"><span style="background-color: ' + stateColor + '; color: white; padding: 2px 8px; border-radius: 3px; font-weight: bold;">' + (container.state || 'unknown').toUpperCase() + '</span></div>' +
                '</div>' +
                '<div style="display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end;">' + actionButtons + '</div>' +
                '</div></div>';
        });

        containersList.innerHTML = html;
    }

    function updateServiceDropdown(containers) {
        const select = document.getElementById('service-select');
        if (!select) return;
        while (select.options.length > 2) select.remove(2);
        containers.forEach(container => {
            const option = document.createElement('option');
            option.value = container.name;
            option.textContent = container.name;
            select.appendChild(option);
        });
    }

    // ── State Helpers ────────────────────────────────────────────────
    function getStateColor(state) {
        const colors = { running: '#28a745', up: '#28a745', exited: '#dc3545', exit: '#dc3545', restarting: '#ffc107', paused: '#6c757d', created: '#17a2b8', not_created: '#6c757d', unknown: '#6c757d' };
        return colors[(state || '').toLowerCase()] || '#6c757d';
    }
    function getStateIcon(state) {
        const icons = { running: '▶', up: '▶', exited: '■', exit: '■', restarting: '↻', paused: '❚❚', created: '○', not_created: '○', unknown: '?' };
        return icons[(state || '').toLowerCase()] || '?';
    }

    function getSelectedService() {
        const select = document.getElementById('service-select');
        const service = select ? select.value : '';
        if (!service) { alert('Please select a service'); return null; }
        return service;
    }

    // ── Direct Container Actions ─────────────────────────────────────
    function createContainerDirect(service) {
        appendOutput('Creating and starting ' + service + '...');
        const target = document.getElementById('docker-target-select')?.value || 'workstation';
        showResultPopup('Create & Start ' + service, '⏳ Creating and starting ' + service + ' on target: ' + target.toUpperCase() + '...\n\nPlease wait.', 'loading');
        safeFetch('/admin/docker/up/' + encodeURIComponent(service), { method: 'POST' })
            .then(r => r.json()).then(data => {
                if (data.success) { appendOutput('✓ ' + service + ' created and started successfully!\n' + (data.stdout || '')); showResultPopup('Create & Start ' + service, '✓ ' + service + ' created and started successfully!\n\n' + (data.stdout || ''), true); setTimeout(refreshContainers, 2000); }
                else { const err = data.stderr || data.error || 'Unknown error'; appendOutput('✗ Failed to create ' + service + ':\n' + err); showResultPopup('Create & Start ' + service + ' Failed', '✗ Failed to create ' + service + ':\n\n' + err, false); }
            }).catch(error => { appendOutput('Error: ' + error.message); showResultPopup('Error', error.message, false); });
    }

    function startContainerDirect(service) {
        appendOutput('Starting ' + service + '...');
        const target = document.getElementById('docker-target-select')?.value || 'workstation';
        showResultPopup('Start ' + service, '⏳ Starting ' + service + ' on target: ' + target.toUpperCase() + '...\n\nPlease wait.', 'loading');
        safeFetch('/admin/docker/start/' + encodeURIComponent(service), { method: 'POST' })
            .then(r => r.json()).then(data => {
                if (data.success) { appendOutput('✓ ' + service + ' started successfully!\n' + (data.stdout || '')); showResultPopup('Start ' + service, '✓ ' + service + ' started successfully!\n\n' + (data.stdout || ''), true); setTimeout(refreshContainers, 1000); }
                else { const err = data.stderr || data.error || 'Unknown error'; appendOutput('✗ Failed to start ' + service + ':\n' + err); showResultPopup('Start ' + service + ' Failed', '✗ Failed to start ' + service + ':\n\n' + err, false); }
            }).catch(error => { appendOutput('Error: ' + error.message); showResultPopup('Error', error.message, false); });
    }

    function stopContainerDirect(service) {
        if (!confirm('Are you sure you want to stop ' + service + '?')) return;
        appendOutput('Stopping ' + service + '...');
        const target = document.getElementById('docker-target-select')?.value || 'workstation';
        showResultPopup('Stop ' + service, '⏳ Stopping ' + service + ' on target: ' + target.toUpperCase() + '...\n\nPlease wait.', 'loading');
        safeFetch('/admin/docker/stop/' + encodeURIComponent(service), { method: 'POST' })
            .then(r => r.json()).then(data => {
                if (data.success) { appendOutput('✓ ' + service + ' stopped successfully!\n' + (data.stdout || '')); showResultPopup('Stop ' + service, '✓ ' + service + ' stopped successfully!\n\n' + (data.stdout || ''), true); setTimeout(refreshContainers, 1000); }
                else { const err = data.stderr || data.error || 'Unknown error'; appendOutput('✗ Failed to stop ' + service + ':\n' + err); showResultPopup('Stop ' + service + ' Failed', '✗ Failed to stop ' + service + ':\n\n' + err, false); }
            }).catch(error => { appendOutput('Error: ' + error.message); showResultPopup('Error', error.message, false); });
    }

    function restartContainerDirect(service) {
        if (!confirm('Are you sure you want to restart ' + service + '?')) return;
        appendOutput('Restarting ' + service + '...');
        const target = document.getElementById('docker-target-select')?.value || 'workstation';
        showResultPopup('Restart ' + service, '⏳ Restarting ' + service + ' on target: ' + target.toUpperCase() + '...\n\nPlease wait.', 'loading');
        safeFetch('/admin/docker/restart/' + encodeURIComponent(service) + '?force=0', { method: 'POST' })
            .then(r => r.json()).then(data => {
                if (data.success) { appendOutput('✓ ' + service + ' restarted successfully!\n' + (data.stdout || '')); showResultPopup('Restart ' + service, '✓ ' + service + ' restarted successfully!\n\n' + (data.stdout || ''), true); setTimeout(refreshContainers, 2000); }
                else { const err = data.stderr || data.error || 'Unknown error'; appendOutput('✗ Failed to restart ' + service + ':\n' + err); showResultPopup('Restart ' + service + ' Failed', '✗ Failed to restart ' + service + ':\n\n' + err, false); }
            }).catch(error => { appendOutput('Error: ' + error.message); showResultPopup('Error', error.message, false); });
    }

    function viewLogsDirect(service) {
        const lines = prompt('How many lines of logs to display? (default: 50)', '50');
        if (lines === null) return;
        appendOutput('Getting logs for ' + service + ' (last ' + lines + ' lines)...');
        const target = document.getElementById('docker-target-select')?.value || 'workstation';
        showResultPopup('Logs for ' + service, '⏳ Fetching last ' + lines + ' lines of logs for ' + service + ' on target: ' + target.toUpperCase() + '...\n\nPlease wait.', 'loading');
        safeFetch('/admin/docker/logs/' + encodeURIComponent(service) + '?lines=' + (parseInt(lines) || 50))
            .then(r => r.json()).then(data => {
                if (data.output || data.error === '') { const out = data.output || 'No logs available'; appendOutput('Logs for ' + service + ':\n' + out); showResultPopup('Logs for ' + service + ' (Last ' + lines + ' Lines)', out, true); }
                else if (data.error) { appendOutput('Error getting logs:\n' + data.error); showResultPopup('Logs for ' + service + ' Failed', 'Error getting logs:\n\n' + data.error, false); }
                else { appendOutput('Unable to retrieve logs'); showResultPopup('Logs for ' + service + ' Failed', 'Unable to retrieve logs', false); }
            }).catch(error => { appendOutput('Error: ' + error.message); showResultPopup('Error', error.message, false); });
    }

    // ── Rebuild ──────────────────────────────────────────────────────
    function _startRebuildPoll(service, autoStart) {
        rebuildLastLen = 0;
        rebuildPollTimer = setInterval(async () => {
            try {
                // NOTE: /admin/docker-rebuild-status/ route may not exist yet — will need to be added
                const resp = await safeFetch('/admin/docker-rebuild-status/' + encodeURIComponent(service));
                const data = await resp.json();
                const full = data.output || '';
                if (full.length > rebuildLastLen) {
                    appendOutput(full.slice(rebuildLastLen));
                    rebuildLastLen = full.length;
                }
                if (data.done) {
                    clearInterval(rebuildPollTimer); rebuildPollTimer = null;
                    appendOutput('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
                    if (data.exit_code === 0) {
                        appendOutput('✓ ' + service + ' rebuilt successfully!\n');
                        if (autoStart) {
                            appendOutput('⏳ Starting ' + service + '...\n');
                            const sr = await safeFetch('/admin/docker/up/' + encodeURIComponent(service), { method: 'POST' });
                            const sd = await sr.json();
                            appendOutput(sd.success ? '✓ ' + service + ' started.\n' : '✗ Start failed.\n');
                        }
                        setTimeout(() => { refreshContainers(); enableRebuildButtons(); }, 2000);
                    } else { appendOutput('✗ Build failed (exit ' + data.exit_code + ').\n'); enableRebuildButtons(); }
                }
            } catch(e) { clearInterval(rebuildPollTimer); rebuildPollTimer = null; appendOutput('Poll error: ' + e.message + '\n'); enableRebuildButtons(); }
        }, 5000);
    }

    function _doRebuild(service, autoStart) {
        disableRebuildButtons();
        appendOutput('⏳ Rebuilding ' + service + '... (runs in background, updates every 5s)\n');
        appendOutput('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
        // NOTE: /admin/docker-rebuild/ route may not exist yet
        safeFetch('/admin/docker-rebuild/' + encodeURIComponent(service))
            .then(r => r.json()).then(data => {
                if (data.success) { appendOutput('Build started (PID tracked). Streaming output...\n'); _startRebuildPoll(service, autoStart); }
                else { appendOutput('✗ Could not start build: ' + (data.error || 'Unknown error') + '\n'); enableRebuildButtons(); }
            }).catch(err => { appendOutput('✗ Request error: ' + err.message + '\n'); enableRebuildButtons(); });
    }

    function rebuildContainerDirect(service) {
        if (!confirm('Rebuild ' + service + '? This takes ~8 minutes. The build runs in the background — you can watch progress here.')) return;
        _doRebuild(service, true);
    }
    function disableRebuildButtons() {
        document.querySelectorAll('[data-action="rebuild"], [data-action*="rebuild"]').forEach(btn => { btn.disabled = true; btn.style.opacity = '0.5'; });
    }
    function enableRebuildButtons() {
        document.querySelectorAll('[data-action="rebuild"], [data-action*="rebuild"]').forEach(btn => { btn.disabled = false; btn.style.opacity = '1'; });
    }
    window.rebuildContainer = function() {
        const service = getSelectedService(); if (!service) return;
        if (!confirm('Rebuild ' + service + '? This takes ~8 minutes. The build runs in the background — you can watch progress here.')) return;
        _doRebuild(service, false);
    };

    // ── Misc Actions ─────────────────────────────────────────────────
    window.pruneDockerSystem = function() {
        if (!confirm('Remove all stopped containers, dangling images, and unused networks? This will free up disk space.')) return;
        appendOutput('⏳ Cleaning up Docker system...\n');
        const target = document.getElementById('docker-target-select')?.value || 'workstation';
        showResultPopup('Docker System Cleanup', '⏳ Pruning unused Docker objects on target: ' + target.toUpperCase() + '...\n\nThis may take several seconds. Please wait.', 'loading');
        // NOTE: route may not exist — needs /admin/docker/prune (or equivalent)
        safeFetch('/admin/docker-prune')
            .then(r => r.json()).then(data => {
                if (data.success || data.output) { appendOutput('✓ Cleanup complete!\n\n' + (data.output || 'No output')); showResultPopup('Docker Cleanup Complete', '✓ Cleanup complete!\n\n' + (data.output || ''), true); setTimeout(refreshContainers, 1000); }
                else { const err = data.error || 'Unknown error'; appendOutput('✗ Cleanup failed:\n' + err + '\n'); showResultPopup('Docker Cleanup Failed', '✗ Cleanup failed:\n\n' + err, false); }
            }).catch(error => { appendOutput('Error: ' + error.message + '\n'); showResultPopup('Error', error.message, false); });
    };

    window.showDiskUsage = function() {
        appendOutput('⏳ Fetching Docker disk usage...\n');
        const target = document.getElementById('docker-target-select')?.value || 'workstation';
        showResultPopup('Docker Disk Usage', '⏳ Querying Docker df stats on target: ' + target.toUpperCase() + '...\n\nPlease wait.', 'loading');
        safeFetch('/admin/docker-system-df')
            .then(r => r.json()).then(data => {
                if (data.success || data.output) { const out = data.output || 'No data available'; appendOutput('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n💾 Docker Disk Usage:\n\n' + out + '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'); showResultPopup('Docker Disk Usage Status', out, true); }
                else { const err = data.error || 'Unknown error'; appendOutput('✗ Failed to get disk usage:\n' + err + '\n'); showResultPopup('Fetch Disk Usage Failed', '✗ Failed to get disk usage:\n\n' + err, false); }
            }).catch(error => { appendOutput('Error: ' + error.message + '\n'); showResultPopup('Error', error.message, false); });
    };

    window.restartContainer = function() {
        const service = getSelectedService(); if (!service) return;
        const force = document.getElementById('force-restart')?.checked;
        if (!confirm('Are you sure you want to restart ' + service + '?')) return;
        appendOutput('Restarting ' + service + (force ? ' (force mode)' : '') + '...');
        const target = document.getElementById('docker-target-select')?.value || 'workstation';
        showResultPopup('Restart ' + service, '⏳ Restarting ' + service + ' on target: ' + target.toUpperCase() + '...\n\nPlease wait.', 'loading');
        safeFetch('/admin/docker/restart/' + encodeURIComponent(service) + '?force=' + (force ? 1 : 0), { method: 'POST' })
            .then(r => r.json()).then(data => {
                if (data.success) { const out = data.stdout || data.output || ''; appendOutput('✓ Restart successful!\n' + out); showResultPopup('Restart ' + service, '✓ Restart successful!\n\n' + out, true); setTimeout(refreshContainers, 2000); }
                else { const err = data.stderr || data.error || 'Unknown error'; appendOutput('✗ Restart failed:\n' + err); showResultPopup('Restart ' + service + ' Failed', '✗ Restart failed:\n\n' + err, false); }
            }).catch(error => { appendOutput('Error: ' + error.message); showResultPopup('Error', error.message, false); });
    };

    window.viewLogs = function() {
        const service = getSelectedService(); if (!service) return;
        const lines = prompt('How many lines of logs to display? (default: 50)', '50');
        if (lines === null) return;
        appendOutput('Getting logs for ' + service + ' (last ' + lines + ' lines)...');
        const target = document.getElementById('docker-target-select')?.value || 'workstation';
        showResultPopup('Logs for ' + service, '⏳ Fetching last ' + lines + ' lines of logs for ' + service + ' on target: ' + target.toUpperCase() + '...\n\nPlease wait.', 'loading');
        safeFetch('/admin/docker/logs/' + encodeURIComponent(service) + '?lines=' + (parseInt(lines) || 50))
            .then(r => r.json()).then(data => {
                if (data.output || data.error === '') { const out = data.output || 'No logs available'; appendOutput('Logs:\n' + out); showResultPopup('Logs for ' + service + ' (Last ' + lines + ' Lines)', out, true); }
                else if (data.error) { appendOutput('Error getting logs:\n' + data.error); showResultPopup('Logs for ' + service + ' Failed', 'Error getting logs:\n\n' + data.error, false); }
                else { appendOutput('Unable to retrieve logs'); showResultPopup('Logs for ' + service + ' Failed', 'Unable to retrieve logs', false); }
            }).catch(error => { appendOutput('Error: ' + error.message); showResultPopup('Error', error.message, false); });
    };

    window.saveDockerImage = function() {
        const service = document.getElementById('deploy-service-select')?.value;
        if (!service) return;
        if (!confirm('Save ' + service + ' Docker image to local tar file?')) return;
        appendOutput('⏳ Saving Docker image: ' + service + '...\n');
        const target = document.getElementById('docker-target-select')?.value || 'workstation';
        showResultPopup('Save Docker Image', '⏳ Exporting ' + service + ' image to tar archive on target: ' + target.toUpperCase() + '...\n\nPlease wait.', 'loading');
        safeFetch('/admin/docker-save-image/' + encodeURIComponent(service))
            .then(r => r.json()).then(data => {
                if (data.success) { appendOutput('✓ Image saved successfully!\nLocation: ' + data.tar_file + '\n' + (data.output || '')); showResultPopup('Save Docker Image', '✓ Image saved successfully!\n\nLocation: ' + data.tar_file + '\n\n' + (data.output || ''), true); }
                else { const err = data.error || data.output || 'Unknown error'; appendOutput('✗ Failed to save image:\n' + err + '\n'); showResultPopup('Save Docker Image Failed', '✗ Failed to save image:\n\n' + err, false); }
            }).catch(error => { appendOutput('Error: ' + error.message + '\n'); showResultPopup('Error', error.message, false); });
    };

    // ── SSH / Deployment ─────────────────────────────────────────────
    window.updateSSHTarget = function() {
        const select = document.getElementById('ssh-target-select');
        const input = document.getElementById('production-host');
        if (select && input && select.value !== 'custom') input.value = select.value;
    };

    window.togglePasswordVisibility = function() {
        const pf = document.getElementById('ssh-password');
        const ei = document.getElementById('password-eye-icon');
        if (!pf || !ei) return;
        if (pf.type === 'password') { pf.type = 'text'; ei.className = 'fas fa-eye-slash'; }
        else { pf.type = 'password'; ei.className = 'fas fa-eye'; }
    };

    function updateSSHStatusIndicator(status) {
        const indicator = document.getElementById('ssh-status-indicator');
        if (!indicator) return;
        const config = { success: ['#28a745', '#1e7e34', 'SSH connection successful'], failed: ['#dc3545', '#c82333', 'SSH connection failed'], testing: ['#ffc107', '#e0a800', 'Testing connection...'] };
        if (config[status]) { indicator.style.backgroundColor = config[status][0]; indicator.style.borderColor = config[status][1]; indicator.title = config[status][2]; }
        else { indicator.style.backgroundColor = '#ccc'; indicator.style.borderColor = '#999'; indicator.title = 'Not tested'; }
    }

    window.testSSHConnection = function(event) {
        if (event) { event.preventDefault(); event.stopPropagation(); }
        const sshTarget = document.getElementById('production-host')?.value.trim();
        const sshPort = document.getElementById('ssh-port')?.value;
        const sshPassword = document.getElementById('ssh-password')?.value;
        if (!sshTarget) { alert('Please enter SSH target (user@host)'); return false; }
        if (!sshPassword) { alert('Please enter SSH password to test connection'); return false; }
        updateSSHStatusIndicator('testing');
        const outputSection = document.getElementById('output-console-section');
        const outputChevron = document.getElementById('chevron-output-console-section');
        if (outputSection && outputSection.style.display !== 'block') { outputSection.style.display = 'block'; if (outputChevron) outputChevron.classList.add('expanded'); }
        appendOutput('\n' + '='.repeat(80) + '\n🔌 Testing SSH connection to ' + sshTarget + ':' + sshPort + '...\n' + '='.repeat(80) + '\n');
        const formData = new FormData();
        formData.append('ssh_target', sshTarget); formData.append('ssh_port', sshPort); formData.append('ssh_password', sshPassword); formData.append('save_credentials', 'yes');
        safeFetch('/admin/docker-test-ssh', { method: 'POST', body: new URLSearchParams(formData) })
            .then(r => r.json()).then(data => {
                appendOutput('\n');
                if (data.success) { appendOutput('✅ SSH CONNECTION SUCCESSFUL\n' + '='.repeat(80) + '\n' + (data.output || 'Connection OK\n')); if (data.credentials_saved) appendOutput('\n✓ Credentials saved to ' + data.credentials_path + '\n'); updateSSHStatusIndicator('success'); }
                else { appendOutput('❌ SSH CONNECTION FAILED\n' + '='.repeat(80) + '\n' + ((data.output || data.error || 'Unknown error') + '\n')); updateSSHStatusIndicator('failed'); }
                appendOutput('='.repeat(80) + '\n\n');
            }).catch(error => { appendOutput('\n❌ CONNECTION TEST ERROR\n' + '='.repeat(80) + '\nError: ' + error.message + '\n' + '='.repeat(80) + '\n\n'); updateSSHStatusIndicator('failed'); });
        return false;
    };

    window.copyToClipboard = function(text) {
        navigator.clipboard.writeText(text).then(() => {
            const msg = document.createElement('div');
            msg.textContent = '✓ Copied to clipboard!';
            msg.style.cssText = 'position: fixed; top: 20px; right: 20px; background: var(--success-color, #28a745); color: white; padding: 12px 24px; border-radius: 4px; z-index: 10000; font-weight: bold;';
            document.body.appendChild(msg); setTimeout(() => msg.remove(), 2000);
        }).catch(err => { alert('Failed to copy: ' + err); });
    };

    // ── Deploy History ───────────────────────────────────────────────
    function loadDeployHistory() {
        fetch('/admin/docker-deploy-history', { credentials: 'same-origin' })
            .then(r => r.json()).then(data => {
                if (data.success && data.latest_file) { _lastDeployContent = data.latest_content || ''; const fname = data.latest_file.split('/').pop(); document.getElementById('last-deploy-file').textContent = fname; document.getElementById('last-deploy-banner').style.display = 'block'; }
            }).catch(() => {});
    }
    window.loadHistoryIntoOutput = function() {
        if (_lastDeployContent && outputBox) { outputBox.textContent = '=== Last Deploy Log ===\n' + _lastDeployContent; outputBox.scrollTop = outputBox.scrollHeight; }
    };

    function loadSavedCredentials() {
        fetch('/admin/docker-load-credentials', { credentials: 'same-origin' })
            .then(r => r.json()).then(data => {
                if (data.success && data.ssh_password) {
                    document.getElementById('ssh-password').value = data.ssh_password;
                    document.getElementById('production-host').value = data.ssh_target || 'ubuntu@192.168.1.126';
                    document.getElementById('ssh-port').value = data.ssh_port || 22;
                    if (document.getElementById('ssh-terminal-target')) document.getElementById('ssh-terminal-target').value = data.ssh_target || 'ubuntu@192.168.1.126';
                    if (document.getElementById('ssh-terminal-password')) document.getElementById('ssh-terminal-password').value = data.ssh_password;
                }
            }).catch(() => {});
    }

    // ── Diagnostics ──────────────────────────────────────────────────
    window.loadDiagnostics = function() {
        const loader = document.getElementById('diagnostics-loader');
        const content = document.getElementById('diagnostics-content');
        if (loader) loader.style.display = 'block';
        if (content) content.style.display = 'none';
        const target = document.getElementById('docker-target-select')?.value || 'workstation';
        safeFetch('/admin/docker-diagnostics?target=' + encodeURIComponent(target))
            .then(r => r.json()).then(data => {
                if (loader) loader.style.display = 'none';
                if (!data || !data.success || !data.diagnostics) {
                    if (content) { content.style.display = 'block'; content.innerHTML = '<div style="color: #dc3545; padding: 10px; text-align: center;">Error loading diagnostics: ' + (data?.error || 'Unknown error') + '</div>'; }
                    return;
                }
                const d = data.diagnostics;
                if (content) content.style.display = 'block';

                const compEl = document.getElementById('diag-compose');
                if (compEl) { const isInstalled = d.compose_status && d.compose_status.indexOf('Not installed') === -1 && d.compose_status.indexOf('ERROR') === -1; compEl.innerHTML = '<span style="color: ' + (isInstalled ? '#28a745' : '#dc3545') + '; font-weight: bold;">' + (isInstalled ? '🟢 Installed & Active' : '🔴 Not Detected / Error') + '</span><br><span style="color: #666; font-size: 10px;">' + (d.compose_status || 'Unknown') + '</span>'; }

                const starEl = document.getElementById('diag-starman');
                if (starEl) starEl.textContent = d.starman_status || 'No starman processes found';

                const portsEl = document.getElementById('diag-ports');
                if (portsEl) {
                    portsEl.innerHTML = '';
                    ['3000', '3001', '5000'].forEach(port => {
                        const active = d.active_ports && d.active_ports.includes(port);
                        portsEl.innerHTML += '<span style="display: inline-flex; align-items: center; gap: 4px; padding: 2px 6px; border-radius: 3px; font-size: 10px; background-color: ' + (active ? '#d4edda' : '#f8d7da') + '; color: ' + (active ? '#155724' : '#721c24') + '; border: 1px solid ' + (active ? '#c3e6cb' : '#f5c6cb') + ';"><span style="display: inline-block; width: 6px; height: 6px; border-radius: 50%; background-color: ' + (active ? '#28a745' : '#dc3545') + ';"></span> Port ' + port + ': ' + (active ? 'Bound' : 'Closed') + '</span>';
                    });
                }

                const gitEl = document.getElementById('diag-git');
                if (gitEl) gitEl.textContent = d.git_status || 'Unknown';

                const backupsEl = document.getElementById('diag-backups');
                if (backupsEl) {
                    backupsEl.innerHTML = '';
                    if (d.backups && d.backups.length > 0) {
                        d.backups.forEach(backup => {
                            backupsEl.innerHTML += '<div style="font-family: monospace; font-size: 10px; background: #e9ecef; padding: 4px 8px; border-radius: 3px; border: 1px solid #ddd; display: flex; justify-content: space-between; align-items: center;"><span>📦 ' + backup + '</span><span class="badge-pill" style="background-color: #17a2b8; font-size: 9px; padding: 1px 4px; border-radius: 2px; color: white;">ROLLBACK TARGET</span></div>';
                        });
                    } else { backupsEl.innerHTML = '<div style="color: #666; font-style: italic;">No recovery backup images found.</div>'; }
                }

                const diskEl = document.getElementById('diag-disk'); if (diskEl) diskEl.textContent = d.disk || 'N/A';
                const memEl = document.getElementById('diag-mem'); if (memEl) memEl.textContent = d.memory || 'N/A';
                const uptimeEl = document.getElementById('diag-uptime'); if (uptimeEl) uptimeEl.textContent = d.uptime || 'N/A';

                const footerHostBadge = document.getElementById('footer-host-badge');
                if (footerHostBadge) footerHostBadge.textContent = (target || 'workstation').toUpperCase();
                const footerUptime = document.getElementById('footer-uptime'); if (footerUptime) footerUptime.textContent = d.uptime || 'N/A';
                const footerDisk = document.getElementById('footer-disk'); if (footerDisk) footerDisk.textContent = d.disk || 'N/A';
                const footerMem = document.getElementById('footer-mem'); if (footerMem) footerMem.textContent = d.memory || 'N/A';
                const footerRefresh = document.getElementById('footer-last-refresh'); if (footerRefresh) footerRefresh.textContent = new Date().toLocaleTimeString();
            }).catch(err => {
                if (loader) loader.style.display = 'none';
                if (content) { content.style.display = 'block'; content.innerHTML = '<div style="color: #dc3545; padding: 10px; text-align: center;">Network/Server error loading diagnostics: ' + err.message + '</div>'; }
            });
    };

    window.startHostStarman = function() {
        const target = document.getElementById('docker-target-select')?.value || 'production1';
        if (!confirm('Are you sure you want to perform an Emergency Fallback and start Starman on host ' + target + '?\n\nThis will stop any running web container on port 5000 and run Starman on the host.')) return;
        showResultPopup('Starting Host Starman...', 'Connecting via SSH to host and triggering Starman startup sequence...\nThis may take up to 15 seconds.', 'loading');
        fetch('/admin/docker-start-starman?target=' + encodeURIComponent(target), { credentials: 'same-origin' })
            .then(r => r.json()).then(data => {
                if (data.success) { showResultPopup('Success', 'Host Starman started successfully:\n\n' + (data.message || ''), true); loadDiagnostics(); }
                else { showResultPopup('Error Starting Starman', data.error || 'Unknown error occurred.', false); }
            }).catch(err => { showResultPopup('Network Error', err.message || 'Network connection failed.', false); });
    };

    function updateEmergencyCommands(target) {
        let ip = '192.168.1.126';
        if (target === 'production2') ip = '192.168.1.127';
        else if (target === 'workstation') ip = 'localhost';
        const prefix = target === 'workstation' ? '' : 'ssh ubuntu@' + ip + ' ';

        const stopCompose = document.getElementById('emergency-cmd-stop-compose');
        if (stopCompose) stopCompose.innerText = target === 'workstation' ? 'cd /opt/comserv/Comserv && docker compose -f docker-compose.server.yml down' : 'ssh ubuntu@' + ip + ' "cd /opt/comserv/Comserv && docker compose -f docker-compose.server.yml down"';

        const stopDirect = document.getElementById('emergency-cmd-stop-direct');
        if (stopDirect) stopDirect.innerText = target === 'workstation' ? 'docker stop comserv2-web-prod && docker rm comserv2-web-prod' : 'ssh ubuntu@' + ip + ' "docker stop comserv2-web-prod && docker rm comserv2-web-prod"';

        const startStarman = document.getElementById('emergency-cmd-start-starman');
        if (startStarman) startStarman.innerText = target === 'workstation' ? 'sudo systemctl reset-failed starman.service && sudo systemctl enable starman.service && sudo systemctl start starman.service' : 'ssh ubuntu@' + ip + ' "sudo systemctl reset-failed starman.service && sudo systemctl enable starman.service && sudo systemctl start starman.service"';

        const statusStarman = document.getElementById('emergency-cmd-status-starman');
        if (statusStarman) statusStarman.innerText = target === 'workstation' ? 'sudo systemctl status starman.service' : 'ssh ubuntu@' + ip + ' "sudo systemctl status starman.service"';
    }

    // ── SSH Terminal (xterm.js) ──────────────────────────────────────
    let sshTerminal = null, sshWebSocket = null, sshFitAddon = null;

    function updateSSHConnectionStatus(status, message) {
        const statusDiv = document.getElementById('ssh-connection-status');
        const connectBtn = document.getElementById('ssh-connect-btn');
        const disconnectBtn = document.getElementById('ssh-disconnect-btn');
        if (!statusDiv) return;
        if (status === 'connected') { statusDiv.innerHTML = '<i class="fas fa-circle" style="color: #28a745;"></i> ' + message; if (connectBtn) { connectBtn.disabled = true; connectBtn.style.opacity = '0.5'; } if (disconnectBtn) { disconnectBtn.disabled = false; disconnectBtn.style.opacity = '1'; } }
        else if (status === 'connecting') { statusDiv.innerHTML = '<i class="fas fa-circle" style="color: #ffc107;"></i> ' + message; if (connectBtn) { connectBtn.disabled = true; connectBtn.style.opacity = '0.5'; } }
        else if (status === 'error') { statusDiv.innerHTML = '<i class="fas fa-circle" style="color: #dc3545;"></i> ' + message; if (connectBtn) { connectBtn.disabled = false; connectBtn.style.opacity = '1'; } if (disconnectBtn) { disconnectBtn.disabled = true; disconnectBtn.style.opacity = '0.5'; } }
        else { statusDiv.innerHTML = '<i class="fas fa-circle" style="color: var(--text-muted-color, #6c757d);"></i> Disconnected'; if (connectBtn) { connectBtn.disabled = false; connectBtn.style.opacity = '1'; } if (disconnectBtn) { disconnectBtn.disabled = true; disconnectBtn.style.opacity = '0.5'; } }
    }

    window.toggleSSHTerminalPassword = function() {
        const pf = document.getElementById('ssh-terminal-password');
        const ei = document.getElementById('ssh-terminal-password-eye');
        if (!pf || !ei) return;
        if (pf.type === 'password') { pf.type = 'text'; ei.className = 'fas fa-eye-slash'; }
        else { pf.type = 'password'; ei.className = 'fas fa-eye'; }
    };

    window.connectSSHTerminal = function() {
        let sshTarget = document.getElementById('ssh-terminal-target')?.value.trim();
        let sshPassword = document.getElementById('ssh-terminal-password')?.value;
        if (!sshTarget) sshTarget = document.getElementById('production-host')?.value.trim();
        if (!sshPassword) sshPassword = document.getElementById('ssh-password')?.value;
        const sshPort = document.getElementById('ssh-port')?.value || 22;
        if (!sshTarget) { alert('Please enter SSH target (user@host)'); return; }
        if (!sshPassword) { alert('Please enter SSH password'); return; }
        updateSSHConnectionStatus('connecting', 'Connecting...');

        if (!sshTerminal && typeof Terminal !== 'undefined') {
            sshTerminal = new Terminal({ cursorBlink: true, fontSize: 14, fontFamily: 'Menlo, Monaco, "Courier New", monospace', theme: { background: '#000000', foreground: '#00ff00' }, rows: 30, cols: 100 });
            if (typeof FitAddon !== 'undefined') { sshFitAddon = new FitAddon.FitAddon(); sshTerminal.loadAddon(sshFitAddon); }
            const tc = document.getElementById('ssh-xterm-terminal');
            if (tc) { sshTerminal.open(tc); if (sshFitAddon) sshFitAddon.fit(); }
            window.addEventListener('resize', () => { if (sshFitAddon) sshFitAddon.fit(); });
        }

        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const wsUrl = protocol + '//' + window.location.host + '/admin/docker-ssh-terminal?ssh_target=' + encodeURIComponent(sshTarget) + '&ssh_port=' + sshPort + '&ssh_password=' + encodeURIComponent(sshPassword);
        sshWebSocket = new WebSocket(wsUrl);
        sshWebSocket.onopen = function() { updateSSHConnectionStatus('connected', 'Connected'); if (sshTerminal) sshTerminal.writeln('\r\n\x1b[32m✓ Connected to ' + sshTarget + '\x1b[0m\r\n'); };
        sshWebSocket.onmessage = function(event) {
            if (!sshTerminal) return;
            if (event.data instanceof Blob) { event.data.arrayBuffer().then(buffer => { sshTerminal.write(new TextDecoder().decode(buffer)); }); }
            else { sshTerminal.write(event.data); }
        };
        sshWebSocket.onerror = function() { updateSSHConnectionStatus('error', 'Connection Error'); if (sshTerminal) sshTerminal.writeln('\r\n\x1b[31m✗ Connection error\x1b[0m\r\n'); };
        sshWebSocket.onclose = function() { updateSSHConnectionStatus('disconnected', 'Disconnected'); if (sshTerminal) sshTerminal.writeln('\r\n\x1b[33m✓ Connection closed\x1b[0m\r\n'); sshWebSocket = null; };
        if (sshTerminal) sshTerminal.onData(data => { if (sshWebSocket && sshWebSocket.readyState === WebSocket.OPEN) sshWebSocket.send(data); });
    };

    window.disconnectSSHTerminal = function() { if (sshWebSocket) { sshWebSocket.close(); sshWebSocket = null; } updateSSHConnectionStatus('disconnected', 'Disconnected'); };

    window.showDeploymentCommands = function() {
        const service = document.getElementById('deploy-service-select')?.value;
        const sshTarget = document.getElementById('production-host')?.value.trim();
        const imageName = 'comserv2-' + (service || 'web-prod');
        appendOutput('\n' + '='.repeat(80) + '\n📋 MANUAL DEPLOYMENT COMMANDS\n' + '='.repeat(80) + '\nService: ' + service + '\nTarget: ' + sshTarget + '\nImage: ' + imageName + '\n');
    };

    window.deployToProduction = function(deployMode) {
        const isQuick = (deployMode === 1 || deployMode === 'quick') ? '1' : '0';
        const popup = window.open('/admin/docker/deploy_form?quick_deploy=' + isQuick, 'docker_deploy', 'width=720,height=540,resizable=yes,scrollbars=yes,toolbar=no,menubar=no,location=no,status=no');
        if (popup) { popup.focus(); window.addEventListener('message', function onMsg(e) { if (e.data && e.data.type === 'deploy_done') { window.removeEventListener('message', onMsg); alert(e.data.success ? '✅ Deploy complete — check the log for details.' : '⚠️ Deploy had errors — review the popup log before closing.'); location.reload(); } }); }
        else { alert('⚠ Popup blocked — allow popups for this site and try again.'); }
    };

    window.deployToStaging = function() {
        const popup = window.open('/admin/docker/deploy_form?target=staging-4000', 'docker_deploy', 'width=720,height=540,resizable=yes,scrollbars=yes,toolbar=no,menubar=no,location=no,status=no');
        if (popup) { popup.focus(); window.addEventListener('message', function onMsg(e) { if (e.data && e.data.type === 'deploy_done') { window.removeEventListener('message', onMsg); alert(e.data.success ? '✅ Staging deploy complete.' : '⚠️ Staging deploy had errors — review the popup log.'); location.reload(); } }); }
        else { alert('⚠ Popup blocked — allow popups for this site and try again.'); }
    };

    window.openSSHTerminal = function() {
        const sshTarget = document.getElementById('production-host')?.value.trim();
        if (!sshTarget) { alert('Please enter SSH target (user@host)'); return; }
        const terminalUrl = 'http://workstation.local:3001/?ssh=' + encodeURIComponent(sshTarget);
        const tw = window.open(terminalUrl, 'SSH Terminal - ' + sshTarget, 'width=1000,height=600,menubar=no,toolbar=no,location=no,status=no');
        if (tw) appendOutput('\n🖥️ SSH Terminal opened in new window: ' + sshTarget + '\n');
        else alert('Popup blocked! Please allow popups for this site.\n\nAlternatively, manually open: ' + terminalUrl);
    };

    // ── Event Delegation (replaces onclick handlers) ─────────────────
    document.addEventListener('click', function(e) {
        const btn = e.target.closest('[data-action]');
        if (!btn) return;
        const action = btn.getAttribute('data-action');
        const service = btn.getAttribute('data-service');

        switch (action) {
            case 'create': createContainerDirect(service); break;
            case 'start': startContainerDirect(service); break;
            case 'stop': stopContainerDirect(service); break;
            case 'restart': restartContainerDirect(service); break;
            case 'logs': viewLogsDirect(service); break;
            case 'rebuild': rebuildContainerDirect(service); break;
            case 'toggle-section':
                const sid = btn.getAttribute('data-section');
                if (sid) window.toggleSection(sid);
                break;
            case 'refresh-containers': window.refreshContainers(); break;
            case 'refresh-volumes': window.refreshVolumes(); break;
            case 'clear-output': window.clearOutput(); break;
            case 'rebuild-container': window.rebuildContainer(); break;
            case 'prune-docker': window.pruneDockerSystem(); break;
            case 'show-disk-usage': window.showDiskUsage(); break;
            case 'restart-container': window.restartContainer(); break;
            case 'view-logs': window.viewLogs(); break;
            case 'test-ssh': window.testSSHConnection(); break;
            case 'start-host-starman': window.startHostStarman(); break;
            case 'save-image': window.saveDockerImage(); break;
            case 'deploy-prod': window.deployToProduction(btn.getAttribute('data-mode') || 0); break;
            case 'deploy-staging': window.deployToStaging(); break;
            case 'show-cmds': window.showDeploymentCommands(); break;
            case 'connect-ssh': window.connectSSHTerminal(); break;
            case 'disconnect-ssh': window.disconnectSSHTerminal(); break;
            case 'open-ssh-terminal': window.openSSHTerminal(); break;
            case 'toggle-ssh-pass': window.toggleSSHTerminalPassword(); break;
            case 'toggle-pass-vis': window.togglePasswordVisibility(); break;
            case 'update-ssh-target': window.updateSSHTarget(); break;
            case 'load-history': window.loadHistoryIntoOutput(); break;
            case 'close-modal': window.closeResultModal(); break;
            case 'load-diag': window.loadDiagnostics(); break;
            case 'update-target': window.onTargetChange(); break;
            case 'copy-clipboard':
                const text = btn.getAttribute('data-text');
                if (text) window.copyToClipboard(text);
                break;
            default:
                if (window[action] && typeof window[action] === 'function') window[action](service);
        }
    });

    // ── Init ─────────────────────────────────────────────────────────
    document.addEventListener('DOMContentLoaded', function() {
        outputBox = document.getElementById('output-box');
        containersList = document.getElementById('containers-list');

        const targetSelect = document.getElementById('docker-target-select');
        const defaultTarget = targetSelect ? targetSelect.value : 'workstation';
        updateEmergencyCommands(defaultTarget);

        refreshContainers();
        // refreshVolumes() is called as part of refreshContainers now (volumes come in same response)
        loadSavedCredentials();
        loadDeployHistory();
        loadDiagnostics();
    });

})();