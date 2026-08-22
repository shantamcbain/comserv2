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

    function setActiveFile(path) {
        _activeFile = path || '';
        if (path) window.AI2_FILE_TO_LOAD = path;
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
    let chatLog = [];   // [{who:'You'|'AI', html:'...'}]

    function renderChatLog(box) {
        if (!box) return;
        box.innerHTML = '';
        if (!chatLog.length) {
            box.innerHTML = '<div><strong>AI:</strong> How can I help with this file?</div>';
            return;
        }
        for (let i = 0; i < chatLog.length; i++) {
            const e = chatLog[i];
            const div = document.createElement('div');
            div.style.marginBottom = '8px';
            div.innerHTML = '<strong>' + (e.who === 'AI' ? 'AI:' : 'You:') + '</strong> ' + e.html;
            box.appendChild(div);
        }
        box.scrollTop = box.scrollHeight;
    }

    // The single place a message is recorded + shown in whichever view is live.
    function recordMessage(who, html) {
        chatLog.push({ who: who, html: html });
        const attachedBox = document.getElementById('chat-messages');
        if (attachedBox && sidebarAttached()) renderChatLog(attachedBox);
        const w = window._aiChatWin;
        if (w && !w.closed) {
            const dBox = w.document.getElementById('chat-messages');
            if (dBox) renderChatLog(dBox);
        }
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
                '#chat-input{flex:1;padding:6px;border:1px solid #555;border-radius:3px;background:#1e1f22;color:#ddd;}' +
                '#send{background:#0e639c;color:#fff;border:none;padding:4px 12px;border-radius:3px;cursor:pointer;}' +
                '.bar{display:flex;gap:6px;padding:6px;border-top:1px solid #555;}' +
                'h3{margin:0;padding:8px;background:#2b2b2b;font-size:13px;display:flex;justify-content:space-between;align-items:center;}' +
                '#attach{background:transparent;border:1px solid #555;color:#aaa;border-radius:3px;cursor:pointer;font-size:11px;padding:1px 6px;}</style>' +
                '</head><body>' +
                '<h3>AI Chat (Hy3) — detached <button id="attach">⊞ Attach</button></h3>' +
                '<div id="chat-messages"></div>' +
                '<div class="bar"><input id="chat-input" placeholder="Ask AI about the open file...">' +
                '<button id="send">Send</button></div>' +
                '</body></html>'
            );
            w.document.close();
            renderChatLog(w.document.getElementById('chat-messages'));

            const dInput = w.document.getElementById('chat-input');
            const dSend = w.document.getElementById('send');
            const dMsgs = w.document.getElementById('chat-messages');
            const target = {
                messages: dMsgs,
                input: dInput,
                sendBtn: dSend,
                status: function () { /* detached window has no status bar */ }
            };
            function fire() {
                const v = dInput.value;
                dInput.value = '';
                sendPrompt(v, target);
            }
            dSend.addEventListener('click', fire);
            dInput.addEventListener('keydown', function (e) { if (e.key === 'Enter') fire(); });

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

        // Record to the shared chat log (survives attach/detach).
        recordMessage('You', escapeHtml(prompt));

        if (sendBtn) { sendBtn.disabled = true; sendBtn.textContent = '...'; }

        // Disk-capability questions must NEVER reach Hy3.
        if (isDiskCapabilityPrompt(prompt)) {
            if (target.status) target.status('Live reading project tree...');
            liveAnswerDiskQuestion(prompt, target, sendBtn);
            return;
        }

        if (target.status) target.status('Asking AI...');

        // The editor is a coding context. The model is chosen from the shared
        // #model-select (populated by ai-chat/model-select.js), defaulting to
        // hy3 — the same code path the general "Chat with AI" widget uses, so
        // the two chat UIs can never diverge on model selection again.
        const model = (window.ComservChat && ComservChat.modelSelect)
            ? ComservChat.modelSelect.getSelectedValue()
            : 'tencent/hy3';
        const filePath = currentFilePath();

        loadCurrentFileContent().then(function (fileContent) {
            const wantEval = isEvaluatePrompt(prompt);
            const filesP = wantEval
                ? loadFilesForEval(filePath, fileContent)
                : Promise.resolve(fileContent && fileContent.length
                    ? [{ path: filePath, content: fileContent }] : []);
            return filesP.then(function (files) {
                const blob = filesToPromptBlob(files);
                const fullPrompt = blob
                    ? (prompt + '\n\n---\nThese files were loaded live from this app via GET /ai2/load_file. They ARE in this message. Never say you cannot see them or ask the user to paste.\n\n' + blob)
                    : prompt;
                if (target.status && files.length) {
                    target.status('Loaded ' + files.map(function (f) { return f.path; }).join(', '));
                }
                return fetch('/ai2/chat', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        prompt: fullPrompt,
                        model: model,
                        agent_id: 'code',
                        page_path: filePath || (files[0] && files[0].path) || '',
                        page_title: filePath ? filePath.split('/').pop() : '',
                        page_content: (files[0] && files[0].content) || fileContent || ''
                    })
                });
            });
        }).then(function (res) { return res.json(); })
          .then(function (data) {
              if (sendBtn) { sendBtn.disabled = false; sendBtn.textContent = 'Send'; }
              if (!data || data.success === 0 || data.error) {
                  const err = (data && data.error) ? data.error : 'No response';
                  recordMessage('AI', '<span style="color:#f66">' + escapeHtml(err) + '</span>');
                  if (target.status) target.status('AI error: ' + err, true);
                  return;
              }
              const usedModel = (data.model ? data.model + (data.provider ? ' (' + data.provider + ')' : '') : EDITOR_MODEL);
              const resp = data.response || '';
              if (data.files_read && data.files_read.length) {
                  recordMessage('AI', '<span style="color:#7fb7ff;font-size:0.85em;">[read ' + escapeHtml(data.files_read.join(', ')) + ']</span>');
                  if (target.status) target.status('Read ' + data.files_read.join(', '));
              }
              const extracted = (window.ComservChat && ComservChat.featureTodo && ComservChat.featureTodo.extractActions)
                  ? ComservChat.featureTodo.extractActions(resp)
                  : { cleanText: resp, actions: [] };
              const display = extracted.cleanText || resp;
              // Prefix the reply with the model actually used, for transparency.
              recordMessage('AI', '<span style="color:#7fb7ff;font-size:0.85em;">[' + escapeHtml(usedModel) + ']</span> ' + escapeHtml(display).replace(/\n/g, '<br>'));

              if (data.todo_action && window.ComservChat && ComservChat.featureTodo
                  && typeof ComservChat.featureTodo.handleServerResult === 'function') {
                  ComservChat.featureTodo.handleServerResult(data.todo_action, {
                      host: document.getElementById('chat-messages'),
                      status: target.status,
                      pagePath: currentFilePath() || window.location.pathname
                  });
              }

              if (extracted.actions && extracted.actions.length && window.ComservChat.featureTodo.handleAction) {
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
              if (block) {
                  // A suggestion is always applied to the MAIN editor window,
                  // even when chat is detached into its own window.
                  showSuggestion(block.code);
                  if (target.status) target.status('Suggestion ready (' + usedModel + ')');
              } else {
                  if (target.status) target.status('Replied (no code suggestion)');
              }
          })
          .catch(function (err) {
              if (sendBtn) { sendBtn.disabled = false; sendBtn.textContent = 'Send'; }
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

    function markDirty() { _dirty = true; }
    function markClean() { _dirty = false; }

    function initAutoRefresh() {
        const filePath = currentFilePath();
        const lastModEl = document.getElementById('last-modified');
        const statusEl = document.getElementById('auto-refresh-status');
        if (statusEl) statusEl.textContent = 'Auto-refresh: ON (4s)';
        if (!filePath) {
            if (statusEl) statusEl.textContent = 'Auto-refresh: off (no file)';
            return;
        }

        const editor = getEditor();
        if (editor) {
            editor.session.on('change', function () { _dirty = true; });
        }

        _autoTimer = setInterval(function () {
            if (_dirty) return;   // don't overwrite unsaved work
            window.AI2EditorCore.getFileMtime(filePath).then(function (mtime) {
                if (!mtime) return;
                const last = initAutoRefresh._lastMtime || 0;
                initAutoRefresh._lastMtime = mtime;
                if (last && mtime !== last) {
                    // File changed on disk — reload it
                    window.AI2EditorCore.loadFileContent(filePath).then(function (data) {
                        if (data && data.content !== undefined) {
                            const ed = getEditor();
                            if (ed) { ed.setValue(data.content, -1); ed.clearSelection(); }
                            if (lastModEl) lastModEl.textContent = 'updated ' + new Date().toLocaleTimeString();
                            setStatus('Reloaded (external change)');
                        }
                    }).catch(function () {});
                } else if (!last) {
                    initAutoRefresh._lastMtime = mtime;
                    if (lastModEl) lastModEl.textContent = 'loaded ' + new Date().toLocaleTimeString();
                }
            }).catch(function () {});
        }, 4000);
    }

    function wire() {
        const sendBtn = document.getElementById('ai-chat-send');
        const input = document.getElementById('ai-chat-input');
        const approve = document.getElementById('ai-approve-btn');
        const reject = document.getElementById('ai-reject-btn');
        const clear = document.getElementById('ai-chat-clear');

        if (sendBtn && input) {
            sendBtn.addEventListener('click', function () {
                const v = input.value;
                input.value = '';
                sendPrompt(v);
            });
            input.addEventListener('keydown', function (e) {
                if (e.key === 'Enter') {
                    const v = input.value;
                    input.value = '';
                    sendPrompt(v);
                }
            });
        }
        if (approve) approve.addEventListener('click', approveSuggestion);
        if (reject) reject.addEventListener('click', rejectSuggestion);
        if (clear && input) clear.addEventListener('click', function () {
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
        applyClosedState();

        // Populate the editor's #model-select from the SHARED model-selection
        // module (same catalog + hy3 default the general widget uses).
        const modelSel = document.getElementById('model-select');
        if (modelSel && window.ComservChat && ComservChat.modelSelect) {
            ComservChat.modelSelect.init({
                selectEl: modelSel,
                context: 'code',
                pinModel: 'tencent/hy3',
                onReady: function () {
                    console.log('[AI2EditorChat] model-select populated by shared module');
                },
                onError: function (e) { console.error('[AI2EditorChat] model-select failed', e); }
            });
        }

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

        console.log('[AI2EditorChat] chat + suggestion wiring ready');
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () { wire(); initAutoRefresh(); });
    } else {
        wire();
        initAutoRefresh();
    }

    console.log('%c[AI2] chat module ready', 'color:#0a0');
    window.AI2Chat = { setActiveFile: setActiveFile };
    window[NS] = window.AI2Chat;
})();
