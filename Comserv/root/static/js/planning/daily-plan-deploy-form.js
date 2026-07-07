/**
 * planning/daily-plan-deploy-form.js
 * Deployment form handler for /admin/docker/deploy_form page
 * Extracted from inline JS in deploy_form.tt — follows js_load.tt modular JS rules
 */

(function() {
    'use strict';

    var logId         = null;
    var logOutput     = '';
    var todoRecordId  = (new URLSearchParams(window.location.search)).get('todo_record_id') || '';
    var autoTarget    = (new URLSearchParams(window.location.search)).get('target') || '';
    var pollingTimer  = null;
    var lastContent   = '';
    var consecutiveErrors = 0;
    var chosenTarget  = null;

    var con = document.getElementById('console');

    function getParam(name) {
        return (new URLSearchParams(window.location.search)).get(name) || '';
    }

    // Append a single line of text to the console. Never clears existing content.
    function appendLine(text, cls) {
        if (!con) return;
        var el = cls
            ? (function() { var s = document.createElement('span'); s.className = cls; s.textContent = text + '\n'; return s; })()
            : document.createTextNode((text || '') + '\n');
        con.appendChild(el);
        con.scrollTop = con.scrollHeight;
    }

    // Append any NEW lines from the full log output (incremental, no full-replace)
    function appendNewOutput(fullOutput) {
        if (!fullOutput) return false;
        if (fullOutput === lastContent) return false;
        // Determine the new portion: everything after the last known length
        var knownLen = lastContent.length;
        if (fullOutput.length > knownLen) {
            var newChunk = fullOutput.substring(knownLen);
            if (newChunk) {
                con.appendChild(document.createTextNode(newChunk));
                // Always scroll to bottom on new content
                con.scrollTop = con.scrollHeight;
                window.scrollTo(0, document.body.scrollHeight);
            }
        }
        lastContent = fullOutput;
        logOutput = fullOutput;
        return true;
    }

    function setStatus(state, text) {
        var badge = document.getElementById('status-badge');
        if (!badge) return;
        badge.className = state;
        badge.innerHTML = (state === 'running' ? '<span id="spinner"></span> ' : '') + text;
        var footer = document.getElementById('footer');
        if (footer) {
            var statusEl = document.getElementById('deploy-status-msg');
            if (!statusEl) {
                statusEl = document.createElement('span');
                statusEl.id = 'deploy-status-msg';
                statusEl.style.cssText = 'font-size:0.85em;color:var(--primary-color,#58a6ff);margin-left:auto;';
                footer.insertBefore(statusEl, footer.firstChild);
            }
            statusEl.textContent = state === 'running' ? '⏳ Deploy running...' : (state === 'success' ? '✅ Complete' : '❌ Failed');
        }
    }

    function safeFetch(url, options) {
        var opts = Object.assign({ credentials: 'same-origin', redirect: 'manual' }, options || {});
        return fetch(url, opts).then(function(response) {
            if (response.type === 'opaqueredirect' || response.status === 0 ||
                (response.status >= 300 && response.status < 400)) {
                appendLine('✗ Session expired — reload and log in again.', 'err');
                return Promise.reject(new Error('session-expired'));
            }
            if (!response.ok) {
                appendLine('✗ Server error (HTTP ' + response.status + ')', 'err');
                return Promise.reject(new Error('HTTP ' + response.status));
            }
            return response;
        });
    }

    function startPolling() {
        if (pollingTimer) clearInterval(pollingTimer);
        lastContent = '';
        pollingTimer = setInterval(function() {
            safeFetch('/admin/docker-deploy-status')
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    if (data.success) {
                        consecutiveErrors = 0;
                        // Incrementally append new content — never clear/replace
                        appendNewOutput(data.output || '');
                        if (!data.is_running) {
                            clearInterval(pollingTimer);
                            pollingTimer = null;
                            setStatus('success', '✅ Done');
                            appendLine('', null);
                            appendLine('='.repeat(60), 'ok');
                            appendLine('✅ DEPLOYMENT FINISHED', 'ok');
                            appendLine('='.repeat(60), 'ok');
                            var closeBtn = document.getElementById('btn-close');
                            if (closeBtn) closeBtn.disabled = false;
                            var viewBtn = document.getElementById('btn-view');
                            if (viewBtn && logId) {
                                viewBtn.href = '/log/details?record_id=' + logId;
                            }
                            if (window.opener && window.opener.postMessage) {
                                window.opener.postMessage({ type: 'deploy_done', success: 1 }, '*');
                            }
                            appendLine('📋 Click "Close & Save Log" to save this log permanently.', 'info');
                        }
                    }
                })
                .catch(function(e) {
                    if (e.message !== 'session-expired') {
                        appendLine('Polling error: ' + e.message, 'err');
                        consecutiveErrors++;
                    }
                });
        }, 1500);  // 1.5s interval — lighter on server, still live
    }

    function startDeploy(target) {
        chosenTarget = target;
        document.getElementById('choice-screen').style.display = 'none';
        document.getElementById('console').style.display = 'block';
        document.getElementById('footer').style.display = 'flex';

        setStatus('running', 'Deploying to ' + target + '…');

        safeFetch('/admin/docker/init_log', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: todoRecordId ? 'todo_record_id=' + encodeURIComponent(todoRecordId) : ''
        })
        .then(function(r) { return r.json(); })
        .then(function(d) {
            if (d.success) logId = d.log_id;
            appendLine('[' + new Date().toLocaleTimeString() + '] Log created — starting deploy to ' + target + '…', 'info');

            var bodyParams = 'target=' + encodeURIComponent(target)
                         + '&trigger_source=DailyPlan-popup';
            if (todoRecordId) bodyParams += '&todo_record_id=' + encodeURIComponent(todoRecordId);

            return safeFetch('/admin/docker-deploy-to-production', {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: bodyParams
            });
        })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            if (data.success) {
                appendLine('Background deploy process started for ' + target + '.', 'ok');
                if (data.message) {
                    appendLine('[deploy] ' + data.message, 'info');
                }
                appendLine('Streaming output…', 'info');
                startPolling();
            } else {
                appendLine('❌ Failed to start deploy: ' + (data.error || 'unknown error'), 'err');
                setStatus('error', '❌ Failed');
                var closeBtn = document.getElementById('btn-close');
                if (closeBtn) closeBtn.disabled = false;
            }
        });
    }

    function cancelDeploy() {
        window.close();
    }

    function cancelAndSave() {
        if (confirm("Are you sure you want to abort?")) {
            if (pollingTimer) { clearInterval(pollingTimer); pollingTimer = null; }
            appendLine('\n🛑 DEPLOYMENT ABORTED/CANCELLED BY USER', 'err');
            setStatus('error', '🛑 Aborted');
            closeLog();
        }
    }

    function closeLog() {
        var notes    = (document.getElementById('notes') || {}).value || '';
        var closeBtn = document.getElementById('btn-close');
        if (closeBtn) { closeBtn.disabled = true; closeBtn.textContent = 'Saving…'; }

        var body = 'log_id='  + encodeURIComponent(logId || '')
                 + '&output=' + encodeURIComponent(logOutput)
                 + '&notes='  + encodeURIComponent(notes);

        fetch('/admin/docker/close_deploy_log', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: body
        })
        .then(function(r) { return r.json(); })
        .then(function(d) {
            appendLine('', null);
            appendLine(d.success ? '📋 Log saved and closed.' : '⚠ Log save error: ' + d.message,
                       d.success ? 'ok' : 'err');
            setTimeout(function() { window.close(); }, 1200);
        })
        .catch(function() {
            appendLine('⚠ Could not save log — closing anyway.', 'err');
            setTimeout(function() { window.close(); }, 1200);
        });
    }

    // === Data-attribute event delegation (no inline onclick) ===
    document.addEventListener('click', function(e) {
        var target = e.target.closest('[data-action]');
        if (!target) return;
        var action = target.getAttribute('data-action');
        if (action === 'start-deploy') {
            e.preventDefault();
            startDeploy(target.getAttribute('data-target'));
        } else if (action === 'cancel-deploy') {
            e.preventDefault();
            cancelDeploy();
        } else if (action === 'abort-save') {
            e.preventDefault();
            cancelAndSave();
        } else if (action === 'close-save') {
            e.preventDefault();
            closeLog();
        }
    });

    // Auto-start if target was passed in URL (e.g. from Deploy Local 4000 button)
    if (autoTarget) {
        startDeploy(autoTarget);
    }
})();