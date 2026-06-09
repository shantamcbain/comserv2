/**
 * AI Code Editor — Shanta admin workspace (/ai/editing_widget)
 * File tree + editor + integrated coding-agent chat.
 */
(function() {
    'use strict';

    var state = {
        currentPath: '',
        currentContent: '',
        dirty: false,
        chatHistory: [],
        conversationId: null,
        provider: 'grok',
        pendingReadFile: null,
    };

    function $(id) { return document.getElementById(id); }

    function setStatus(msg, type) {
        var el = $('aew-status');
        if (!el) return;
        el.textContent = msg || '';
        el.className = 'aew-status' + (type ? ' ' + type : '');
    }

    function escapeHtml(s) {
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    function fetchJson(url, opts) {
        opts = opts || {};
        opts.credentials = 'include';
        return fetch(url, opts).then(function(r) { return r.json(); });
    }

    // ── File tree ───────────────────────────────────────────────────────────
    var treeExpanded = {};

    function makeTreeRow(ent, depth) {
        var row = document.createElement('div');
        row.className = 'aew-tree-item' + (ent.type === 'dir' ? ' dir' : '');
        if (ent.path === state.currentPath) row.classList.add('active');
        var indent = '';
        for (var i = 0; i < depth; i++) indent += '<span class="aew-tree-indent"></span>';
        var open = treeExpanded[ent.path];
        row.innerHTML = indent
            + (ent.type === 'dir' ? (open ? '📂 ' : '📁 ') : '📄 ')
            + escapeHtml(ent.name);
        row.onclick = function(e) {
            e.stopPropagation();
            if (ent.type === 'dir') toggleDir(ent.path, depth);
            else loadFile(ent.path);
        };
        return row;
    }

    function fillTreeContainer(container, dir, depth, seq) {
        dir = (dir == null || dir === undefined) ? '' : String(dir);
        fetchJson('/ai/list_dir?rel=' + encodeURIComponent(dir))
            .then(function(data) {
                if (seq !== treeSeq) return;
                if (!data.success) {
                    setStatus(data.error || 'list_dir failed', 'err');
                    return;
                }
                container.innerHTML = '';
                (data.entries || []).forEach(function(ent) {
                    container.appendChild(makeTreeRow(ent, depth));
                    if (ent.type === 'dir') {
                        var childBox = document.createElement('div');
                        childBox.className = 'aew-tree-children';
                        childBox.dataset.rel = ent.path;
                        childBox.style.display = treeExpanded[ent.path] ? 'block' : 'none';
                        container.appendChild(childBox);
                        if (treeExpanded[ent.path]) {
                            fillTreeContainer(childBox, ent.path, depth + 1, seq);
                        }
                    }
                });
            })
            .catch(function(e) { setStatus('Tree error: ' + e, 'err'); });
    }

    var treeSeq = 0;

    function refreshTree() {
        var root = $('aew-tree');
        if (!root) return;
        treeSeq += 1;
        var seq = treeSeq;
        treeExpanded = { lib: true };
        root.innerHTML = '';
        fillTreeContainer(root, '', 0, seq);
    }

    function toggleDir(path, depth) {
        treeExpanded[path] = !treeExpanded[path];
        refreshTree();
    }

    // ── Editor ──────────────────────────────────────────────────────────────
    function loadFile(path, lineNum) {
        if (state.dirty && !confirm('Discard unsaved changes to ' + state.currentPath + '?')) {
            return;
        }
        setStatus('Loading ' + path + '…');
        fetchJson('/ai/read_file?path=' + encodeURIComponent(path) + '&limit=800')
            .then(function(data) {
                if (!data.success) {
                    setStatus(data.error || 'read failed', 'err');
                    return;
                }
                state.currentPath = data.path;
                state.currentContent = data.content;
                state.dirty = false;
                $('aew-editor').value = data.content;
                $('aew-editor-path').textContent = data.path + ' (' + data.total + ' lines)';
                setStatus('Loaded ' + data.path, 'ok');
                refreshTree();
                if (lineNum) {
                    setTimeout(function() {
                        scrollToLine(lineNum);
                    }, 50);
                }
            })
            .catch(function(e) { setStatus('Load error: ' + e, 'err'); });
    }

    function scrollToLine(lineNum) {
        var textarea = $('aew-editor');
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
            if (window.opener && !window.opener.closed) {
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
            var input = $('aew-chat-input');
            if (input) {
                input.value = promptText;
                input.focus();
            }
            addMessage("Detected error source on parent page. Loaded file: " + errInfo.path + (errInfo.lineNum ? " (line " + errInfo.lineNum + ")" : ""), "system");
        }
    }

    function saveFile() {
        if (!state.currentPath) {
            setStatus('No file open', 'err');
            return;
        }
        var content = $('aew-editor').value;
        var btn = $('aew-save-btn');
        if (btn) btn.disabled = true;
        fetch('/ai/apply_fix', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: 'path=' + encodeURIComponent(state.currentPath)
                + '&content=' + encodeURIComponent(content),
        })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            if (btn) btn.disabled = false;
            if (data.success) {
                state.currentContent = content;
                state.dirty = false;
                setStatus('Saved ' + state.currentPath + ' (backup: ' + (data.backup || '.bak') + ')', 'ok');
            } else {
                setStatus('Save failed: ' + (data.error || 'unknown'), 'err');
            }
        })
        .catch(function(e) {
            if (btn) btn.disabled = false;
            setStatus('Save error: ' + e, 'err');
        });
    }

    // ── Chat ────────────────────────────────────────────────────────────────
    function addMessage(text, role) {
        var box = $('aew-messages');
        if (!box) return;
        var div = document.createElement('div');
        div.className = 'aew-msg aew-msg-' + role;
        div.textContent = text;
        box.appendChild(div);
        box.scrollTop = box.scrollHeight;
    }

    function parseFixBlock(raw) {
        var re = /##\s*FIX:\s*([^\n\r]+)[\r\n]+```[^\n\r]*\n([\s\S]*?)```/i;
        var m = raw.match(re);
        if (!m) return null;
        return { path: m[1].trim(), content: m[2] };
    }

    function showFixPanel(fix) {
        var box = $('aew-messages');
        var panel = document.createElement('div');
        panel.className = 'aew-fix-panel';
        panel.innerHTML = '<strong>Proposed fix:</strong> ' + escapeHtml(fix.path)
            + '<pre>' + escapeHtml(fix.content.slice(0, 2000)) + (fix.content.length > 2000 ? '\n…' : '') + '</pre>';
        var applyBtn = document.createElement('button');
        applyBtn.className = 'aew-btn aew-btn-success';
        applyBtn.textContent = 'Apply Fix';
        applyBtn.onclick = function() {
            if (!confirm('Apply AI fix to ' + fix.path + '?')) return;
            fetch('/ai/apply_fix', {
                method: 'POST',
                credentials: 'include',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: 'path=' + encodeURIComponent(fix.path)
                    + '&content=' + encodeURIComponent(fix.content),
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.success) {
                    addMessage('Applied fix to ' + fix.path, 'system');
                    if (fix.path === state.currentPath) {
                        state.currentContent = fix.content;
                        state.dirty = false;
                        $('aew-editor').value = fix.content;
                    }
                    setStatus('Fix applied', 'ok');
                } else {
                    setStatus('Apply failed: ' + data.error, 'err');
                }
            });
        };
        panel.appendChild(applyBtn);
        box.appendChild(panel);
        box.scrollTop = box.scrollHeight;
    }

    function handleReadFileRequest(path) {
        fetchJson('/ai/read_file?path=' + encodeURIComponent(path.trim()) + '&limit=400')
            .then(function(data) {
                if (data.success) {
                    var ctx = '[FILE: ' + data.path + ']\n```\n' + data.content + '\n```\n[/FILE]\n\n'
                        + '(File loaded — continue analysis.)';
                    sendChat(ctx, true);
                } else {
                    addMessage('Could not read: ' + data.error, 'system');
                }
            });
    }

    function buildPrompt(userText) {
        var parts = [];
        if (state.currentPath && state.currentContent) {
            parts.push('[FILE: ' + state.currentPath + ']\n```\n' + state.currentContent + '\n```\n[/FILE]\n\n');
        }
        parts.push(userText);
        return parts.join('');
    }

    function sendChat(userText, isFollowUp) {
        if (!userText.trim()) return;
        if (!isFollowUp) {
            addMessage(userText, 'user');
            state.chatHistory.push({ role: 'user', content: userText });
        }
        var prompt = isFollowUp ? userText : buildPrompt(userText);
        var provider = ($('aew-provider') && $('aew-provider').value) || 'grok';
        setStatus('AI thinking…');
        $('aew-send-btn').disabled = true;

        var body = {
            prompt: prompt,
            history: state.chatHistory.slice(-20),
            agent_id: 'coding',
            provider: provider,
            page_path: '/ai/editing_widget',
            page_title: 'AI Code Editor',
        };
        if (state.conversationId) body.conversation_id = state.conversationId;

        fetch('/ai/chat', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            $('aew-send-btn').disabled = false;
            if (!data.success) {
                addMessage('Error: ' + (data.error || 'request failed'), 'system');
                setStatus(data.error || 'chat error', 'err');
                return;
            }
            if (data.conversation_id) state.conversationId = data.conversation_id;
            var reply = data.response || '';
            addMessage(reply, 'ai');
            state.chatHistory.push({ role: 'assistant', content: reply });
            setStatus('Ready', 'ok');

            var rf = reply.match(/\[READ_FILE:\s*([^\]]+)\]/i);
            if (rf) handleReadFileRequest(rf[1]);

            var fix = parseFixBlock(reply);
            if (fix) showFixPanel(fix);
        })
        .catch(function(e) {
            $('aew-send-btn').disabled = false;
            addMessage('Request failed: ' + e, 'system');
            setStatus('Network error', 'err');
        });
    }

    function loadProviders() {
        fetchJson('/ai/get_user_providers')
            .then(function(data) {
                var sel = $('aew-provider');
                if (!sel || !data.success || !data.providers) return;
                sel.innerHTML = '';
                data.providers.forEach(function(p) {
                    if (p.service === 'grok') {
                        var o = document.createElement('option');
                        o.value = 'grok';
                        o.textContent = 'Grok (cloud)';
                        sel.appendChild(o);
                    }
                    if (p.service === 'ollama') {
                        var o2 = document.createElement('option');
                        o2.value = 'ollama';
                        o2.textContent = 'Ollama (local)';
                        sel.appendChild(o2);
                    }
                });
            })
            .catch(function() {});
    }

    // ── Init ────────────────────────────────────────────────────────────────
    function init() {
        refreshTree();
        loadProviders();

        $('aew-save-btn').onclick = saveFile;
        $('aew-reload-btn').onclick = function() {
            if (state.currentPath) loadFile(state.currentPath);
        };
        $('aew-refresh-tree').onclick = refreshTree;

        $('aew-editor').addEventListener('input', function() {
            state.dirty = $('aew-editor').value !== state.currentContent;
        });

        $('aew-send-btn').onclick = function() {
            var input = $('aew-chat-input');
            var text = (input.value || '').trim();
            if (!text) return;
            input.value = '';
            sendChat(text, false);
        };

        $('aew-chat-input').addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                $('aew-send-btn').click();
            }
        });

        var params = new URLSearchParams(window.location.search);
        var openFile = params.get('file');
        if (openFile) loadFile(openFile);

        var openPrompt = params.get('prompt');
        if (openPrompt) {
            setTimeout(function() { sendChat(openPrompt, false); }, 500);
        }

        addMessage('AI Code Editor ready. Open a file from the tree or ask a coding question.', 'system');
        checkForErrorSourceAndLoad();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();