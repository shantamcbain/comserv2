/**
 * Floating AI Code Editor — Grok CLI + file tree (not Comserv /ai/chat by default).
 * Toggle: window.AEW.open() / AEW.close() / AEW.toggle()
 */
(function() {
    'use strict';

    if (window.AEW && window.AEW._loaded) return;

    var state = {
        enabled: false,
        open: false,
        inline: false,
        popupWindow: null,
        currentPath: '',
        currentContent: '',
        dirty: false,
        chatHistory: [],
        backend: 'grok_cli',
        treeExpanded: {},
        treeSeq: 0,
    };

    function q(sel, root) {
        return (root || document).querySelector(sel);
    }

    function setStatus(msg, type) {
        var el = q('#aew-status');
        if (!el) return;
        el.textContent = msg || '';
        el.style.color = type === 'err' ? '#f48771' : (type === 'ok' ? '#89d185' : '#888');
    }

    function fetchJson(url, opts) {
        opts = opts || {};
        opts.credentials = 'include';
        return fetch(url, opts).then(function(r) { return r.json(); });
    }

    function escapeHtml(s) {
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    function buildDom() {
        if (q('#aew-launcher-wrap')) return;

        var wrap = document.createElement('div');
        wrap.id = 'aew-launcher-wrap';
        wrap.innerHTML =
            '<button type="button" id="aew-launcher" title="AI Code Editor (Grok CLI)">💻 Code + Grok</button>';

        var panel = document.createElement('div');
        panel.id = 'aew-panel';
        panel.innerHTML =
            '<div id="aew-panel-header">' +
              '<span id="aew-drag-handle" title="Drag">⠿</span>' +
              '<span id="aew-panel-title">AI Code Editor</span>' +
              '<span id="aew-panel-sub">Grok CLI · floating</span>' +
              '<select id="aew-backend" title="AI backend" style="font-size:0.72rem;margin-left:6px;">' +
                '<option value="grok_cli">Grok CLI (Cursor)</option>' +
                '<option value="comserv">Comserv AI (Ollama/Grok API)</option>' +
              '</select>' +
              '<button type="button" class="aew-btn" id="aew-popout" title="Open in separate window (move to another monitor)">⤢</button>' +
              '<button type="button" class="aew-btn" id="aew-dock-inline" title="Dock inline on this page">⊞</button>' +
              '<button type="button" class="aew-btn" id="aew-close">✕</button>' +
            '</div>' +
            '<div id="aew-panel-body" class="aew-panel-body">' +
              '<aside class="aew-files">' +
                '<div style="padding:0.3rem;display:flex;gap:0.25rem;">' +
                  '<button type="button" class="aew-btn" id="aew-refresh-tree">↻</button>' +
                  '<button type="button" class="aew-btn aew-btn-primary" id="aew-save-btn">Save</button>' +
                '</div>' +
                '<div class="aew-tree" id="aew-tree"></div>' +
              '</aside>' +
              '<section class="aew-editor-pane">' +
                '<div style="padding:0.25rem 0.4rem;font-size:0.72rem;color:#9cdcfe;" id="aew-editor-path">—</div>' +
                '<textarea class="aew-editor" id="aew-editor" spellcheck="false"></textarea>' +
              '</section>' +
              '<aside class="aew-chat-pane">' +
                '<div class="aew-messages" id="aew-messages"></div>' +
                '<div class="aew-input-row">' +
                  '<textarea id="aew-chat-input" rows="2" placeholder="Ask Grok CLI…"></textarea>' +
                  '<button type="button" class="aew-btn aew-btn-primary" id="aew-send-btn">Send</button>' +
                '</div>' +
                '<div class="aew-status" id="aew-status"></div>' +
              '</aside>' +
            '</div>' +
            '<div id="aew-resize-handle" title="Resize"></div>';

        document.body.appendChild(wrap);
        document.body.appendChild(panel);

        q('#aew-launcher').onclick = function() { AEW.open(); };
        q('#aew-close').onclick = function() { AEW.close(); };
        q('#aew-popout').onclick = function() { AEW.openPopup(); };
        q('#aew-dock-inline').onclick = function() {
            if (window.AEW_POPUP_MODE) {
                window.opener && window.opener.AEW && window.opener.AEW.open({ inline: true });
                window.close();
                return;
            }
            AEW.open({ inline: true });
        };
        q('#aew-save-btn').onclick = saveFile;
        q('#aew-refresh-tree').onclick = refreshTree;
        q('#aew-send-btn').onclick = function() {
            var t = q('#aew-chat-input').value.trim();
            if (!t) return;
            q('#aew-chat-input').value = '';
            sendChat(t);
        };
        q('#aew-chat-input').addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); q('#aew-send-btn').click(); }
        });
        q('#aew-backend').onchange = function() {
            state.backend = q('#aew-backend').value;
            addMsg('Backend: ' + state.backend, 'system');
        };
        q('#aew-editor').addEventListener('input', function() {
            state.dirty = q('#aew-editor').value !== state.currentContent;
        });

        initDrag(panel);
        initResize(panel);
    }

    function initDrag(panel) {
        var handle = q('#aew-panel-header');
        var dragging = false, sx, sy, st, sl;
        handle.addEventListener('mousedown', function(e) {
            if (e.target.closest('button,select,textarea')) return;
            dragging = true;
            sx = e.clientX; sy = e.clientY;
            var r = panel.getBoundingClientRect();
            panel.style.bottom = 'auto';
            panel.style.left = r.left + 'px';
            panel.style.top = r.top + 'px';
            st = r.top; sl = r.left;
            e.preventDefault();
        });
        document.addEventListener('mousemove', function(e) {
            if (!dragging) return;
            panel.style.top = (st + e.clientY - sy) + 'px';
            panel.style.left = (sl + e.clientX - sx) + 'px';
        });
        document.addEventListener('mouseup', function() { dragging = false; });
    }

    function initResize(panel) {
        var rh = q('#aew-resize-handle');
        var resizing = false, sx, sy, sw, sh;
        rh.addEventListener('mousedown', function(e) {
            e.stopPropagation();
            resizing = true;
            sx = e.clientX; sy = e.clientY;
            sw = panel.offsetWidth; sh = panel.offsetHeight;
            e.preventDefault();
        });
        document.addEventListener('mousemove', function(e) {
            if (!resizing) return;
            panel.style.width = Math.max(520, sw + e.clientX - sx) + 'px';
            panel.style.height = Math.max(360, sh + e.clientY - sy) + 'px';
        });
        document.addEventListener('mouseup', function() { resizing = false; });
    }

    function addMsg(text, role) {
        var box = q('#aew-messages');
        if (!box) return;
        var d = document.createElement('div');
        d.className = 'aew-msg aew-msg-' + role;
        d.textContent = text;
        box.appendChild(d);
        box.scrollTop = box.scrollHeight;
    }

    function treeLabel(ent, depth) {
        var ind = '';
        for (var i = 0; i < depth; i++) ind += '  ';
        var open = ent.type === 'dir' && state.treeExpanded[ent.path];
        return ind + (ent.type === 'dir' ? (open ? '📂 ' : '📁 ') : '📄 ') + ent.name;
    }

    function markTreeActive() {
        var root = q('#aew-tree');
        if (!root) return;
        root.querySelectorAll('.aew-tree-item').forEach(function(row) {
            row.classList.toggle('active', row.dataset.rel === state.currentPath);
        });
    }

    function appendTreeEntries(container, dir, depth, seq) {
        dir = (dir == null || dir === undefined) ? '' : String(dir);
        if (/HASH\s*\(\s*0x/i.test(dir) || dir.indexOf('::') >= 0) {
            setStatus('Invalid folder path — refresh the tree (↻)', 'err');
            return Promise.resolve();
        }
        var loadGen = (container._aewLoadGen || 0) + 1;
        container._aewLoadGen = loadGen;
        container.innerHTML = '';
        return fetchJson('/ai/list_dir?rel=' + encodeURIComponent(dir))
            .then(function(data) {
                if (seq !== state.treeSeq || loadGen !== container._aewLoadGen) return;
                if (!data.success) {
                    var msg = data.error || 'list_dir failed';
                    if (data.hint) msg += ' — ' + data.hint;
                    if (data.project_root) msg += ' (root: ' + data.project_root + ')';
                    setStatus(msg, 'err');
                    if (!dir) {
                        container.innerHTML = '<div class="aew-tree-hint">' + escapeHtml(msg) + '</div>';
                    }
                    return;
                }
                if (data.project_root) state.projectRoot = data.project_root;
                (data.entries || []).forEach(function(ent) {
                    var row = document.createElement('div');
                    row.className = 'aew-tree-item' + (ent.type === 'dir' ? ' dir' : '');
                    row.dataset.rel = ent.path;
                    if (ent.path === state.currentPath) row.classList.add('active');
                    row.textContent = treeLabel(ent, depth);

                    var childBox = null;
                    if (ent.type === 'dir') {
                        childBox = document.createElement('div');
                        childBox.className = 'aew-tree-children';
                        childBox.dataset.rel = ent.path;
                        if (!state.treeExpanded[ent.path]) childBox.style.display = 'none';
                    }

                    row.onclick = function(ev) {
                        ev.stopPropagation();
                        if (ent.type === 'dir' && childBox) {
                            state.treeExpanded[ent.path] = !state.treeExpanded[ent.path];
                            row.textContent = treeLabel(ent, depth);
                            if (state.treeExpanded[ent.path]) {
                                childBox.style.display = '';
                                appendTreeEntries(childBox, ent.path, depth + 1, state.treeSeq);
                            } else {
                                childBox.style.display = 'none';
                            }
                        } else {
                            loadFile(ent.path);
                        }
                    };

                    container.appendChild(row);
                    if (childBox) {
                        container.appendChild(childBox);
                        if (state.treeExpanded[ent.path]) {
                            appendTreeEntries(childBox, ent.path, depth + 1, seq);
                        }
                    }
                });
            });
    }

    function refreshTree() {
        var root = q('#aew-tree');
        if (!root) return;
        state.treeSeq += 1;
        var seq = state.treeSeq;
        state.treeExpanded = { lib: true };
        root.innerHTML = '';
        appendTreeEntries(root, '', 0, seq);
    }

    function loadFile(path, lineNum) {
        if (state.dirty && !confirm('Discard unsaved changes?')) return;
        setStatus('Loading…');
        fetchJson('/ai/read_file?path=' + encodeURIComponent(path) + '&limit=800')
            .then(function(data) {
                if (!data.success) { setStatus(data.error, 'err'); return; }
                state.currentPath = data.path;
                state.currentContent = data.content;
                state.dirty = false;
                q('#aew-editor').value = data.content;
                q('#aew-editor-path').textContent = data.path;
                setStatus('Loaded', 'ok');
                markTreeActive();
                if (lineNum) {
                    setTimeout(function() {
                        scrollToLine(lineNum);
                    }, 50);
                }
            });
    }

    function scrollToLine(lineNum) {
        var textarea = q('#aew-editor');
        if (!textarea || !lineNum) return;
        var lines = textarea.value.split('\n');
        var targetLine = parseInt(lineNum, 10);
        if (isNaN(targetLine) || targetLine < 1 || targetLine > lines.length) return;
        var charIndex = 0;
        for (var i = 0; i < targetLine - 1; i++) {
            charIndex += lines[i].length + 1;
        }
        textarea.focus();
        textarea.setSelectionRange(charIndex, charIndex + (lines[targetLine - 1] || '').length);
        var lineHeight = parseFloat(window.getComputedStyle(textarea).lineHeight) || 16;
        textarea.scrollTop = (targetLine - 1) * lineHeight - (textarea.clientHeight / 2);
    }

    function detectPageErrorSource() {
        var doc = document;
        try {
            if (window.AEW_POPUP_MODE && window.opener && !window.opener.closed) {
                doc = window.opener.document;
            }
        } catch (e) {}

        var fileTd = Array.from(doc.querySelectorAll('td, th')).find(function(el) {
            var text = el.textContent.trim();
            return text === 'File:' || text.indexOf('File:') >= 0;
        });
        if (!fileTd) return null;

        var pathTd = fileTd.nextElementSibling;
        if (!pathTd) return null;

        var fullPath = pathTd.textContent.trim();
        if (!fullPath) return null;

        var parts = fullPath.split(':');
        var rawPath = parts[0];
        var lineNum = '';
        if (parts[1] && /^\d+$/.test(parts[1].trim())) {
            lineNum = parts[1].trim();
        }

        var match = rawPath.match(/(?:^|\/)(lib|root|sql|script|t)\/(.+)$/);
        var path = '';
        if (match) {
            path = match[1] + '/' + match[2];
        } else {
            path = rawPath;
        }

        var subject = '';
        var subjectTh = Array.from(doc.querySelectorAll('th, td')).find(function(el) {
            return el.textContent.trim().toLowerCase() === 'subject';
        });
        if (subjectTh && subjectTh.nextElementSibling) {
            subject = subjectTh.nextElementSibling.textContent.trim();
        }

        var desc = '';
        var descTh = Array.from(doc.querySelectorAll('th, td')).find(function(el) {
            return el.textContent.trim().toLowerCase() === 'description';
        });
        if (descTh && descTh.nextElementSibling) {
            desc = descTh.nextElementSibling.textContent.trim();
        }

        return {
            path: path,
            lineNum: lineNum,
            subject: subject,
            description: desc
        };
    }

    function checkForErrorSourceAndLoad() {
        var errInfo = detectPageErrorSource();
        if (errInfo && errInfo.path) {
            loadFile(errInfo.path, errInfo.lineNum);
            var promptText = "I encountered an error:\n" +
                             "File: " + errInfo.path + (errInfo.lineNum ? " (line " + errInfo.lineNum + ")" : "") + "\n";
            if (errInfo.subject) {
                promptText += "Subject: " + errInfo.subject + "\n";
            }
            if (errInfo.description) {
                promptText += "Details:\n" + errInfo.description + "\n";
            }
            promptText += "\nPlease analyze the code around the error source and help me fix it.";
            var input = q('#aew-chat-input');
            if (input) {
                input.value = promptText;
                input.focus();
            }
            addMsg("Detected error source on parent page. Loaded file: " + errInfo.path + (errInfo.lineNum ? " (line " + errInfo.lineNum + ")" : ""), "system");
        }
    }

    function saveFile() {
        if (!state.currentPath) return;
        var content = q('#aew-editor').value;
        fetch('/ai/apply_fix', {
            method: 'POST', credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: 'path=' + encodeURIComponent(state.currentPath) + '&content=' + encodeURIComponent(content),
        }).then(function(r) { return r.json(); }).then(function(data) {
            if (data.success) {
                state.currentContent = content;
                state.dirty = false;
                setStatus('Saved', 'ok');
            } else {
                setStatus(data.error, 'err');
            }
        });
    }

    function buildPrompt(userText) {
        var parts = [];
        if (state.chatHistory.length) {
            parts.push('--- Conversation ---\n');
            state.chatHistory.slice(-10).forEach(function(m) {
                parts.push((m.role === 'user' ? 'User: ' : 'Assistant: ') + m.content + '\n');
            });
            parts.push('--- End ---\n\n');
        }
        if (state.currentPath && state.currentContent) {
            parts.push('[FILE: ' + state.currentPath + ']\n```\n' + state.currentContent + '\n```\n[/FILE]\n\n');
        }
        parts.push('User: ' + userText);
        return parts.join('');
    }

    function buildGrokCliPrompt(userText) {
        var parts = [];
        var turns = state.chatHistory.filter(function(m) {
            return (m.role === 'user' || m.role === 'assistant')
                && m.content && !/^Error:/i.test(m.content);
        }).slice(-4);
        if (turns.length) {
            turns.forEach(function(m) {
                parts.push((m.role === 'user' ? 'User: ' : 'Assistant: ') + m.content + '\n\n');
            });
        }
        if (state.currentPath && state.currentContent) {
            var snippet = state.currentContent;
            if (snippet.length > 12000) {
                snippet = snippet.slice(0, 12000) + '\n... (truncated)';
            }
            parts.push('[FILE: ' + state.currentPath + ']\n```\n' + snippet + '\n```\n\n');
        }
        parts.push(userText);
        return parts.join('');
    }

    function openerContext() {
        var path = window.location.pathname;
        var title = document.title || '';
        try {
            if (window.opener && !window.opener.closed) {
                path = window.opener.location.pathname || path;
                title = window.opener.document.title || title;
            }
        } catch (e) { /* cross-origin */ }
        return { page_path: path, page_title: title };
    }

    function sendChatGrokCli(prompt) {
        setStatus('Grok CLI running…');
        q('#aew-send-btn').disabled = true;
        var ctx = openerContext();
        var body = 'prompt=' + encodeURIComponent(prompt)
            + '&page_path=' + encodeURIComponent(ctx.page_path)
            + '&page_title=' + encodeURIComponent(ctx.page_title);
        return fetch('/ai/grok_cli', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: body,
        })
        .then(function(r) { return r.json(); })
        .finally(function() { q('#aew-send-btn').disabled = false; });
    }

    function sendChatComserv(prompt) {
        setStatus('Comserv AI…');
        q('#aew-send-btn').disabled = true;
        return fetch('/ai/chat', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                prompt: prompt,
                agent_id: 'coding',
                history: state.chatHistory.slice(-20),
                page_path: window.location.pathname,
            }),
        })
        .then(function(r) { return r.json(); })
        .finally(function() { q('#aew-send-btn').disabled = false; });
    }

    function sendChat(userText) {
        addMsg(userText, 'user');
        state.chatHistory.push({ role: 'user', content: userText });
        var full = state.backend === 'comserv' ? buildPrompt(userText) : buildGrokCliPrompt(userText);
        var req = state.backend === 'comserv' ? sendChatComserv(full) : sendChatGrokCli(full);
        req.then(function(data) {
            if (!data.success) {
                var err = data.error || 'failed';
                if (data.hint) err += '\n' + data.hint;
                if (data.stderr) err += '\n' + data.stderr;
                if (data.grok) err += '\n(binary: ' + data.grok + ', cwd: ' + (data.cwd || '?') + ')';
                addMsg('Error: ' + err, 'system');
                setStatus(data.error || 'grok error', 'err');
                return;
            }
            var reply = data.response || '';
            addMsg(reply, 'ai');
            state.chatHistory.push({ role: 'assistant', content: reply });
            var backendLabel = data.backend === 'grok_api' ? 'Grok xAI API' : (data.backend || state.backend);
            setStatus(backendLabel + ' done', 'ok');
            var rf = reply.match(/\[READ_FILE:\s*([^\]]+)\]/i);
            if (rf) loadFile(rf[1].trim());
        }).catch(function(e) {
            addMsg('Network error: ' + e, 'system');
            setStatus(String(e), 'err');
        });
    }

    function ensureOnBody() {
        var panel = q('#aew-panel');
        var wrap = q('#aew-launcher-wrap');
        if (panel && panel.parentNode !== document.body) {
            document.body.appendChild(panel);
        }
        if (wrap && wrap.parentNode !== document.body) {
            document.body.appendChild(wrap);
        }
    }

    function openPanel() {
        buildDom();
        ensureOnBody();
        var panel = q('#aew-panel');
        panel.classList.add('open');
        state.open = true;
        state.inline = true;
        document.body.classList.add('aew-inline-open');
        sessionStorage.setItem('aew_open', 'inline');
        if (!q('#aew-messages').childElementCount && !window.AEW_POPUP_MODE) {
            addMsg('Inline dock — use ⤢ for a separate window (recommended).', 'system');
        }
        refreshTree();
        checkForErrorSourceAndLoad();
    }

    function closePanel() {
        var p = q('#aew-panel');
        if (p) p.classList.remove('open');
        state.open = false;
        state.inline = false;
        document.body.classList.remove('aew-inline-open');
        sessionStorage.removeItem('aew_open');
    }

    function openPopup() {
        if (state.popupWindow && !state.popupWindow.closed) {
            state.popupWindow.focus();
            return;
        }
        closePanel();
        var w = 920, h = 640;
        var left = Math.max(0, window.screenX + window.outerWidth - w - 40);
        var top  = Math.max(0, window.screenY + 40);
        state.popupWindow = window.open(
            '/ai/editing_widget_popup',
            'aew-grok-editor',
            'width=' + w + ',height=' + h + ',left=' + left + ',top=' + top +
            ',resizable=yes,menubar=no,toolbar=no,location=no,status=no'
        );
        if (!state.popupWindow) {
            addMsg('Popup blocked — allow popups or use ⊞ to dock inline.', 'system');
            openPanel();
        }
    }

    function open(opts) {
        opts = opts || {};
        if (window.AEW_POPUP_MODE || opts.popup) {
            openPanel();
            return;
        }
        if (opts.inline || sessionStorage.getItem('aew_open') === 'inline') {
            openPanel();
        } else {
            openPopup();
        }
    }

    window.AEW = {
        _loaded: true,
        open: open,
        openPopup: openPopup,
        openInline: function() { open({ inline: true }); },
        close: function() {
            closePanel();
            if (state.popupWindow && !state.popupWindow.closed) {
                state.popupWindow.close();
            }
        },
        toggle: function() {
            if (state.popupWindow && !state.popupWindow.closed) {
                state.popupWindow.focus();
            } else if (state.open) {
                closePanel();
            } else {
                open();
            }
        },
        loadFile: loadFile,
        refreshTree: refreshTree,
    };

    fetchJson('/ai/editor_config').then(function(cfg) {
        if (!cfg.success || !cfg.enabled) return;
        state.enabled = true;
        buildDom();
        if (cfg.grok_cli) {
            var authNote = cfg.grok_auth ? (' auth=' + cfg.grok_auth) : '';
            var modeNote = cfg.grok_mode === 'xai_api'
                ? ' — uses xAI API (works from tablet/remote; no local CLI)'
                : ' — local CLI (workstation only)';
            addMsg('Grok: ' + cfg.grok_cli + authNote + modeNote, 'system');
        }
        if (cfg.remote_ok) {
            if (cfg.zerotier_dns_note) {
                addMsg(cfg.zerotier_dns_note, 'system');
            }
            if (cfg.editor_url_workstation_zero) {
                addMsg('Dev (ZT hostname): ' + cfg.editor_url_workstation_zero, 'system');
            }
            if (cfg.editor_url_zerotier) {
                addMsg('Dev (ZT IP): ' + cfg.editor_url_zerotier, 'system');
            }
            addMsg('LAN hostname: ' + (cfg.editor_url_lan || 'http://workstation.local:3001/ai/editing_widget_popup'), 'system');
            if (cfg.ssh_tunnel_cmd) {
                addMsg('SSH: ' + cfg.ssh_tunnel_cmd, 'system');
                addMsg('Tunnel browser: ' + (cfg.editor_url_tunnel || 'http://workstation.local:3001/ai/editing_widget_popup'), 'system');
                addMsg(cfg.tunnel_hosts_hint || 'Tablet hosts: 127.0.0.1 workstation.local', 'system');
            }
            if (cfg.ssh_tunnel_cmd_named) {
                addMsg('SSH alias: ' + cfg.ssh_tunnel_cmd_named + ' (Host ' + (cfg.ssh_config_host || 'comserv-aew') + ')', 'system');
            }
            addMsg('Do not use raw IP 192.168.1.199 — not a configured site domain.', 'system');
        }
        if (cfg.project_root) {
            addMsg('Project root: ' + cfg.project_root + ' — expand lib/ → Comserv/ → Controller/ in the tree.', 'system');
        }
        if (window.AEW_POPUP_MODE) {
            checkForErrorSourceAndLoad();
            return;
        }
        if (sessionStorage.getItem('aew_open') === 'inline') openPanel();
        if (window.location.search.match(/open_aew=(?:1|popup)/)) openPopup();
        if (window.location.search.indexOf('open_aew=inline') >= 0) openPanel();
    }).catch(function() {});
})();