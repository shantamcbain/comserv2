/**
 * ai2editor/chat.js
 * Wires the AI2 editor popup's right-hand chat sidebar to /ai2/chat and
 * turns the AI's code suggestion into an Approve/Reject diff pane.
 *
 * Flow:
 *   1. User types a prompt about the open file -> Send.
 *   2. We POST to /ai2/chat with the current file path + content.
 *   3. AI response is rendered in #chat-messages.
 *   4. If the response contains a fenced code block, we surface it in the
 *      #ai-diff-pane as a suggestion with Approve / Reject.
 *   5. Approve applies the suggestion to the Ace editor and saves via
 *      /ai2/save_file. Reject discards the suggestion (editor untouched).
 *
 * No inline JS in templates; loaded from js_load.tt for /ai2/editing_widget_popup.
 */

(function () {
    'use strict';

    // Mark this page as AI Editor so Chat-with-AI Apply Fix / coding paths stay off elsewhere.
    try { window.AI2_EDITOR = true; } catch (e) { /* ignore */ }


    const NS = 'AI2EditorChat';
    let _activeFile = '';

    function getEditor() {
        if (typeof ace === 'undefined') return null;
        const el = document.getElementById('ace-editor');
        if (!el) return null;
        try {
            return ace.edit('ace-editor');
        } catch (e) {
            return null;
        }
    }

    function currentFilePath() {
        if (window.AI2_FILE_TO_LOAD) return window.AI2_FILE_TO_LOAD;
        if (_activeFile) return _activeFile;
        // The popup is opened with ?file=<rel_path>; that is the editable path.
        try {
            const p = new URLSearchParams(window.location.search).get('file');
            if (p) return p;
        } catch (e) { /* ignore */ }
        return '';
    }

    // Returns context distinguishing the *open editable file* from the *current page / endpoint*.
    // Important: the file clicked to open AI Editor is often the page itself, but not always
    // (e.g. error on page X, open editor from page Y to fix X; error message usually provided).
    function getEditorContext() {
        const openFile = currentFilePath();
        let currentPage = '';
        try {
            currentPage = window.location.pathname || '';
            // If opened from a different surface, try referer as hint
            if (!currentPage || currentPage.includes('/ai2/')) {
                const ref = document.referrer ? new URL(document.referrer).pathname : '';
                if (ref && !ref.includes('/ai2/')) currentPage = ref;
            }
        } catch (e) {}
        return { openFile, currentPage, pageVsFileDiffer: !!(openFile && currentPage && openFile.toLowerCase() !== currentPage.toLowerCase()) };
    }

    function setActiveFile(path) {
        _activeFile = path || '';
        if (path) window.AI2_FILE_TO_LOAD = path;
    }

    // Stub for early preload called from core openFile.
    // Beefs up auto-pipeline: pre-fetches related controller(s) so they are ready when chat starts.
    // Uses the strengthened infer that handles open-file vs page and errors.
    async function preloadRelatedPipeline(path, extraHint = '') {
        try {
            const paths = await inferRelatedPipelineFiles(path, extraHint);
            // Fire the loads so cache / network is warm; chat will re-use via filesP later
            await Promise.all(paths.map(p => fetchLoadFile(p).catch(() => null)));
            console.log('[AI2Chat] preloaded pipeline for', path, paths);
        } catch (e) { /* non-fatal */ }
    }

    function escapeHtml(s) {
        return String(s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;');
    }

    // Extract the first fenced code block from an AI response.
    // Returns { lang, code } or null.
    function extractCodeBlock(text) {
        if (!text) return null;
        const fence = text.match(/```([a-zA-Z0-9_+#.-]*)\n([\s\S]*?)```/);
        if (fence) {
            return { lang: fence[1] || '', code: fence[2].replace(/\n$/, '') };
        }
        return null;
    }

    function appendMessageTo(box, who, html) {
        if (!box) return;
        const div = document.createElement('div');
        div.style.marginBottom = '8px';
        div.innerHTML = '<strong>' + (who === 'AI' ? 'AI:' : 'You:') + '</strong> ' + html;
        box.appendChild(div);
        box.scrollTop = box.scrollHeight;
    }

    // Last AI message text (stripped of HTML) — used to prefill the "Add Todo" form.
    function lastAiText() {
        for (let i = chatLog.length - 1; i >= 0; i--) {
            if (chatLog[i].who === 'AI') {
                const tmp = document.createElement('div');
                tmp.innerHTML = chatLog[i].html;
                return (tmp.textContent || '').trim();
            }
        }
        return '';
    }

    // Back-compat alias for the in-editor (main) chat.
    function appendMessage(who, html) {
        appendMessageTo(document.getElementById('chat-messages'), who, html);
    }

    // --- Resize the chat sidebar by dragging its left edge ---
    function initResize() {
        const sidebar = document.getElementById('ai-chat-sidebar');
        const handle = document.getElementById('ai-chat-resize');
        if (!sidebar || !handle) return;
        let startX = 0, startW = 0, dragging = false;
        handle.addEventListener('mousedown', function (e) {
            dragging = true;
            startX = e.clientX;
            startW = sidebar.offsetWidth;
            document.body.style.cursor = 'col-resize';
            e.preventDefault();
        });
        document.addEventListener('mousemove', function (e) {
            if (!dragging) return;
            const delta = startX - e.clientX;   // drag left => wider
            const newW = Math.max(220, Math.min(window.innerWidth * 0.7, startW + delta));
            sidebar.style.setProperty('--ai-chat-w', newW + 'px');
        });
        document.addEventListener('mouseup', function () {
            if (dragging) { dragging = false; document.body.style.cursor = ''; }
        });
    }

    // --- Shared chat log: the conversation is ONE logical chat, whether the
    //     panel is attached to the editor or detached into its own window.
    //     We keep the messages in memory and re-render whichever view is active,
    //     so detaching/reattaching never loses context. ---
    let chatLog = [];   // [{who:'You'|'AI'|'Think', html?, summary?, steps?, open?, done?}]

        function ensureEditorChatContrast(doc) {
        doc = doc || document;
        if (!doc || !doc.head) return;
        if (doc.getElementById('ai2-editor-chat-contrast-css')) {
            // Allow upgrades after deploy: replace contents
            var existing = doc.getElementById('ai2-editor-chat-contrast-css');
            if (existing && existing.getAttribute('data-v') === '2') return;
            if (existing) existing.remove();
        }
        const style = doc.createElement('style');
        style.id = 'ai2-editor-chat-contrast-css';
        style.setAttribute('data-v', '2');
        style.textContent = [
            '#ai-chat-sidebar{background:#1e1f22!important;color:#f2f2f2!important;display:flex!important;flex-direction:column!important;min-height:0!important;}',
            '#ai-chat-sidebar .chat-messages,#ai-chat-sidebar #chat-messages{flex:1 1 auto!important;min-height:0!important;background:#1a1b1e!important;color:#f2f2f2!important;font-size:13px!important;line-height:1.45!important;}',
            '#ai-chat-sidebar .chat-msg{margin-bottom:10px;padding:8px 10px;border-radius:6px;border:1px solid #3a3f4a;color:#f2f2f2!important;word-break:break-word;overflow-wrap:anywhere;}',
            '#ai-chat-sidebar .chat-msg-you{background:#243044!important;border-color:#3d5a80;}',
            '#ai-chat-sidebar .chat-msg-ai{background:#252830!important;border-color:#4a5568;}',
            '#ai-chat-sidebar .chat-msg strong{color:#9ecbff!important;}',
            '#ai-chat-sidebar .chat-msg-you strong{color:#ffd27a!important;}',
            '#ai-chat-sidebar .chat-msg pre,#ai-chat-sidebar .chat-msg code{background:#0f1115!important;color:#e6edf3!important;border:1px solid #333;border-radius:4px;padding:6px 8px;display:block;white-space:pre-wrap;font-size:12px!important;max-height:280px;overflow:auto;}',
            '#ai-chat-sidebar .ai2-chat-input-row{flex:0 0 auto!important;display:flex!important;flex-direction:row!important;align-items:flex-end!important;gap:6px!important;padding:8px!important;border-top:1px solid #555!important;background:#1e1f22!important;width:100%!important;box-sizing:border-box!important;}',
            '#ai-chat-sidebar #ai-chat-input{flex:1 1 auto!important;min-width:0!important;min-height:36px!important;max-height:120px!important;background:#0f1115!important;color:#f2f2f2!important;border:1px solid #555!important;border-radius:3px!important;padding:8px!important;font-size:13px!important;box-sizing:border-box!important;}',
            '#ai-chat-sidebar #ai-chat-input::placeholder{color:#9aa3b2!important;opacity:1!important;}',
            /* neutralize leaked widget class if still present */
            '#ai-chat-sidebar .chat-input{flex:0 0 auto!important;display:flex!important;flex-direction:row!important;align-items:flex-end!important;background:#1e1f22!important;}'
        ].join('');
        doc.head.appendChild(style);
    }

function ensureThinkingStyles(doc) {
        doc = doc || document;
        if (!doc || !doc.head) return;
        if (doc.getElementById('ai2-editor-thinking-css')) return;
        const style = doc.createElement('style');
        style.id = 'ai2-editor-thinking-css';
        style.textContent = [
            '.ai-thinking{margin:8px 0;border:1px solid #4a5568;border-radius:6px;background:#252830;color:#c8d0dc;font-size:12px;}',
            '.ai-thinking summary{cursor:pointer;padding:6px 10px;list-style:none;font-weight:600;color:#9ecbff;}',
            '.ai-thinking summary::-webkit-details-marker{display:none;}',
            '.ai-thinking summary::before{content:"▸ ";display:inline-block;transition:transform .1s;}',
            '.ai-thinking[open] summary::before{transform:rotate(90deg);}',
            '.ai-thinking-body{padding:4px 10px 8px;border-top:1px solid #3a4150;}',
            '.ai-thinking-step{padding:4px 0;border-bottom:1px solid #333842;white-space:pre-wrap;line-height:1.35;}',
            '.ai-thinking-step:last-child{border-bottom:none;}',
            '.ai-thinking-live{border-color:#0e639c;box-shadow:0 0 0 1px rgba(14,99,156,.35);}',
            '.ai-thinking-live summary{color:#7ec8ff;}'
        ].join('');
        doc.head.appendChild(style);
    }

    function autosizePrompt(el) {
        if (!el || !el.style) return;
        el.style.height = 'auto';
        const max = 200;
        const next = Math.min(Math.max(el.scrollHeight, 32), max);
        el.style.height = next + 'px';
        el.style.overflowY = (el.scrollHeight > max) ? 'auto' : 'hidden';
    }

    function wirePromptBox(el, onSend) {
        if (!el || el._ai2PromptWired) return;
        el._ai2PromptWired = true;
        autosizePrompt(el);
        el.addEventListener('input', function () { autosizePrompt(el); });
        el.addEventListener('keydown', function (e) {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                if (typeof onSend === 'function') onSend();
            }
        });
    }

    function refreshChatViews() {
        const attachedBox = document.getElementById('chat-messages');
        if (attachedBox && sidebarAttached()) renderChatLog(attachedBox);
        const w = window._aiChatWin;
        if (w && !w.closed) {
            const dBox = w.document.getElementById('chat-messages');
            if (dBox) renderChatLog(dBox);
        }
    }

    function renderChatLog(box) {
        if (!box) return;
        ensureThinkingStyles(box.ownerDocument || document);
        ensureEditorChatContrast(box.ownerDocument || document);
        box.innerHTML = '';
        if (!chatLog.length) {
            box.innerHTML = '<div class="chat-msg chat-msg-ai"><strong>AI:</strong> How can I help with this file?</div>';
            return;
        }
        for (let i = 0; i < chatLog.length; i++) {
            const e = chatLog[i];
            if (e.who === 'Think') {
                const details = document.createElement('details');
                details.className = 'ai-thinking' + (e.done ? '' : ' ai-thinking-live');
                details.open = e.open !== false;
                if (e.id) details.dataset.thinkId = e.id;
                const summary = document.createElement('summary');
                summary.textContent = e.summary || 'AI thinking…';
                const body = document.createElement('div');
                body.className = 'ai-thinking-body';
                (e.steps || []).forEach(function (step) {
                    const stepEl = document.createElement('div');
                    stepEl.className = 'ai-thinking-step';
                    stepEl.textContent = step;
                    body.appendChild(stepEl);
                });
                details.appendChild(summary);
                details.appendChild(body);
                box.appendChild(details);
                continue;
            }
            const div = document.createElement('div');
            div.className = 'chat-msg ' + (e.who === 'AI' ? 'chat-msg-ai' : 'chat-msg-you');
            div.innerHTML = '<strong>' + (e.who === 'AI' ? 'AI:' : 'You:') + '</strong> ' + e.html;
            box.appendChild(div);
        }
        box.scrollTop = box.scrollHeight;
    }

    // The single place a message is recorded + shown in whichever view is live.
    function recordMessage(who, html) {
        chatLog.push({ who: who, html: html });
        refreshChatViews();
    }

    // Build conversation history for the model — strips HTML to plain text
    // and returns [{role:'user'|'assistant', content}] for the last N exchanges.
    // This lets the AI editor maintain context across turns (like Hermes).
    // Skipped thinking entries (client-only), keeps only user+assistant.
    var _lastConversationId = '';
    function buildConversationHistory(maxExchanges) {
        maxExchanges = maxExchanges || 8;
        var history = [];
        var count = 0;
        for (var i = chatLog.length - 1; i >= 0 && count < maxExchanges; i--) {
            var entry = chatLog[i];
            if (!entry || entry.who === 'Think') continue;
            var role = (entry.who === 'You') ? 'user' : 'assistant';
            // Strip HTML tags for clean history
            var content = String(entry.html || '');
            content = content.replace(/<[^>]+>/g, ' ');
            content = content.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"');
            content = content.replace(/\s+/g, ' ').trim();
            if (!content) continue;
            history.unshift({ role: role, content: content });
            count++;
        }
        return history;
    }

    // Live thinking trail in chat (visible + kept for daily agent analysis).
    function startLiveThinking(meta) {
        ensureThinkingStyles(document);
        try {
            const w = window._aiChatWin;
            if (w && !w.closed) ensureThinkingStyles(w.document);
        } catch (e0) { /* ignore */ }
        const id = 'think-' + Date.now() + '-' + Math.random().toString(36).slice(2, 7);
        const startedAt = Date.now();
        const entry = {
            who: 'Think',
            id: id,
            open: true,
            done: false,
            summary: '⏳ AI thinking…',
            steps: []
        };
        chatLog.push(entry);

        function find() {
            for (let i = chatLog.length - 1; i >= 0; i--) {
                if (chatLog[i].id === id) return chatLog[i];
            }
            return entry;
        }
        function addStep(text) {
            const e = find();
            e.steps.push(String(text));
            refreshChatViews();
        }
        function setSummary(text) {
            const e = find();
            e.summary = String(text);
            refreshChatViews();
        }
        if (meta && meta.agent) addStep('Agent: ' + meta.agent);
        if (meta && meta.phase) addStep('Phase: ' + meta.phase);
        if (meta && meta.model) addStep('Model: ' + meta.model);
        if (meta && meta.file) addStep('Open file: ' + meta.file);
        addStep('Preparing request…');
        setSummary('⏳ Thinking — ' + (meta && meta.phase ? meta.phase + ' / ' : '') + (meta && meta.model ? meta.model : 'model') + ' (0s)');

        const heartbeat = setInterval(function () {
            const secs = Math.round((Date.now() - startedAt) / 1000);
            const e = find();
            if (e.done) return;
            e.summary = '⏳ Still thinking — ' + (meta && meta.phase ? meta.phase + ' / ' : '')
                + (meta && meta.model ? meta.model : 'model') + ' (' + secs + 's)';
            // Refresh last wait step or append tick every 5s for the record
            if (secs > 0 && secs % 5 === 0) {
                const waitLabel = 'Waiting on model… ' + secs + 's elapsed';
                if (!e.steps.length || e.steps[e.steps.length - 1].indexOf('Waiting on model') !== 0) {
                    e.steps.push(waitLabel);
                } else {
                    e.steps[e.steps.length - 1] = waitLabel;
                }
            }
            refreshChatViews();
            if (typeof setStatus === 'function') {
                setStatus('AI thinking… ' + secs + 's (' + ((meta && meta.model) || '') + ')');
            }
        }, 1000);

        function finalize(ok, extraSteps) {
            clearInterval(heartbeat);
            const e = find();
            e.done = true;
            const secs = Math.round((Date.now() - startedAt) / 1000);
            (extraSteps || []).forEach(function (s) { e.steps.push(String(s)); });
            e.steps.push(ok ? ('Done in ' + secs + 's') : ('Failed after ' + secs + 's'));
            e.summary = (ok ? '🔍 AI thinking' : '⚠️ AI thinking (failed)')
                + ' (' + e.steps.length + ' steps, ' + secs + 's)';
            refreshChatViews();
            return e.steps.slice();
        }

        return { id: id, addStep: addStep, setSummary: setSummary, finalize: finalize, startedAt: startedAt };
    }

    // --- Attach/Detach is a VIEW TOGGLE of one chat, not two chats. ---
    //   attached:  sidebar shown in editor (uses real estate)
    //   detached:  sidebar hidden (real estate released), chat in own window
    function sidebarAttached() { return !_detached; }

    // --- Single view-state: considers BOTH close (collapse) and detach ----
    //   attached + open :  sidebar visible in editor (uses real estate)
    //   attached + closed: sidebar hidden, floating 💬 to reopen
    //   detached         : sidebar hidden (real estate released), chat in own window
    let _detached = false;
    let _closed = false;

    function sidebarAttached() { return !_detached; }

    function applyViewState() {
        try {
            const sidebar = document.getElementById('ai-chat-sidebar');
            const btn = document.getElementById('ai-chat-detach');
            const reopen = document.getElementById('ai-chat-reopen');
            // Hidden if closed OR detached; otherwise shown (flex child of .main,
            // so the editor expands to fill the freed space — pinned to edges).
            if (sidebar) sidebar.style.display = (_closed || _detached) ? 'none' : 'flex';
            if (reopen) reopen.style.display = _closed ? 'block' : 'none';
            if (btn) btn.textContent = _detached ? '⊞ Attach' : '⤢ Detach';
            try {
                document.dispatchEvent(new CustomEvent('ai2:chat-view', {
                    detail: { closed: _closed, detached: _detached }
                }));
            } catch (evErr) { /* ignore */ }
            if (window.AI2EditorCore && typeof window.AI2EditorCore.resizeEditor === 'function') {
                window.AI2EditorCore.resizeEditor();
            }
            // Keep the log in sync with whichever view is now active.
            if (_detached) {
                const w = window._aiChatWin;
                if (w && !w.closed) renderChatLog(w.document.getElementById('chat-messages'));
            } else {
                renderChatLog(document.getElementById('chat-messages'));
            }
        } catch (e) {
            console.error('[AI2EditorChat] applyViewState error', e);
        }
    }

    // --- Close / reopen the chat sidebar (collapse to free editor space). ---
    // Distinct from detach: closing keeps the chat attached but hidden, with a
    // floating 💬 button to bring it back. Detach moves it to a separate window.
    function initClose() {
        const closeBtn = document.getElementById('ai-chat-close');
        const reopenBtn = document.getElementById('ai-chat-reopen');
        if (closeBtn) closeBtn.addEventListener('click', function () {
            _closed = true;
            applyViewState();
        });
        if (reopenBtn) reopenBtn.addEventListener('click', function () {
            _closed = false;
            applyViewState();
        });
    }

    function initDetach() {
        const btn = document.getElementById('ai-chat-detach');
        const sidebar = document.getElementById('ai-chat-sidebar');
        if (!btn || !sidebar) return;

        btn.addEventListener('click', function () {
            try {
                if (!_detached) {
                    // --- Detach: release editor real estate, open chat window ---
                    _detached = true;
                    if (!window._aiChatWin || window._aiChatWin.closed) {
                        openDetachedWindow();
                    } else {
                        window._aiChatWin.focus();
                    }
                    applyViewState();
                } else {
                    // --- Re-attach: bring chat back into the editor sidebar ---
                    _detached = false;
                    if (window._aiChatWin && !window._aiChatWin.closed) {
                        window._aiChatWin.close();
                        window._aiChatWin = null;
                    }
                    applyViewState();
                }
            } catch (e) {
                console.error('[AI2EditorChat] detach toggle error', e);
                _detached = false;
                applyViewState();
            }
        });
    }

    function openDetachedWindow() {
        let w = null;
        try {
            w = window.open('', 'AI2ChatDetach',
                'width=420,height=700,left=' + (screen.width - 440) + ',top=40,resizable=yes');
        } catch (e) {
            console.error('[AI2EditorChat] window.open blocked', e);
            _detached = false; applyViewState(); return;
        }
        if (!w) { _detached = false; applyViewState(); return; }
        try {
            window._aiChatWin = w;
            w.document.write(
                '<!DOCTYPE html><html><head><meta charset="utf-8">' +
                '<title>AI Chat — editor</title>' +
                '<style>body{margin:0;font-family:system-ui,sans-serif;background:#1e1f22;color:#ddd;height:100vh;display:flex;flex-direction:column;}' +
                '#chat-messages{flex:1;overflow:auto;padding:8px;font-size:0.9em;}' +
                '#chat-input{flex:1;min-height:32px;max-height:200px;resize:none;overflow-y:hidden;padding:6px;border:1px solid #555;border-radius:3px;background:#1e1f22;color:#ddd;font:inherit;line-height:1.35;}' +
                '#send{background:#0e639c;color:#fff;border:none;padding:6px 12px;border-radius:3px;cursor:pointer;align-self:flex-end;}' +
                '.bar{display:flex;gap:6px;padding:6px;border-top:1px solid #555;align-items:flex-end;}' +
                '#chat-status{padding:4px 8px;font-size:11px;color:#9ecbff;border-top:1px solid #333;min-height:16px;}' +
                '#chat-status.err{color:#f88;}' +
                'h3{margin:0;padding:8px;background:#2b2b2b;font-size:13px;display:flex;justify-content:space-between;align-items:center;}' +
                '#attach{background:transparent;border:1px solid #555;color:#aaa;border-radius:3px;cursor:pointer;font-size:11px;padding:1px 6px;}</style>' +
                '</head><body>' +
                '<h3>AI Chat — detached <button id="attach">⊞ Attach</button></h3>' +
                '<div id="chat-messages"></div>' +
                '<div id="chat-status">Ready</div>' +
                '<div class="bar"><textarea id="chat-input" rows="1" placeholder="Describe the bug… vague asks get Clarify first. Enter send, Shift+Enter newline"></textarea>' +
                '<button id="send">Send</button></div>' +
                '</body></html>'
            );
            w.document.close();
            ensureThinkingStyles(w.document);
            renderChatLog(w.document.getElementById('chat-messages'));

            const dInput = w.document.getElementById('chat-input');
            const dSend = w.document.getElementById('send');
            const dMsgs = w.document.getElementById('chat-messages');
            const dStatus = w.document.getElementById('chat-status');
            const target = {
                messages: dMsgs,
                input: dInput,
                sendBtn: dSend,
                status: function (msg, isError) {
                    if (!dStatus) return;
                    dStatus.textContent = msg || '';
                    dStatus.className = isError ? 'err' : '';
                }
            };
            function fire() {
                const v = (dInput.value || '').trim();
                if (!v) return;
                dInput.value = '';
                autosizePrompt(dInput);
                try {
                    sendPrompt(v, target);
                } catch (err) {
                    console.error('[AI2EditorChat] send failed', err);
                    target.status('Send failed: ' + (err && err.message ? err.message : err), true);
                    recordMessage('AI', '<span style="color:#f66">Send failed: ' + escapeHtml(String(err && err.message ? err.message : err)) + '</span>');
                }
            }
            dSend.addEventListener('click', fire);
            wirePromptBox(dInput, fire);

            // "Attach" inside the detached window re-attaches into the editor.
            const attachBtn = w.document.getElementById('attach');
            if (attachBtn) attachBtn.addEventListener('click', function () {
                try {
                    if (window.opener && !window.opener.closed && window.opener._aiReattach) {
                        window.opener._aiReattach();
                    } else {
                        window.close();
                    }
                } catch (err) { window.close(); }
            });

            // Closing the detached window re-attaches into the editor automatically.
            w.addEventListener('beforeunload', function () {
                try {
                    window._aiChatWin = null;
                    if (_detached) { _detached = false; applyViewState(); }
                } catch (err) { /* non-fatal */ }
            });
        } catch (e) {
            console.error('[AI2EditorChat] openDetachedWindow error', e);
            _detached = false; applyViewState();
        }
    }

    // Called from the detached window's "Attach" button.
    window._aiReattach = function () {
        if (_detached) {
            _detached = false;
            if (window._aiChatWin && !window._aiChatWin.closed) {
                window._aiChatWin.close();
                window._aiChatWin = null;
            }
            applyViewState();
        }
    };

    function setStatus(msg, isError) {
        const el = document.getElementById('file-status');
        if (el) {
            el.textContent = msg;
            el.style.color = isError ? '#f66' : '#888';
        }
    }

    let pendingSuggestion = null;   // code string awaiting Approve/Reject

    function showSuggestion(code) {
        pendingSuggestion = code;
        const pane = document.getElementById('ai-diff-pane');
        const content = document.getElementById('ai-diff-content');
        const status = document.getElementById('ai-diff-status');
        if (!pane || !content) return;
        content.textContent = code;
        if (status) status.textContent = ' — review, then Approve to apply & save';
        pane.style.display = 'block';
    }

    function clearSuggestion() {
        pendingSuggestion = null;
        const pane = document.getElementById('ai-diff-pane');
        const content = document.getElementById('ai-diff-content');
        if (pane) pane.style.display = 'none';
        if (content) content.textContent = '';
    }

    function loadCurrentFileContent() {
        const ed = getEditor();
        if (ed) {
            try {
                const v = ed.getValue();
                if (v && v.length) return Promise.resolve(v);
            } catch (e) { /* Ace not ready */ }
        }
        const path = currentFilePath();
        if (!path || !window.AI2EditorCore || typeof window.AI2EditorCore.loadFileContent !== 'function') {
            return Promise.resolve('');
        }
        return window.AI2EditorCore.loadFileContent(path)
            .then(function (data) { return data && data.content ? data.content : ''; })
            .catch(function () { return ''; });
    }

    const DEFAULT_APP_PATHS = [
        'lib/Comserv/Controller/AI2.pm',
        'lib/Comserv/Model/AI2/Chat.pm',
        'lib/Comserv/Model/AI2/CodeRead.pm',
        'lib/Comserv/Model/AI2/Router.pm'
    ];

    // Infer related controller / pipeline files from an opened template or page path.
    // Beefed up: uses getEditorContext() to handle cases where the *open file* (the one being edited)
    // differs from the *analyzed page/endpoint* (e.g. fix a failing page by opening editor elsewhere;
    // error message usually provided in prompt).
    // Also extracts file paths from error messages/stack traces.
    // Prefers AI2 paths during legacy->AI2 refactor. Tries legacy resolve_route for accuracy if available.
    // Enables earlier auto-knowledge of the "background pipeline" (controller action, stash population,
    // models, includes, date logic, action bars, etc.).
    async function inferRelatedPipelineFiles(openPath, promptHint = '') {
        const related = [];
        const ctx = getEditorContext();
        const primary = openPath || ctx.openFile || '';
        if (!primary && !ctx.currentPage) return related;

        const candidates = new Set();
        if (primary) candidates.add(primary);
        if (ctx.currentPage) candidates.add(ctx.currentPage);
        if (ctx.pageVsFileDiffer) {
            // When they differ, still try to resolve the "real" page
            candidates.add(ctx.currentPage);
        }

        // Error message / stack trace extraction (common when fixing load failures)
        if (promptHint) {
            const errPaths = promptHint.match(/(?:lib|root|script|Comserv)\/[\w\/.-]+\.(?:pm|tt|js|pl)/gi) || [];
            errPaths.forEach(p => candidates.add(p.replace(/^Comserv\//, '')));
            // Also look for common error indicators pointing at Planning etc.
            if (/planning|daily|DailyPlan/i.test(promptHint)) {
                candidates.add('lib/Comserv/Controller/Planning.pm');
            }
        }

        for (let cand of candidates) {
            if (!cand) continue;
            const p = cand.toLowerCase();

            // Try to get better mapping via legacy resolve_route (still useful during AI2 refactor;
            // returns controller + template). Non-blocking.
            try {
                const url = '/ai/resolve_route?path=' + encodeURIComponent(cand);
                const r = await fetch(url, { credentials: 'include' }).then(res => res.ok ? res.json() : null).catch(() => null);
                if (r && r.controller) {
                    const ctrlPath = r.controller.replace(/\./g, '/').replace('Comserv::Controller::', 'lib/Comserv/Controller/') + '.pm';
                    if (ctrlPath && !related.includes(ctrlPath)) related.push(ctrlPath);
                }
                if (r && r.template) {
                    if (!related.includes(r.template)) related.push(r.template);
                }
            } catch (e) { /* ignore, fall back to heuristics */ }

            // Template -> controller heuristics (Catalyst / TT conventions)
            if (p.endsWith('.tt') || p.includes('/root/')) {
                if (p.includes('dailyplan') || p.includes('planning/daily')) {
                    related.push('lib/Comserv/Controller/Planning.pm');
                }
                const match = p.match(/root\/(?:admin\/)?([^\/]+)\/.*\.tt$/);
                if (match) {
                    let ctrl = 'lib/Comserv/Controller/' + match[1].charAt(0).toUpperCase() + match[1].slice(1) + '.pm';
                    if (!related.includes(ctrl)) related.push(ctrl);
                }
                if (p.includes('/admin/')) {
                    const adminMatch = p.match(/root\/admin\/([^\/]+)\//);
                    if (adminMatch) {
                        const ctrl = 'lib/Comserv/Controller/Admin/' + adminMatch[1].charAt(0).toUpperCase() + adminMatch[1].slice(1) + '.pm';
                        if (!related.includes(ctrl)) related.push(ctrl);
                    }
                }
            } else if (p.endsWith('.pm')) {
                // If a controller is primary, pull its likely template too for context
                if (!related.includes(cand)) related.push(cand);
                // crude reverse
                const ctrlName = cand.split('/').pop().replace('.pm', '');
                const possibleTpl = 'root/' + ctrlName.toLowerCase() + '/' + ctrlName.toLowerCase() + '.tt'; // rough
                // better: we already have the open file
            }

            // Always consider core AI/editor files (prefer AI2 during refactor)
            DEFAULT_APP_PATHS.forEach(f => {
                if (!related.includes(f)) related.push(f);
            });
        }

        // Dedup
        return [...new Set(related)];
    }

    function isEvaluatePrompt(text) {
        const p = String(text || '').toLowerCase();
        if (/\bevaluat/.test(p)) return true;
        if (/\bread.{0,30}\bevaluat/.test(p)) return true;
        if (/\b(look at|look over|review|inspect)\b/.test(p) && /\b(code|file|source)\b/.test(p)) return true;
        return false;
    }

    function fetchLoadFile(path) {
        return fetch('/ai2/load_file?path=' + encodeURIComponent(path), { credentials: 'include' })
            .then(function (res) { return res.json(); })
            .then(function (data) {
                if (data && data.content) return { path: path, content: data.content };
                return null;
            })
            .catch(function () { return null; });
    }

    function loadFilesForEval(openPath, openContent) {
        const paths = DEFAULT_APP_PATHS.slice();
        if (openPath && /^(lib|root\/static|sql|script|t)\//.test(openPath)
            && paths.indexOf(openPath) === -1) {
            paths.unshift(openPath);
        }
        return Promise.all(paths.map(fetchLoadFile)).then(function (rows) {
            return rows.filter(Boolean);
        });
    }

    function filesToPromptBlob(files) {
        if (!files || !files.length) return '';
        return files.map(function (f) {
            const body = String(f.content || '').slice(0, 48000);
            return '[FILE: ' + f.path + '] (live /ai2/load_file)\n```\n' + body + '\n```';
        }).join('\n\n');
    }

    function isDiskCapabilityPrompt(text) {
        const p = String(text || '').toLowerCase();
        if (/\b(how do i|please fix|refactor|implement)\b/.test(p)) return false;
        if (/\b(what|which)\s+files\b/.test(p)) return true;
        if (/\bon disk\b/.test(p) && /\b(read|able|access|see|open)\b/.test(p)) return true;
        if (/\bable(?:\s+to)?\s+read\b/.test(p)) return true;
        if (/\b(can|could|do)\s+you\b/.test(p) && /\b(read|access|see)\b/.test(p)
            && /\b(file|files|code|disk|source)\b/.test(p)) return true;
        return false;
    }

    function flattenTree(nodes, depth, acc) {
        if (!nodes || !nodes.length) return acc;
        depth = depth || 0;
        acc = acc || [];
        for (let i = 0; i < nodes.length && acc.length < 80; i++) {
            const n = nodes[i];
            if (!n) continue;
            const pad = new Array(depth + 1).join('  ');
            acc.push(pad + (n.type === 'dir' ? n.name + '/' : n.name));
            if (n.type === 'dir' && n.children && depth < 1) {
                flattenTree(n.children.slice(0, 14), depth + 1, acc);
            }
        }
        return acc;
    }

    function finishSend(target, sendBtn, msg, status, isError) {
        if (sendBtn) { sendBtn.disabled = false; sendBtn.textContent = 'Send'; }
        recordMessage('AI', '<span style="color:#7fb7ff;font-size:0.85em;">[live-read]</span> '
            + escapeHtml(msg).replace(/\n/g, '<br>'));
        if (target.status) target.status(status || 'Live read', isError);
    }

    function liveAnswerDiskQuestion(prompt, target, sendBtn) {
        const open = currentFilePath() || '(none open)';
        return fetch('/ai2/file_tree', { credentials: 'include' })
            .then(function (res) { return res.json(); })
            .then(function (data) {
                const lines = flattenTree((data && data.tree) || []);
                const msg = 'Yes. Live read from this app via GET /ai2/file_tree (not Hy3).\n'
                    + 'Allowed tops: lib/, root/, sql/, script/, t/. Secrets (.env, keys) refused.\n'
                    + 'Currently open: ' + open + '\n\n'
                    + (lines.length ? lines.join('\n') : '(tree empty or not authorized)')
                    + '\n\nOpen a file in Project, or name a path such as lib/Comserv/Model/AI2/Chat.pm';
                finishSend(target, sendBtn, msg, 'Live file-tree read');
            })
            .catch(function (err) {
                finishSend(target, sendBtn, 'Live read failed: ' + (err && err.message ? err.message : err),
                    'Live read failed', true);
            });
    }


    // --- Agent + phase (clarify → analyze → plan → verify → implement) ---
    // Budget: clarify + most analyze/plan stay on cheap/fast models; implement uses a code model.
    // Header model select always overrides.
    //
    // New local Ollama models (as of this session):
    // - nimble (9B, Bespoke Labs): involved in todo/decision ranking + daily planning sort (compute_decision_rank.pl, Util/AI/DecisionRank).
    //   Good for planning/analyze phases on DailyPlan, focus queue, priorities, audits.
    // - tev1 (4B / 0.8B): used in Focus-Tune / decision chains; fast local option.
    //
    // Not fully tested yet — prefer as cheap local fallbacks for analyze/plan on planning code.
    // OpenRouter frees still available as backup. Local preferred for speed/cost/privacy in editor.
    const CLARIFY_MODEL = 'ollama|tev1:0.8b';  // or nimble for heavier clarify
    const ANALYZE_MODEL = 'ollama|nimble';     // strong for pipeline + planning analysis (DailyPlan etc.)
    const PLAN_MODEL    = 'ollama|nimble';     // explicit for plan phase on todo/daily planning
    const IMPLEMENT_MODEL = 'openrouter|cohere/north-mini-code:free';  // or local code model when ready
    let _userPickedModel = false;
    let _escalatedThisSend = false;
    let _planApproved = false;
    // Pending clarify session: original vague ask + gap questions awaiting answers.
    let _clarifySession = null; // { original, gaps, askedAt }

    function currentEditorAgentId() {
        const sel = document.getElementById('ai-editor-agent');
        const v = sel && sel.value ? sel.value : 'programming';
        return v || 'programming';
    }

    function currentEditorPhase() {
        const sel = document.getElementById('ai-editor-phase');
        if (sel && sel.value) _editorPhase = sel.value;
        return _editorPhase || 'analyze';
    }

    function setEditorPhase(phase) {
        _editorPhase = phase || 'analyze';
        const sel = document.getElementById('ai-editor-phase');
        if (sel) sel.value = _editorPhase;
        const badge = document.getElementById('ai-editor-phase-badge');
        if (badge) {
            badge.textContent = 'Phase: ' + _editorPhase + (_planApproved ? ' (plan approved)' : '');
        }
    }

    function resolveEditorModel(phase) {
        const filePath = currentFilePath() || '';
        const isPlanningContext = /dailyplan|planning|todo.*sort|focus.*queue/i.test(filePath) ||
                                  /daily.*plan|planning.*page/i.test(document.title || '');

        // Header model select usually wins, but for planning/DailyPlan analysis we bias
        // hard toward local nimble (the model actually used for todo/daily planning sort).
        const picked = (window.ComservChat && ComservChat.modelSelect)
            ? ComservChat.modelSelect.getSelectedValue()
            : '';

        // Strong bias for planning work
        if (isPlanningContext && (phase === 'plan' || phase === 'analyze')) {
            return picked || 'ollama|nimble';  // prefer the one that actually sorts daily planning
        }

        if (phase === 'clarify') {
            return picked || CLARIFY_MODEL;
        }
        if (currentEditorAgentId() === 'analyze') {
            return picked || ANALYZE_MODEL;
        }
        if (phase === 'implement') {
            return picked || IMPLEMENT_MODEL;
        }
        if (phase === 'plan') {
            return picked || PLAN_MODEL;
        }
        return picked || ANALYZE_MODEL;
    }

    // Local gap detection — no tokens. Used before any clarify/analyze model call.
    function promptGaps(prompt, filePath) {
        const p = String(prompt || '').trim();
        const lower = p.toLowerCase();
        const gaps = [];
        if (p.length < 40) {
            gaps.push('What exactly is broken or missing? (one sentence symptom)');
        }
        const hasSite = /\b(sitename|site\s*name|3d|bmaster|csc|forager|brew)\b/i.test(p);
        if (!hasSite && /\b(site|nav|menu|feature|addon|module)\b/i.test(lower)) {
            gaps.push('Which sitename / host is this on? (e.g. 3d, CSC, BMaster)');
        }
        const hasPath = /(?:^|\s)(?:lib\/|root\/|Comserv\/|[\w.-]+\.(?:pm|tt|js|sql))\b/.test(p)
            || (filePath && filePath.length > 0);
        if (!hasPath && /\b(bug|broken|fix|error|fail|not work|missing|gate|nav)\b/i.test(lower)) {
            gaps.push('Any file/module path you already suspect, or should we search from Root/nav?');
        }
        if (/\b(not work|broken|fail|wrong|missing|no .+ feature)\b/i.test(lower)
            && !/\b(expected|should|want|instead)\b/i.test(lower)) {
            gaps.push('What should happen instead? (expected behavior)');
        }
        if (!/\b(repro|steps|when i|after i|click|login|guest)\b/i.test(lower) && p.length < 200) {
            gaps.push('How do you reproduce it? (short steps)');
        }
        if (/\b(addon|feature)\b/i.test(lower) && !/\b(site_modules|enabled_modules|hosting|nav)\b/i.test(lower)) {
            gaps.push('Is this a site *feature* (nav/module enablement) or something else?');
        }
                if (/SQL_[A-Z_]+\s*=>/.test(p) || /Address already in use/i.test(p) || /failed to listen to port/i.test(p)) {
            gaps.push('That looks like a server log paste. What do you want fixed — the bug behind it, or help reading the log?');
        }
        // Dedup, max 4
        const out = [];
        gaps.forEach(function (g) { if (out.indexOf(g) === -1) out.push(g); });
        return out.slice(0, 4);
    }

    function looksLikeLogNoise(prompt) {
        const p = String(prompt || '');
        let hits = 0;
        if (/SQL_[A-Z_]+\s*=>/.test(p)) hits++;
        if (/Address already in use/i.test(p)) hits++;
        if (/Exiting eval via next/i.test(p)) hits++;
        if (/failed to listen to port/i.test(p)) hits++;
        if (/_initialize_ai_chat_schema/i.test(p)) hits++;
        if (/HTTP\/Server\/PSGI/i.test(p)) hits++;
        if (/\[workstation \(Standalone\):\d+\]/.test(p)) hits++;
        if (/SQL_QUOTED_IDENTIFIER_CASE/i.test(p)) hits++;
        if (/shanta@workstation:/i.test(p)) hits++;
        return hits >= 2;
    }

    // Free code models often invent tool calls or echo shell noise instead of analyzing.
    function looksLikeJunkAnalyzeReply(text, phase) {
        const t = String(text || '').trim();
        if (!t) return true;
        if (looksLikeLogNoise(t)) return true;
        if (/\[ACTION:\s*\{/i.test(t) && t.length < 800) return true;
        if (/^\s*\[ACTION:/i.test(t)) return true;
        if ((phase === 'analyze' || phase === 'plan' || phase === 'clarify')
            && (/list_files|read_file|run_terminal|\[run,\s*cwd=/i.test(t))
            && !/root cause|enabled_modules|SiteModule|can_beekeep/i.test(t)) {
            return true;
        }
        if ((t.match(/\[run,\s*cwd=/gi) || []).length >= 3) return true;
        return false;
    }

    function looksVague(prompt, filePath) {
        const p = String(prompt || '').trim();
        if (/^(skip\s+clarify|analyze\s+now|looks\s+good)\b/i.test(p)) return false;
        if (/^## Refined engineering task/.test(p)) return false; // already fabricated
        if (looksLikeLogNoise(p)) return true;
        const gaps = promptGaps(p, filePath);
        // One missing fact is enough — do not burn an analyze turn on a thin ask.
        if (gaps.length >= 1) return true;
        if (p.length < 100) return true;
        if (/\b(fix|help|broken|not working|whats wrong|what'?s wrong|happening)\b/i.test(p)) {
            return true;
        }
        return false;
    }

    function isSkipClarify(prompt) {
        return /^\s*(skip\s+clarify|analyze\s+now|looks\s+good|just\s+analyze)\b/i.test(String(prompt || ''));
    }

    function synthesizePrompt(original, answers, filePath) {
        const lines = [
            '## Refined engineering task (fabricated from clarify)',
            '',
            '### Original ask',
            String(original || '').trim(),
            '',
            '### Clarifications from user',
            String(answers || '').trim() || '(none — user skipped; infer carefully from code)',
            '',
            '### Editor context',
            'Open file: ' + (filePath || '(none)'),
            '',
            '### Required output',
            '1. Reproduce / locate the real gate in Comserv code (not guesswork about DNS/addons unless evidence).',
            '2. Name root cause with file/symbol references.',
            '3. Propose the smallest safe fix.',
            '4. How to verify on aisystem :4006 (no prod deploy).',
            'Do not invent infrastructure. Prefer site *features* / enabled_modules / nav gating over "paid addon" language unless the code literally says addon.'
        ];
        return lines.join('\n');
    }

    function beginClarifySession(original, gaps, target, sendBtn) {
        _clarifySession = {
            original: original,
            gaps: gaps.slice(),
            askedAt: Date.now()
        };
        setEditorPhase('clarify');
        const qHtml = gaps.map(function (g, i) {
            return (i + 1) + '. ' + escapeHtml(g);
        }).join('<br>');
        recordMessage('AI',
            '<span style="color:#ffd27a;font-size:0.9em;">[clarify · free]</span> '
            + 'Your ask is a bit thin for a good analysis. Please answer:<br><br>'
            + qHtml
            + '<br><br><span style="opacity:0.85;">Reply with answers in one message, or say '
            + '<code>skip clarify</code> / <code>analyze now</code> to proceed anyway.</span>');
        if (sendBtn) { sendBtn.disabled = false; sendBtn.textContent = 'Send'; }
        if (target && target.status) target.status('Clarify — waiting for your answers');
    }

    function phaseContract(phase, agentId) {
        const lines = [
            '[AI Editor agent=' + agentId + ' phase=' + phase + ']',
            'Contract:',
            '0) clarify — ask only for missing facts; do not analyze code deeply yet.',
            'A) analyze — cost-effective analysis; no ## FIX / large rewrites.',
            'B) plan — short plan for user verify; docs/changelog notes only as text; do not create todos; end by asking for "approve plan".',
            'C) implement — code suggestion only after plan approval (or explicit implement request).'
        ];
        // Note on open file vs analyzed page (key during refactoring and error fixing)
        lines.push('CONTEXT NOTE: Primary open file (buffer) is usually the clicked page, but can differ (e.g. open editor from stable page to fix a broken one). Error messages are often supplied — use them + auto-attached pipeline controllers.');

        if (agentId === 'analyze') {
            lines.push('You are the Analyze worker: read open buffers and named paths; explain root cause and a short plan only. Never emit ## FIX, never rewrite files, never ask the user to paste files already loaded via /ai2/load_file. Use auto-attached controller for pipeline understanding.');
        } else if (agentId === 'documentation') {
            lines.push('You are in documentation mode: prefer docs/changelog/planning guidance; do not emit code file rewrites unless asked.');
        } else {
            lines.push('You are in programming mode: do NOT divert to FocusTune; never create todos or emit [ACTION: create_todo]; stay on code/docs/plan for this file.');
        }
        if (phase === 'clarify') {
            lines.push('Current phase CLARIFY: ask 2–4 short questions about missing context only. No root-cause essay.');
        } else if (phase === 'analyze') {
            lines.push('Current phase ANALYZE: respond with analysis only. Prefer evidence from loaded files and Comserv patterns (features/modules/nav).');
        } else if (phase === 'plan') {
            lines.push('Current phase PLAN: propose the plan; wait for user "approve plan" / Verify before code. Reference background pipeline from auto-loaded files.');
        } else {
            lines.push('Current phase IMPLEMENT: provide concrete code suggestion for Approve/Reject.');
        }
        return lines.join('\n');
    }

    function todoStartReminder() {
        let todoId = '';
        try {
            const q = new URLSearchParams(window.location.search);
            todoId = q.get('todo_id') || q.get('record_id') || '';
        } catch (e) { /* ignore */ }
        if (!todoId && window.AI2_TODO_ID) todoId = String(window.AI2_TODO_ID);
        if (!todoId) {
            // Look for todo #NNNN in recent chat
            try {
                const blob = chatLog.map(function (e) { return e.html || ''; }).join(' ');
                const m = blob.match(/todo\s*#?\s*(\d{3,})/i) || blob.match(/record_id[=: ]+(\d{3,})/i);
                if (m) todoId = m[1];
            } catch (e2) { /* ignore */ }
        }
        if (!todoId) return '';
        return '\n[TODO CONTEXT] Existing todo #' + todoId
            + ' — remind user to Start it first (POST /todo/open_log) before coding if not already started. '
            + 'Link: /todo/details?record_id=' + todoId + '\n';
    }

    function maybeAdvancePhaseFromUser(prompt) {
        const p = String(prompt || '').toLowerCase();
        // Analyze worker never auto-advances to implement from chat text.
        if (currentEditorAgentId() === 'analyze') {
            if (/\b(make\s+a\s+)?plan\b|\bpropose\b/.test(p) && currentEditorPhase() === 'analyze') {
                setEditorPhase('plan');
            }
            return;
        }
        // Waiting/negative wording must not advance (e.g. "wait for Verify before implementing").
        const waitingOrNegative = /\b(wait\s+for|do\s+not|don't|dont|never|before)\b/.test(p)
            && /\b(verify|implement)/.test(p);
        if (!waitingOrNegative && (
            /\bapprove\s+plan\b/.test(p)
            || /\bplan\s+approved\b/.test(p)
            || /\bverified\b/.test(p)
            || /\bgo\s+ahead\b/.test(p)
            || /\bwrite\s+the\s+code\b/.test(p)
            || /\bplease\s+implement\b/.test(p)
            || /\bimplement\s+now\b/.test(p)
        )) {
            _planApproved = true;
            setEditorPhase('implement');
            return;
        }
        if (/\b(make\s+a\s+)?plan\b|\bpropose\b/.test(p) && currentEditorPhase() === 'analyze') {
            setEditorPhase('plan');
        }
    }

    function sendPrompt(prompt, target) {
        target = target || {
            messages: document.getElementById('chat-messages'),
            input: document.getElementById('ai-chat-input'),
            sendBtn: document.getElementById('ai-chat-send'),
            status: function (msg, isError) { setStatus(msg, isError); }
        };
        const input = target.input;
        const sendBtn = target.sendBtn;
        if (!prompt || !prompt.trim()) return;

        if (target.status) target.status('Starting…');
        // Record to the shared chat log (survives attach/detach).
        recordMessage('You', escapeHtml(prompt));

        if (sendBtn) { sendBtn.disabled = true; sendBtn.textContent = '...'; }

        // Disk-capability questions must NEVER reach Hy3.
        if (isDiskCapabilityPrompt(prompt)) {
            if (target.status) target.status('Live reading project tree...');
            liveAnswerDiskQuestion(prompt, target, sendBtn);
            return;
        }

        const filePathEarly = currentFilePath();

        // Answer an open clarify session → fabricate analyze prompt (no extra clarify model $).
        if (_clarifySession) {
            const original = _clarifySession.original;
            const answers = isSkipClarify(prompt) ? '' : prompt;
            _clarifySession = null;
            const fabricated = synthesizePrompt(original, answers, filePathEarly);
            recordMessage('AI',
                '<span style="color:#7fb7ff;font-size:0.9em;">[fabricated prompt → analyze · free]</span><br>'
                + '<pre style="white-space:pre-wrap;margin:6px 0;font-size:0.85em;opacity:0.95;">'
                + escapeHtml(fabricated) + '</pre>');
            setEditorPhase('analyze');
            prompt = fabricated;
            if (target.status) target.status('Fabricated prompt — starting analyze…');
        } else {
            // Auto-clarify when ask is thin (or phase is Clarify).
            maybeAdvancePhaseFromUser(prompt);
            let phasePeek = currentEditorPhase();
            const wantClarify = (phasePeek === 'clarify')
                || ((phasePeek === 'analyze' || phasePeek === 'plan') && looksVague(prompt, filePathEarly));
            if (wantClarify && !isSkipClarify(prompt)) {
                const gaps = promptGaps(prompt, filePathEarly);
                if (gaps.length) {
                    beginClarifySession(prompt, gaps, target, sendBtn);
                    return;
                }
                if (phasePeek === 'clarify') setEditorPhase('analyze');
            }
        }

        // Agent + phase first so thinking UI can name model/phase immediately.
        maybeAdvancePhaseFromUser(prompt);
        const agentId = currentEditorAgentId();
        const phase = currentEditorPhase() === 'clarify' ? 'analyze' : currentEditorPhase();
        if (currentEditorPhase() === 'clarify') setEditorPhase('analyze');
        const model = resolveEditorModel(phase);
        // The header pin is not a user choice. Unless the dropdown was changed,
        // leave model empty so the server picks from SuperGrok, OpenRouter, Ollama.
        const sendModel = (_userPickedModel && model) ? model : '';
        const route = _escalatedThisSend ? 'escalate' : (sendModel ? 'explicit' : 'auto');
        const filePath = filePathEarly;

        if (target.status) target.status('AI thinking…');
        const liveThink = startLiveThinking({
            agent: agentId,
            phase: phase,
            model: model,
            file: filePath || '(none)'
        });

        loadCurrentFileContent().then(function (fileContent) {
            liveThink.addStep('Loaded editor buffer' + (fileContent && fileContent.length
                ? ' (' + fileContent.length + ' chars)' : ' (empty)'));
            const wantEval = isEvaluatePrompt(prompt);
            let filesP = wantEval
                ? loadFilesForEval(filePath, fileContent)
                : Promise.resolve(fileContent && fileContent.length
                    ? [{ path: filePath, content: fileContent }] : []);

            // NEW: Auto-load related pipeline files (controller etc.) early for .tt / page analysis.
            // This gives the AI direct knowledge of the background pipeline (stash population,
            // models, includes, date logic, etc.) before clarify/analyze/plan. Greatly improves
            // self-direction and planning accuracy.
            if (!wantEval && filePath) {
                // Beefed up inference is async (tries resolve_route + error extraction)
                filesP = filesP.then(async function (baseFiles) {
                    const promptForHint = prompt || '';
                    const pipelinePaths = await inferRelatedPipelineFiles(filePath, promptForHint);
                    const extra = await Promise.all(pipelinePaths.map(function (rp) {
                        if (rp === filePath) return null;
                        return fetchLoadFile(rp);
                    })).then(function (extras) { return extras.filter(Boolean); });

                    const seen = new Set(baseFiles.map(function (f) { return f.path; }));
                    extra.forEach(function (ef) {
                        if (!seen.has(ef.path)) {
                            baseFiles.push(ef);
                            seen.add(ef.path);
                        }
                    });
                    return baseFiles;
                });
            }

            return filesP.then(function (files) {
                const blob = filesToPromptBlob(files);
                const contract = phaseContract(phase, agentId) + todoStartReminder();
                const ctx = getEditorContext();
                let contextNote = '';
                if (ctx.pageVsFileDiffer) {
                    contextNote = '\n[EDITOR CONTEXT] Open file for editing: ' + (ctx.openFile || 'none') +
                        ' | Analyzed / current page: ' + (ctx.currentPage || 'unknown') +
                        ' (may differ when fixing errors from another surface; error details usually in prompt)';
                }
                const fullPrompt = blob
                    ? (contract + contextNote + '\n\n' + prompt + '\n\n---\nThese files were loaded live from this app via GET /ai2/load_file (including auto pipeline controllers). They ARE in this message. Never say you cannot see them or ask the user to paste.\n\n' + blob)
                    : (contract + contextNote + '\n\n' + prompt);
                if (files.length) {
                    liveThink.addStep('Attached files: ' + files.map(function (f) { return f.path; }).join(', '));
                    if (target.status) target.status('Loaded ' + files.map(function (f) { return f.path; }).join(', '));
                }
                liveThink.addStep('Calling /ai2/chat (waiting on provider)…');
                if (target.status) target.status('Asking AI…');
                const history = buildConversationHistory(8);

                return fetch('/ai2/chat', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        prompt: fullPrompt,
                        model: sendModel,
                        route: route,
                        user_picked: _userPickedModel ? 1 : 0,
                        agent_id: agentId,
                        phase: phase,
                        page_path: filePath || (files[0] && files[0].path) || '',
                        page_title: filePath ? filePath.split('/').pop() : '',
                        page_content: (files[0] && files[0].content) || fileContent || '',
                        history: history,
                        conversation_id: _lastConversationId || ''
                    })
                });
            });
        }).then(function (res) { return res.json(); })
          .then(function (data) {
              if (sendBtn) { sendBtn.disabled = false; sendBtn.textContent = 'Send'; }
              // Remember conversation_id for next turn
              if (data && data.conversation_id) {
                  _lastConversationId = String(data.conversation_id);
              }
              if (!data || data.success === 0 || data.error) {
                  const err = (data && data.error) ? data.error : 'No response';
                  const serverSteps = (data && data.thinking && data.thinking.length) ? data.thinking : [];
                  liveThink.finalize(false, serverSteps.concat(['Error: ' + err]));
                  recordMessage('AI', '<span style="color:#f66">' + escapeHtml(err) + '</span>');
                  if (target.status) target.status('AI error: ' + err, true);
                  return;
              }
              const usedModel = (data.model ? data.model + (data.provider ? ' (' + data.provider + ')' : '') : EDITOR_MODEL);
              const resp = data.response || '';
              const serverSteps = (data.thinking && data.thinking.length) ? data.thinking : [];
              const extra = serverSteps.slice();
              if (data.provider) extra.push('Provider: ' + data.provider);
              if (data.model) extra.push('Model used: ' + data.model);
              if (data.fallback) extra.push('Fallback used' + (data.fallback_from ? ' from ' + data.fallback_from : ''));
              liveThink.finalize(true, extra);
              if (data.files_read && data.files_read.length) {
                  recordMessage('AI', '<span style="color:#7fb7ff;font-size:0.85em;">[read ' + escapeHtml(data.files_read.join(', ')) + ']</span>');
                  if (target.status) target.status('Read ' + data.files_read.join(', '));
              }
              const extracted = (window.ComservChat && ComservChat.featureTodo && ComservChat.featureTodo.extractActions)
                  ? ComservChat.featureTodo.extractActions(resp)
                  : { cleanText: resp, actions: [] };
              const display = extracted.cleanText || resp;
              // Prefix the reply with the model actually used, for transparency.
              if (looksLikeJunkAnalyzeReply(display, phase)) {
                  if (!_escalatedThisSend) {
                      _escalatedThisSend = true;
                      liveThink.addStep('Reply was junk — asking the router to pick another available model');
                      recordMessage('AI',
                          '<span style="color:#ffd27a;">[switch]</span> That reply was not usable. '
                          + 'Asking the router to pick from the models that are actually available.');
                      if (target.status) target.status('Switching model…');
                      return fetch('/ai2/chat', {
                          method: 'POST',
                          headers: { 'Content-Type': 'application/json' },
                          body: JSON.stringify({
                              prompt: fullPrompt,
                              model: '',
                              route: 'escalate',
                              user_picked: 0,
                              agent_id: agentId,
                              phase: phase,
                              page_path: filePath || '',
                              page_title: filePath ? filePath.split('/').pop() : '',
                              page_content: fileContent || '',
                              history: history,
                              conversation_id: _lastConversationId || ''
                          })
                      }).then(function (res2) { return res2.json(); }).then(function (data2) {
                          if (sendBtn) { sendBtn.disabled = false; sendBtn.textContent = 'Send'; }
                          if (data2 && data2.conversation_id) _lastConversationId = String(data2.conversation_id);
                          const used2 = (data2 && data2.model) ? data2.model : 'router';
                          const text2 = (data2 && data2.response) || (data2 && data2.error) || '';
                          if (!data2 || data2.success === 0 || looksLikeJunkAnalyzeReply(text2, phase)) {
                              recordMessage('AI',
                                  '<span style="color:#f88;">[rejected reply]</span> '
                                  + 'The router retry also failed'
                                  + (used2 ? ' (' + escapeHtml(used2) + ')' : '') + '.');
                              if (target.status) target.status('Model switch did not produce a usable reply', true);
                              return;
                          }
                          recordMessage('AI',
                              '<span style="color:#7fb7ff;font-size:0.85em;">[' + escapeHtml(used2) + ']</span> '
                              + escapeHtml(text2).replace(/\n/g, '<br>'));
                          if (target.status) target.status('Reply from ' + used2);
                      });
                  }
                  liveThink.finalize(false, ['Rejected junk/log-like model reply']);
                  recordMessage('AI',
                      '<span style="color:#f88;">[rejected reply]</span> '
                      + 'That model response was not an analysis of the task.');
                  if (target.status) target.status('Rejected junk model reply', true);
                  return;
              }
              var bodyHtml = escapeHtml(display).replace(/\n/g, '<br>');
              recordMessage('AI', '<span style="color:#7fb7ff;font-size:0.85em;">[' + escapeHtml(usedModel) + ']</span> ' + bodyHtml);

              // Belt-and-suspenders: programming/docs agents must not create todos from chat.
              const skipTodoCreate = /^(programming|coding|code|documentation|analyze)$/i.test(agentId);
              if (!skipTodoCreate && data.todo_action && window.ComservChat && ComservChat.featureTodo
                  && typeof ComservChat.featureTodo.handleServerResult === 'function') {
                  ComservChat.featureTodo.handleServerResult(data.todo_action, {
                      host: document.getElementById('chat-messages'),
                      status: target.status,
                      pagePath: currentFilePath() || window.location.pathname
                  });
              }
              if (!skipTodoCreate && extracted.actions && extracted.actions.length && window.ComservChat.featureTodo.handleAction) {
                  extracted.actions.forEach(function (a) {
                      if (a.action === 'create_todo' || a.action === 'create_project') {
                          ComservChat.featureTodo.handleAction(a, {
                              host: document.getElementById('chat-messages'),
                              status: target.status,
                              pagePath: currentFilePath() || window.location.pathname
                          });
                      }
                  });
              }

              const block = (data.provider === 'ai2-coderead') ? null : extractCodeBlock(display);
              const allowSuggest = (currentEditorAgentId() !== 'documentation')
                  && (currentEditorAgentId() !== 'analyze')
                  && (currentEditorPhase() === 'implement' || _planApproved
                      || /\b(implement|apply|write code|fix now)\b/i.test(prompt));
              if (block && allowSuggest) {
                  // A suggestion is always applied to the MAIN editor window,
                  // even when chat is detached into its own window.
                  showSuggestion(block.code);
                  if (target.status) target.status('Suggestion ready (' + usedModel + ')');
              } else {
                  if (target.status) {
                      target.status(block && !allowSuggest
                          ? 'Plan/analyze reply (code suggestion held until implement/Verify)'
                          : 'Replied (no code suggestion)');
                  }
              }
          })
          
          .catch(function (err) {
              if (sendBtn) { sendBtn.disabled = false; sendBtn.textContent = 'Send'; }
              try { liveThink.finalize(false, ['Request failed: ' + (err && err.message ? err.message : err)]); } catch (e2) { /* ignore */ }
              recordMessage('AI', '<span style="color:#f66">Request failed: ' + escapeHtml(err.message) + '</span>');
              if (target.status) target.status('Request failed: ' + err.message, true);
          });
    }

    function approveSuggestion() {
        if (pendingSuggestion === null) return;
        const editor = getEditor();
        const filePath = currentFilePath();
        if (!editor) {
            setStatus('Editor not available', true);
            return;
        }
        if (!filePath) {
            setStatus('No file loaded to save into', true);
            return;
        }

        // Apply the suggestion to the editor.
        editor.setValue(pendingSuggestion, -1);
        editor.clearSelection();
        clearSuggestion();
        setStatus('Applying & saving...');

        const saveBtn = document.getElementById('save-btn');
        if (saveBtn) { saveBtn.disabled = true; saveBtn.textContent = 'Saving...'; }

        fetch('/ai2/save_file', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path: filePath, content: pendingSuggestion })
        })
        .then(function (res) { return res.json(); })
        .then(function (data) {
            if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'Save'; }
            if (data && data.success) {
                if (saveBtn) { saveBtn.style.display = 'none'; }
                setStatus('Saved');
                // Success hook for learning: a good analysis + approved change was applied.
                // Future: POST to a learning endpoint or log compact record (original prompt + files + outcome)
                // so future sessions can retrieve "[SUCCESSFUL PIPELINE ANALYSIS]" patterns.
                // Ties into comserv2-ai-learning-system (DB for app, skills for agent-side).
                console.log('[AI Editor Success] Approved & saved for', filePath);
            } else {
                const msg = 'Save failed: ' + ((data && (data.error || data.detail)) || 'unknown error');
                setStatus(msg, true);
            }
        })
        .catch(function (err) {
            if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'Save'; }
            setStatus('Save error: ' + err.message, true);
        });
    }

    function rejectSuggestion() {
        clearSuggestion();
        setStatus('Suggestion rejected');
    }

    // --- Auto-refresh: poll the on-disk file checksum every 4s and reload
    //     ONLY when the editor has no unsaved changes, so we never clobber
    //     the admin's in-progress edits. Updates the status-bar timestamp. ---
    let _dirty = false;
    let _autoTimer = null;
    let _checksumInFlight = false;
    let _changeWired = false;

    function markDirty() { _dirty = true; }
    function markClean() { _dirty = false; }

    function initAutoRefresh() {
        const filePath = currentFilePath();
        const lastModEl = document.getElementById('last-modified');
        const statusEl = document.getElementById('auto-refresh-status');
        if (_autoTimer) {
            clearInterval(_autoTimer);
            _autoTimer = null;
        }
        if (statusEl) statusEl.textContent = 'Auto-refresh: ON (4s)';
        if (!filePath) {
            if (statusEl) statusEl.textContent = 'Auto-refresh: off (no file)';
            return;
        }

        const editor = getEditor();
        if (editor && !_changeWired) {
            _changeWired = true;
            editor.session.on('change', function () { _dirty = true; });
        }

        _autoTimer = setInterval(function () {
            if (_dirty) return;
            if (_checksumInFlight) return;
            if (typeof document.hidden === 'boolean' && document.hidden) return;
            if (!window.AI2EditorCore || typeof window.AI2EditorCore.getFileMtime !== 'function') return;
            _checksumInFlight = true;
            window.AI2EditorCore.getFileMtime(filePath).then(function (mtime) {
                if (!mtime) return;
                const last = initAutoRefresh._lastMtime || 0;
                initAutoRefresh._lastMtime = mtime;
                if (last && mtime !== last) {
                    return window.AI2EditorCore.loadFileContent(filePath).then(function (data) {
                        if (data && data.content !== undefined) {
                            const ed = getEditor();
                            if (ed) { ed.setValue(data.content, -1); ed.clearSelection(); }
                            if (lastModEl) lastModEl.textContent = 'updated ' + new Date().toLocaleTimeString();
                            setStatus('Reloaded (external change)');
                        }
                    });
                }
                if (!last) {
                    initAutoRefresh._lastMtime = mtime;
                    if (lastModEl) lastModEl.textContent = 'loaded ' + new Date().toLocaleTimeString();
                }
            }).catch(function () {
            }).then(function () {
                _checksumInFlight = false;
            });
        }, 4000);
    }


    function initModelSelect() {
        const modelSel = document.getElementById('model-select');
        if (!modelSel) return;
        function go() {
            if (!(window.ComservChat && ComservChat.modelSelect)) return false;
            ComservChat.modelSelect.init({
                selectEl: modelSel,
                context: 'code',
                pinModel: 'cohere/north-mini-code:free',
                onReady: function () {
                    console.log('[AI2EditorChat] model-select populated by shared module');
                    if (!modelSel._userPickWired) {
                        modelSel._userPickWired = true;
                        modelSel.addEventListener('change', function () {
                            _userPickedModel = true;
                        });
                    }
                },
                onError: function (e) {
                    console.error('[AI2EditorChat] model-select failed', e);
                    try {
                        modelSel.innerHTML = '';
                        const opt = document.createElement('option');
                        opt.disabled = true;
                        opt.selected = true;
                        opt.textContent = 'Model list unavailable';
                        modelSel.appendChild(opt);
                    } catch (err) { /* ignore */ }
                }
            });
            return true;
        }
        if (go()) return;
        // Defer script order race: retry briefly
        let n = 0;
        const t = setInterval(function () {
            n++;
            if (go() || n >= 40) clearInterval(t);
        }, 100);
    }

    function wire() {
        // Models first so a later throw cannot leave "Loading models…" forever.
        initModelSelect();

        const sendBtn = document.getElementById('ai-chat-send');
        const input = document.getElementById('ai-chat-input');
        const approve = document.getElementById('ai-approve-btn');
        const reject = document.getElementById('ai-reject-btn');
        const clear = document.getElementById('ai-chat-clear');

        if (sendBtn && input) {
            function fireAttached() {
                const v = (input.value || '').trim();
                if (!v) return;
                input.value = '';
                autosizePrompt(input);
                try {
                    sendPrompt(v);
                } catch (err) {
                    console.error('[AI2EditorChat] send failed', err);
                    setStatus('Send failed: ' + (err && err.message ? err.message : err), true);
                    recordMessage('AI', '<span style="color:#f66">Send failed: ' + escapeHtml(String(err && err.message ? err.message : err)) + '</span>');
                }
            }
            sendBtn.addEventListener('click', fireAttached);
            wirePromptBox(input, fireAttached);
        }
        if (approve) approve.addEventListener('click', approveSuggestion);
        if (reject) reject.addEventListener('click', rejectSuggestion);
        if (clear && input) clear.addEventListener('click', function () {
            _clarifySession = null;
            chatLog = [];   // reset the shared log (both views re-render empty)
            renderChatLog(document.getElementById('chat-messages'));
            const w = window._aiChatWin;
            if (w && !w.closed) renderChatLog(w.document.getElementById('chat-messages'));
            input.value = '';
        });

        initResize();
        initDetach();
        initClose();
        applyViewState();   // ensure correct initial view (attached by default)

        // model-select: see initModelSelect() at top of wire()

        // "Add Todo" chat feature (shared module) — attaches to the current page's project.
        const todoBtn = document.getElementById('ai-chat-todo');
        if (todoBtn && window.ComservChat && ComservChat.featureTodo) {
            todoBtn.addEventListener('click', function () {
                ComservChat.featureTodo.open({
                    pagePath: currentFilePath() || window.location.pathname,
                    pageTitle: (currentFilePath() ? currentFilePath().split('/').pop() : document.title) || '',
                    prefill: lastAiText()
                });
            });
        }

        // Keep the dirty flag in sync after an Approve applies a suggestion.
        const editor = getEditor();
        if (editor) {
            editor.session.on('change', function () { _dirty = true; });
        }

        // Apply shared tooltip map to this widget's buttons.
        if (window.ComservChat && ComservChat.tooltips) ComservChat.tooltips.apply(document);


        // Agent + phase controls (minimal analyze → plan → verify → implement UI)
        const agentSel = document.getElementById('ai-editor-agent');
        const phaseSel = document.getElementById('ai-editor-phase');
        const verifyBtn = document.getElementById('ai-editor-verify');
        if (agentSel && !agentSel._wired) {
            agentSel._wired = true;
            agentSel.addEventListener('change', function () {
                _planApproved = false;
                setEditorPhase((agentSel.value === 'documentation' || agentSel.value === 'analyze') ? 'analyze' : currentEditorPhase());
                recordMessage('AI', '<em>Switched agent to ' + escapeHtml(agentSel.value) + '. Flow: analyze → plan → Verify → implement.</em>');
            });
        }
        if (phaseSel && !phaseSel._wired) {
            phaseSel._wired = true;
            phaseSel.addEventListener('change', function () {
                setEditorPhase(phaseSel.value);
            });
            setEditorPhase(phaseSel.value || 'analyze');
        }
        if (verifyBtn && !verifyBtn._wired) {
            verifyBtn._wired = true;
            verifyBtn.addEventListener('click', function () {
                _planApproved = true;
                setEditorPhase('implement');
                recordMessage('You', escapeHtml('approve plan'));
                recordMessage('AI', '<em>Plan verified. Phase → implement. Ask for the code change (or Send again).</em>');
                if (typeof setStatus === 'function') setStatus('Plan approved — implement phase');
            });
        }

        console.log('[AI2EditorChat] chat + suggestion wiring ready');
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () { wire(); initAutoRefresh(); });
    } else {
        wire();
        initAutoRefresh();
    }

    console.log('%c[AI2] chat module ready', 'color:#0a0');
    window.AI2Chat = {
        setActiveFile: setActiveFile,
        setClosed: function (v) { _closed = !!v; applyViewState(); },
        isClosed: function () { return !!_closed; },
        isDetached: function () { return !!_detached; },
        reattach: function () {
            _detached = false;
            if (window._aiChatWin && !window._aiChatWin.closed) {
                try { window._aiChatWin.close(); } catch (e) {}
                window._aiChatWin = null;
            }
            applyViewState();
        },
        // Exposed for core.js early preload and external use during AI2 refactor / testing.
        preloadRelatedPipeline: preloadRelatedPipeline
    };
    window[NS] = window.AI2Chat;
})();
