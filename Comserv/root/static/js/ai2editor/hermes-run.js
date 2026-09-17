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
        var input = document.getElementById('ai-chat-input');
        if (input) {
            var v = (input.value || '').trim();
            if (v) return v;
        }
        // Fallback — use the active file loaded in the editor
        if (window.AI2_FILE_TO_LOAD) {
            return 'Review the current file: ' + window.AI2_FILE_TO_LOAD;
        }
        return 'Analyze the current project state and suggest what to work on.';
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

        // Skip if already wired
        if (panel.dataset.hermesRunWired === '1') return;
        panel.dataset.hermesRunWired = '1';

        // Create the button row and output area inside the Hermes panel.
        // The panel already has content from editing_widget_popup.tt — we append
        // to the inner wrapper (first child div that has padding:8px).
        var wrapper = panel.querySelector('div');
        if (!wrapper) return;

        // Remove the placeholder text / iframe area, we replace with live controls
        var placeholder = wrapper.querySelector('#hermes-placeholder');
        var iframe = wrapper.querySelector('#hermes-iframe, iframe');

        // Button row
        var btnRow = document.createElement('div');
        btnRow.style.cssText = 'display:flex;gap:6px;margin-bottom:8px;align-items:center;';

        var promptInput = document.createElement('textarea');
        promptInput.id = 'hermes-run-prompt';
        promptInput.placeholder = 'Prompt for Hermes… (default: current editor state)';
        promptInput.style.cssText = 'flex:1;background:#0f1115;color:#ddd;border:1px solid #555;border-radius:3px;padding:6px;font-size:12px;min-height:50px;resize:vertical;font-family:inherit;';

        var runBtn = document.createElement('button');
        runBtn.id = 'hermes-run-btn';
        runBtn.textContent = 'Run with Hermes (auto)';
        runBtn.style.cssText = 'background:#6a1b9a;color:#fff;border:none;padding:6px 12px;border-radius:3px;cursor:pointer;font-size:12px;white-space:nowrap;';

        btnRow.appendChild(promptInput);
        btnRow.appendChild(runBtn);
        wrapper.appendChild(btnRow);

        // Mode indicator
        var modeIndicator = document.createElement('div');
        modeIndicator.id = 'hermes-run-mode';
        modeIndicator.style.cssText = 'font-size:11px;color:#888;margin-bottom:4px;';
        wrapper.appendChild(modeIndicator);

        // Output area
        var outputBox = document.createElement('div');
        outputBox.id = 'hermes-run-output';
        outputBox.style.cssText = 'background:#0f1115;color:#c8d0dc;border:1px solid #444;border-radius:4px;padding:8px;font-size:11px;line-height:1.4;max-height:400px;overflow:auto;white-space:pre-wrap;display:none;font-family:monospace;';
        wrapper.appendChild(outputBox);

        // Dashboard URL / launch hint area (shown when mode=desktop)
        var dashArea = document.createElement('div');
        dashArea.id = 'hermes-run-dashboard';
        dashArea.style.cssText = 'font-size:11px;color:#9ecbff;margin-top:4px;display:none;';
        wrapper.appendChild(dashArea);

        // Error area
        var errorArea = document.createElement('div');
        errorArea.id = 'hermes-run-error';
        errorArea.style.cssText = 'font-size:11px;color:#f66;margin-top:4px;display:none;';
        wrapper.appendChild(errorArea);

        // Hidden status area for the thinking indicator
        var statusArea = document.createElement('div');
        statusArea.id = 'hermes-run-status';
        statusArea.style.cssText = 'font-size:11px;color:#7ec8ff;margin-top:4px;display:none;';
        wrapper.appendChild(statusArea);

        // Run handler
        function runHermes() {
            var prompt = (promptInput.value || '').trim() || getCurrentPrompt();
            if (!prompt) {
                errorArea.textContent = 'Enter a prompt first.';
                errorArea.style.display = 'block';
                return;
            }

            runBtn.disabled = true;
            runBtn.textContent = 'Running…';
            outputBox.style.display = 'none';
            errorArea.style.display = 'none';
            dashArea.style.display = 'none';
            modeIndicator.textContent = '';
            statusArea.textContent = '⏳ Probing desktop…';
            statusArea.style.display = 'block';

            callHermesRun(prompt, 'auto').then(function (data) {
                if (!data) {
                    throw new Error('Empty response from server');
                }
                if (!data.success && data.error) {
                    throw new Error(data.error);
                }

                var modeText = data.mode === 'desktop' ? '🖥️ Desktop' : '💻 CLI';
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
            // Ctrl+Enter to send from the prompt textarea
            if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
                e.preventDefault();
                runHermes();
            }
        });

        console.log('[' + NS + '] Hermes Run panel ready');
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    console.log('%c[' + NS + '] loaded', 'color:#6a1b9a');
})();