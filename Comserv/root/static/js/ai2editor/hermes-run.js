/**
 * hermes-run.js
 * "Run Hermes CLI oneshot" button for the AI Editor's Hermes panel.
 * Calls POST /ai2/hermes_run to auto-pick Desktop-vs-CLI mode.
 *
 * Rules:
 *  1) Probe Desktop: any hermes/electron desktop process OR GET configured
 *     HERMES_DASHBOARD_URL. If healthy → mode=desktop (return URL + launch hint)
 *  2) Else → mode=cli: runs hermes chat -q "<prompt>" --oneshot in the
 *     aisystem worktree root (app server never starts Electron).
 *  3) UI shows which mode was used.
 *
 * Loaded from js_load.tt for /ai2/editing_widget_popup route.
 */
(function () {
    'use strict';

    const NS = 'AI2HermesRun';

    function escapeHtml(s) {
        return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }

    /**
     * Call the backend /ai2/hermes_run endpoint.
     * @param {string} prompt - The user prompt to send
     * @param {string} prefer - "auto" | "desktop" | "cli"
     * @returns {Promise<object>} Parsed JSON response
     */
    function callHermesRun(prompt, prefer) {
        return fetch('/ai2/hermes_run', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ prompt: prompt, prefer: prefer || 'auto' }),
            credentials: 'include'
        }).then(function (res) {
            return res.json();
        });
    }

    /**
     * Get the current prompt from the editor's chat input, or a fallback.
     */
    function getCurrentPrompt() {
        // Prefer Hermes panel textarea, then main AI editor chat input, then context
        var hermesTa = document.getElementById('hermes-run-prompt');
        if (hermesTa) {
            var hv = (hermesTa.value || '').trim();
            if (hv) return hv;
        }
        var candidates = [
            'ai-chat-input',
            'ai2-chat-input',
            'chat-input',
            'editor-chat-input'
        ];
        for (var i = 0; i < candidates.length; i++) {
            var input = document.getElementById(candidates[i]);
            if (input) {
                var v = (input.value || input.textContent || '').trim();
                if (v) return v;
            }
        }
        var sel = '';
        try { sel = String(window.getSelection && window.getSelection() || '').trim(); } catch (e) {}
        if (sel) return sel;
        if (window.AI2_FILE_TO_LOAD) {
            return 'Review the current file: ' + window.AI2_FILE_TO_LOAD;
        }
        return '';
    }

    /**
     * Initialize the "Run with Hermes" button and output area in the Hermes panel.
     */
    function init() {
        var panel = document.getElementById('panel-hermes');
        if (!panel) {
            console.warn('[' + NS + '] Hermes panel not found');
            return;
        }
        if (panel.dataset.hermesRunWired === '1') return;
        panel.dataset.hermesRunWired = '1';

        var copyBtn = document.getElementById('hermes-copy-cmd');
        var cmdEl = document.getElementById('hermes-terminal-cmd');
        if (copyBtn && cmdEl) {
            copyBtn.addEventListener('click', function () {
                var cmd = (cmdEl.textContent || '').trim();
                if (navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(cmd).then(function () {
                        copyBtn.textContent = 'Copied';
                        setTimeout(function () { copyBtn.textContent = 'Copy terminal command'; }, 1500);
                    }).catch(function () {
                        copyBtn.textContent = 'Select & copy manually';
                    });
                } else {
                    copyBtn.textContent = 'Select & copy manually';
                }
            });
        }

        var startDesk = document.getElementById('hermes-start-desktop');
        var deskStatus = document.getElementById('hermes-desktop-status');
        if (startDesk) {
            startDesk.addEventListener('click', function () {
                startDesk.disabled = true;
                startDesk.textContent = 'Starting…';
                if (deskStatus) {
                    deskStatus.style.display = 'block';
                    deskStatus.style.color = '#7ec8ff';
                    deskStatus.textContent = 'Optional: starting Electron Desktop (not the browser dashboard)…';
                }
                fetch('/ai2/hermes_start_desktop', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
                    body: '{}',
                    credentials: 'include'
                }).then(function (res) {
                    return res.text().then(function (txt) {
                        var data;
                        try { data = JSON.parse(txt); }
                        catch (e) {
                            throw new Error('Start Desktop needs /ai2/hermes_start_desktop (use :4006 or restart :3001). Got HTTP ' + res.status + ' non-JSON');
                        }
                        if (!res.ok && data && data.error) throw new Error(data.error);
                        return data;
                    });
                }).then(function (data) {
                    startDesk.disabled = false;
                    startDesk.textContent = 'Start Hermes Desktop (aisystem)';
                    if (!deskStatus) return;
                    deskStatus.style.display = 'block';
                    if (!data || !data.success) {
                        deskStatus.style.color = '#f66';
                        deskStatus.textContent = (data && data.error) ? data.error : 'Start failed';
                        return;
                    }
                    deskStatus.style.color = '#9ecbff';
                    var lines = [];
                    lines.push(data.message || 'OK');
                    if (data.cwd) lines.push('cwd: ' + data.cwd);
                    if (data.already) lines.push('(already running)');
                    if (data.note) lines.push(data.note);
                    if (data.launch_hint) lines.push('hint: ' + data.launch_hint);
                    deskStatus.textContent = lines.join('\n');
                }).catch(function (err) {
                    startDesk.disabled = false;
                    startDesk.textContent = 'Start Hermes Desktop (aisystem)';
                    if (deskStatus) {
                        deskStatus.style.display = 'block';
                        deskStatus.style.color = '#f66';
                        deskStatus.textContent = 'Request failed: ' + (err && err.message ? err.message : String(err));
                    }
                });
            });
        }



        // Restore familiar dashboard iframe when possible (do not remove it)
        var iframe = document.getElementById('hermes-iframe');
        var placeholder = document.getElementById('hermes-placeholder');
        var openTab = document.getElementById('hermes-open-tab');
        var frameWrap = document.getElementById('hermes-frame-wrap');
        var dashUrl = '';
        try {
            var qs = new URLSearchParams(window.location.search || '');
            dashUrl = qs.get('hermes') || '';
        } catch (e) {}
        if (!dashUrl && iframe && iframe.getAttribute('src')) {
            dashUrl = iframe.getAttribute('src');
        }
        if (!dashUrl) {
            // Same host as the editor (localhost or ZeroTier IP): Hermes dashboard sessions
            dashUrl = window.location.protocol + '//' + window.location.hostname + ':9119/sessions';
        }
        function applyDashUrl(u) {
            dashUrl = u;
            if (iframe) {
                iframe.src = u;
                iframe.style.display = 'block';
            }
            if (frameWrap) frameWrap.style.display = 'block';
            if (placeholder) placeholder.style.display = 'none';
            if (openTab) openTab.href = u;
        }
        if (iframe && dashUrl) applyDashUrl(dashUrl);
        if (openTab && dashUrl) openTab.href = dashUrl;

        // Height: persist + taller/shorter + drag
        var HEIGHT_KEY = 'ai2-hermes-iframe-h';
        function clampH(h) {
            h = parseInt(h, 10);
            if (!h || isNaN(h)) h = Math.min(window.innerHeight * 0.7, 720);
            return Math.max(280, Math.min(1200, h));
        }
        function setFrameHeight(px) {
            if (!frameWrap) return;
            var h = clampH(px);
            frameWrap.style.height = h + 'px';
            frameWrap.style.minHeight = Math.min(h, 420) + 'px';
            try { sessionStorage.setItem(HEIGHT_KEY, String(h)); } catch (e) {}
        }
        try {
            var savedH = sessionStorage.getItem(HEIGHT_KEY);
            if (savedH) setFrameHeight(savedH);
        } catch (e) {}
        var taller = document.getElementById('hermes-taller');
        var shorter = document.getElementById('hermes-shorter');
        if (taller) taller.addEventListener('click', function () {
            var cur = frameWrap ? (parseInt(frameWrap.style.height, 10) || frameWrap.offsetHeight || 520) : 520;
            setFrameHeight(cur + 80);
        });
        if (shorter) shorter.addEventListener('click', function () {
            var cur = frameWrap ? (parseInt(frameWrap.style.height, 10) || frameWrap.offsetHeight || 520) : 520;
            setFrameHeight(cur - 80);
        });
        var resizeBar = document.getElementById('hermes-iframe-resize');
        if (resizeBar && frameWrap) {
            var dragging = false;
            var startY = 0;
            var startH = 0;
            resizeBar.addEventListener('mousedown', function (e) {
                dragging = true;
                startY = e.clientY;
                startH = frameWrap.offsetHeight || 520;
                e.preventDefault();
                document.body.style.userSelect = 'none';
            });
            document.addEventListener('mousemove', function (e) {
                if (!dragging) return;
                setFrameHeight(startH + (e.clientY - startY));
            });
            document.addEventListener('mouseup', function () {
                if (!dragging) return;
                dragging = false;
                document.body.style.userSelect = '';
            });
        }

        // Detach / Attach (popup window)
        var detachBtn = document.getElementById('hermes-detach');
        var _detachWin = null;
        var _detachPoll = null;
        var _detached = false;
        function setDetachLabel(detached) {
            if (!detachBtn) return;
            detachBtn.textContent = detached ? '⊞ Attach' : '⤢ Detach';
            detachBtn.title = detached
                ? 'Close detached window and show Hermes in the editor'
                : 'Open Hermes dashboard in its own window';
        }
        function closeHermesPanel() {
            if (window.AI2Sidebar && typeof window.AI2Sidebar.closePanel === 'function') {
                window.AI2Sidebar.closePanel('hermes');
                return;
            }
            var icon = document.querySelector('#sidebar-icons .sidebar-icon[data-panel="hermes"]');
            if (icon && icon.classList.contains('active')) icon.click();
        }
        function openHermesPanel() {
            if (window.AI2Sidebar && typeof window.AI2Sidebar.openPanel === 'function') {
                window.AI2Sidebar.openPanel('hermes');
                return;
            }
            var icon = document.querySelector('#sidebar-icons .sidebar-icon[data-panel="hermes"]');
            if (icon && !icon.classList.contains('active')) icon.click();
        }
        function clearDetach() {
            _detached = false;
            _detachWin = null;
            if (_detachPoll) { clearInterval(_detachPoll); _detachPoll = null; }
            setDetachLabel(false);
        }
        if (detachBtn) {
            detachBtn.addEventListener('click', function () {
                if (_detached) {
                    if (_detachWin && !_detachWin.closed) {
                        try { _detachWin.close(); } catch (e) {}
                    }
                    clearDetach();
                    openHermesPanel();
                    return;
                }
                var u = dashUrl || (window.location.protocol + '//' + window.location.hostname + ':9119/sessions');
                var w = null;
                try {
                    w = window.open(u, 'AI2HermesDetach', 'width=1280,height=900,left=40,top=20,resizable=yes,scrollbars=yes');
                } catch (e) {
                    console.error('[' + NS + '] detach blocked', e);
                    return;
                }
                if (!w) {
                    console.warn('[' + NS + '] popup blocked');
                    return;
                }
                _detachWin = w;
                _detached = true;
                setDetachLabel(true);
                closeHermesPanel();
                if (_detachPoll) clearInterval(_detachPoll);
                _detachPoll = setInterval(function () {
                    if (!_detachWin || _detachWin.closed) clearDetach();
                }, 700);
                try { w.focus(); } catch (e2) {}
            });
        }

        // Primary action: show dashboard (never Electron login)
        var reloadDash = document.getElementById('hermes-reload-dashboard');
        if (!reloadDash) {
            reloadDash = document.createElement('button');
            reloadDash.id = 'hermes-reload-dashboard';
            reloadDash.type = 'button';
            reloadDash.textContent = 'Load dashboard /sessions';
            reloadDash.style.cssText = 'background:#1565c0;color:#fff;border:none;padding:6px 10px;border-radius:3px;cursor:pointer;font-size:12px;margin:6px 0;';
            var ph = document.getElementById('hermes-placeholder') || iframe;
            if (ph && ph.parentNode) ph.parentNode.insertBefore(reloadDash, ph);
        }
        reloadDash.onclick = function () {
            var u = window.location.protocol + '//' + window.location.hostname + ':9119/sessions';
            applyDashUrl(u);
        };


        var mount = document.getElementById('hermes-run-section');
        if (!mount) {
            // Fallback: append under panel wrapper
            mount = panel.querySelector('div') || panel;
        }

        var btnRow = document.createElement('div');
        btnRow.style.cssText = 'display:flex;gap:6px;margin-bottom:8px;align-items:flex-start;';

        var promptInput = document.createElement('textarea');
        promptInput.id = 'hermes-run-prompt';
        promptInput.placeholder = 'Prompt for Hermes CLI oneshot…';
        promptInput.style.cssText = 'flex:1;background:#0f1115;color:#ddd;border:1px solid #555;border-radius:3px;padding:6px;font-size:12px;min-height:50px;resize:vertical;font-family:inherit;';

        var runBtn = document.createElement('button');
        runBtn.id = 'hermes-run-btn';
        runBtn.textContent = 'Run Hermes CLI oneshot';
        runBtn.style.cssText = 'background:#6a1b9a;color:#fff;border:none;padding:6px 12px;border-radius:3px;cursor:pointer;font-size:12px;white-space:nowrap;';

        btnRow.appendChild(promptInput);
        btnRow.appendChild(runBtn);
        mount.appendChild(btnRow);

        var modeIndicator = document.createElement('div');
        modeIndicator.id = 'hermes-run-mode';
        modeIndicator.style.cssText = 'font-size:11px;color:#888;margin-bottom:4px;';
        mount.appendChild(modeIndicator);

        var outputBox = document.createElement('div');
        outputBox.id = 'hermes-run-output';
        outputBox.style.cssText = 'background:#0f1115;color:#c8d0dc;border:1px solid #444;border-radius:4px;padding:8px;font-size:11px;line-height:1.4;max-height:280px;overflow:auto;white-space:pre-wrap;display:none;font-family:monospace;';
        mount.appendChild(outputBox);

        var dashArea = document.createElement('div');
        dashArea.id = 'hermes-run-dashboard';
        dashArea.style.cssText = 'font-size:11px;color:#9ecbff;margin-top:4px;display:none;';
        mount.appendChild(dashArea);

        var errorArea = document.createElement('div');
        errorArea.id = 'hermes-run-error';
        errorArea.style.cssText = 'font-size:11px;color:#f66;margin-top:4px;display:none;';
        mount.appendChild(errorArea);

        var statusArea = document.createElement('div');
        statusArea.id = 'hermes-run-status';
        statusArea.style.cssText = 'font-size:11px;color:#7ec8ff;margin-top:4px;display:none;';
        mount.appendChild(statusArea);

        function runHermes() {
            var prompt = (promptInput.value || '').trim() || getCurrentPrompt();
            if (!prompt) {
                errorArea.textContent = 'Enter a prompt in the Hermes box (or the editor chat input) first.';
                errorArea.style.display = 'block';
                return;
            }
            if (!(promptInput.value || '').trim()) {
                promptInput.value = prompt;
            }

            runBtn.disabled = true;
            runBtn.textContent = 'Running…';
            outputBox.style.display = 'none';
            errorArea.style.display = 'none';
            dashArea.style.display = 'none';
            modeIndicator.textContent = '';
            statusArea.textContent = 'Probing desktop / starting CLI…';
            statusArea.style.display = 'block';

            callHermesRun(prompt, 'cli').then(function (data) {
                if (!data) throw new Error('Empty response from server');
                if (!data.success && data.error) throw new Error(data.error);

                var modeText = data.mode === 'desktop' ? 'Desktop' : 'CLI';
                modeIndicator.textContent = 'Mode: ' + modeText + ' — ' + (data.message || '');

                if (data.mode === 'desktop') {
                    dashArea.style.display = 'block';
                    var html = 'Dashboard: <a href="' + escapeHtml(data.dashboard_url || '') + '" target="_blank" style="color:#7ec8ff;">' + escapeHtml(data.dashboard_url || '') + '</a>';
                    if (data.launch_hint) {
                        html += '<br>Launch: <code style="background:#252830;padding:1px 4px;border-radius:2px;">' + escapeHtml(data.launch_hint) + '</code>';
                    }
                    dashArea.innerHTML = html;
                }

                if (data.output) {
                    outputBox.textContent = data.output;
                    outputBox.style.display = 'block';
                } else if (data.mode === 'cli' && !data.error) {
                    outputBox.textContent = '(hermes chat completed with no visible output)';
                    outputBox.style.display = 'block';
                }

                if (data.error) {
                    errorArea.textContent = 'Error: ' + data.error;
                    errorArea.style.display = 'block';
                }

                statusArea.style.display = 'none';
                runBtn.disabled = false;
                runBtn.textContent = 'Run Hermes CLI oneshot';
            }).catch(function (err) {
                console.error('[' + NS + '] hermes_run failed', err);
                errorArea.textContent = 'Request failed: ' + (err && err.message ? err.message : String(err));
                errorArea.style.display = 'block';
                statusArea.style.display = 'none';
                runBtn.disabled = false;
                runBtn.textContent = 'Run Hermes CLI oneshot';
            });
        }

        runBtn.addEventListener('click', runHermes);
        promptInput.addEventListener('keydown', function (e) {
            if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
                e.preventDefault();
                runHermes();
            }
        });

        console.log('[' + NS + '] Hermes Dashboard + Run panel ready; iframe=' + dashUrl);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    console.log('%c[' + NS + '] loaded', 'color:#6a1b9a');
})();