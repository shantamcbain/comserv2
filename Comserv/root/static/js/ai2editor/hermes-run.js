/**
 * hermes-run.js
 * "Run with Hermes (auto)" button for the AI Editor's Hermes panel.
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


        // Restore familiar dashboard iframe when possible (do not remove it)
        var iframe = document.getElementById('hermes-iframe');
        var placeholder = document.getElementById('hermes-placeholder');
        var openTab = document.getElementById('hermes-open-tab');
        var dashUrl = '';
        try {
            var qs = new URLSearchParams(window.location.search || '');
            dashUrl = qs.get('hermes') || '';
        } catch (e) {}
        if (!dashUrl && iframe && iframe.getAttribute('src')) {
            dashUrl = iframe.getAttribute('src');
        }
        if (!dashUrl) {
            // Same host as the editor (works for IP remote: 172.30.x.x:9119)
            dashUrl = window.location.protocol + '//' + window.location.hostname + ':9119/';
        }
        if (iframe && dashUrl) {
            iframe.src = dashUrl;
            iframe.style.display = 'block';
            if (placeholder) placeholder.style.display = 'none';
        }
        if (openTab && dashUrl) {
            openTab.href = dashUrl;
        }

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
        runBtn.textContent = 'Run with Hermes (auto)';
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

            callHermesRun(prompt, 'auto').then(function (data) {
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
                runBtn.textContent = 'Run with Hermes (auto)';
            }).catch(function (err) {
                console.error('[' + NS + '] hermes_run failed', err);
                errorArea.textContent = 'Request failed: ' + (err && err.message ? err.message : String(err));
                errorArea.style.display = 'block';
                statusArea.style.display = 'none';
                runBtn.disabled = false;
                runBtn.textContent = 'Run with Hermes (auto)';
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