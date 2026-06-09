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
        conversationTurns: [],
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
        row.dataset.rel = ent.path;
        row.dataset.name = ent.name;
        var open = treeExpanded[ent.path];
        row.innerHTML = (ent.type === 'dir' ? (open ? '📂 ' : '📁 ') : '📄 ')
            + escapeHtml(ent.name);
        row.onclick = function(e) {
            e.stopPropagation();
            if (ent.type === 'dir') {
                toggleDir(ent.path, depth);
                var openNow = treeExpanded[ent.path];
                row.innerHTML = (openNow ? '📂 ' : '📁 ') + escapeHtml(row.dataset.name);
            }
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

    function filterTree() {
        var query = (($('aew-tree-search') || {}).value || '').toLowerCase().trim();
        var root = $('aew-tree');
        if (!root) return;
        var items = root.querySelectorAll('.aew-tree-item');
        var childrenContainers = root.querySelectorAll('.aew-tree-children');
        if (!query) {
            items.forEach(function(row) {
                row.style.display = '';
                var rel = row.dataset.rel;
                if (row.classList.contains('dir')) {
                    var open = treeExpanded[rel];
                    row.innerHTML = (open ? '📂 ' : '📁 ') + escapeHtml(row.dataset.name || rel.split('/').pop());
                }
            });
            childrenContainers.forEach(function(box) {
                var rel = box.dataset.rel;
                box.style.display = treeExpanded[rel] ? '' : 'none';
            });
            return;
        }
        childrenContainers.forEach(function(box) {
            box.style.display = 'none';
        });
        var visiblePaths = {};
        items.forEach(function(row) {
            var rel = row.dataset.rel || '';
            var name = (row.dataset.name || rel.split('/').pop()).toLowerCase();
            if (name.indexOf(query) !== -1) {
                row.style.display = '';
                visiblePaths[rel] = true;
                var parts = rel.split('/');
                while (parts.length > 0) {
                    parts.pop();
                    if (parts.length > 0) {
                        var parentPath = parts.join('/');
                        visiblePaths[parentPath] = true;
                    }
                }
            } else {
                row.style.display = 'none';
            }
        });
        items.forEach(function(row) {
            var rel = row.dataset.rel || '';
            if (visiblePaths[rel]) {
                row.style.display = '';
                if (row.classList.contains('dir')) {
                    row.innerHTML = '📂 ' + escapeHtml(row.dataset.name || rel.split('/').pop());
                }
            }
        });
        childrenContainers.forEach(function(box) {
            var rel = box.dataset.rel || '';
            if (visiblePaths[rel]) {
                box.style.display = '';
            }
        });
    }

    var treeSeq = 0;

    function refreshTree() {
        var root = $('aew-tree');
        if (!root) return;
        treeSeq += 1;
        var seq = treeSeq;
        if (!treeExpanded || Object.keys(treeExpanded).length === 0) {
            treeExpanded = { lib: true };
        }
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
            } else if (window.parent && window.parent !== window) {
                doc = window.parent.document;
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

    function applyErrorSource(errInfo) {
        if (!errInfo || !errInfo.path) return;
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

    function checkForErrorSourceAndLoad() {
        var errInfo = null;
        try {
            errInfo = detectPageErrorSource();
        } catch (e) {}

        if (errInfo && errInfo.path) {
            applyErrorSource(errInfo);
        } else {
            if (window.opener && !window.opener.closed) {
                window.opener.postMessage({ type: 'AEW_REQUEST_ERROR_SOURCE' }, '*');
            } else if (window.parent && window.parent !== window) {
                window.parent.postMessage({ type: 'AEW_REQUEST_ERROR_SOURCE' }, '*');
            }
        }
    }

    window.addEventListener('message', function(event) {
        if (!event || !event.data) return;
        if (event.data.type === 'AEW_REQUEST_ERROR_SOURCE') {
            var errInfo = null;
            try {
                errInfo = detectPageErrorSource();
            } catch (e) {}
            if (errInfo && event.source) {
                event.source.postMessage({
                    type: 'AEW_RESPONSE_ERROR_SOURCE',
                    errorSource: errInfo
                }, '*');
            }
        } else if (event.data.type === 'AEW_RESPONSE_ERROR_SOURCE') {
            applyErrorSource(event.data.errorSource);
        }
    });

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

    function renderConversation() {
        var box = $('aew-messages');
        if (!box) return;
        box.innerHTML = '';
        var selectEl = $('aew-chat-history-select');
        var selectedVal = selectEl ? selectEl.value : '';
        if (selectedVal) {
            var turnId = parseInt(selectedVal, 10);
            var turn = state.conversationTurns.find(function(t) { return t.id === turnId; });
            if (turn) {
                var dUser = document.createElement('div');
                dUser.className = 'aew-msg aew-msg-user';
                dUser.textContent = turn.user;
                box.appendChild(dUser);
                var dAi = document.createElement('div');
                dAi.className = 'aew-msg aew-msg-ai';
                dAi.textContent = turn.ai;
                box.appendChild(dAi);
            }
        } else {
            state.chatHistory.forEach(function(m) {
                var d = document.createElement('div');
                d.className = 'aew-msg aew-msg-' + m.role;
                d.textContent = m.content;
                box.appendChild(d);
            });
        }
        box.scrollTop = box.scrollHeight;
    }

    function updateHistoryDropdown() {
        var selectEl = $('aew-chat-history-select');
        if (!selectEl) return;
        selectEl.innerHTML = '<option value="">-- Active Conversation (Show All) --</option>';
        state.conversationTurns.forEach(function(turn) {
            var opt = document.createElement('option');
            opt.value = turn.id;
            var label = turn.user.replace(/\s+/g, ' ').trim();
            if (label.length > 35) {
                label = label.substring(0, 35) + '...';
            }
            opt.textContent = 'Q: ' + label;
            selectEl.appendChild(opt);
        });
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
        var selectEl = $('aew-chat-history-select');
        if (selectEl && selectEl.value !== '') {
            selectEl.value = '';
            renderConversation();
        }
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

            var turnIndex = state.conversationTurns.length + 1;
            state.conversationTurns.push({
                id: turnIndex,
                user: userText,
                ai: reply
            });
            updateHistoryDropdown();

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

    function setupDeployTabs() {
        var messages = $('aew-messages');
        if (!messages) return;
        var chatPane = messages.parentNode;
        if (!chatPane) return;

        var tabsHeader = document.createElement('div');
        tabsHeader.className = 'aew-tabs-header';
        tabsHeader.innerHTML = 
            '<button type="button" class="aew-tab-btn active" id="aew-tab-chat">💬 Chat</button>' +
            '<button type="button" class="aew-tab-btn" id="aew-tab-deploy">🚀 Deploy</button>' +
            '<button type="button" class="aew-tab-btn" id="aew-tab-cli">💻 CLI</button>';

        var chatContent = document.createElement('div');
        chatContent.id = 'aew-tab-chat-content';
        chatContent.className = 'aew-tab-content active-tab';

        var historyBar = document.createElement('div');
        historyBar.className = 'aew-chat-history-bar';
        historyBar.innerHTML = 
            '<select id="aew-chat-history-select">' +
              '<option value="">-- Active Conversation (Show All) --</option>' +
            '</select>';
        chatContent.appendChild(historyBar);

        var children = Array.from(chatPane.childNodes);
        children.forEach(function(child) {
            chatContent.appendChild(child);
        });

        var deployContent = document.createElement('div');
        deployContent.id = 'aew-tab-deploy-content';
        deployContent.className = 'aew-tab-content';
        deployContent.innerHTML = 
          '<div class="aew-deploy-form">' +
            '<div class="aew-form-group">' +
              '<label>Git Commit Message:</label>' +
              '<textarea id="aew-deploy-commit-msg" rows="2" placeholder="Enter commit message for on-demand commit..."></textarea>' +
            '</div>' +
            '<div class="aew-form-group-row">' +
              '<div class="aew-form-group">' +
                '<label>Target Host:</label>' +
                '<select id="aew-deploy-target">' +
                  '<option value="production1">Production 1 (Live)</option>' +
                  '<option value="production2">Production 2 (Staging)</option>' +
                '</select>' +
              '</div>' +
            '</div>' +
            '<div class="aew-form-group-row checkbox-row">' +
              '<label><input type="checkbox" id="aew-deploy-vols"> Recreate Volumes</label>' +
              '<label><input type="checkbox" id="aew-deploy-noroll"> No Rollback</label>' +
            '</div>' +
            '<div class="aew-deploy-actions">' +
              '<button type="button" class="aew-btn aew-btn-success" id="aew-btn-commit-deploy">Commit & Deploy</button>' +
              '<button type="button" class="aew-btn" id="aew-btn-deploy-only">Deploy Only</button>' +
            '</div>' +
          '</div>' +
          '<div class="aew-terminal-container">' +
            '<div class="aew-terminal-header">' +
              '<span>Terminal Console Output</span>' +
              '<button type="button" class="aew-btn-clear" id="aew-terminal-clear">Clear</button>' +
            '</div>' +
            '<pre class="aew-terminal-console" id="aew-terminal-console">Ready to deploy...</pre>' +
          '</div>';

        var cliContent = document.createElement('div');
        cliContent.id = 'aew-tab-cli-content';
        cliContent.className = 'aew-tab-content';
        cliContent.innerHTML = 
          '<div class="aew-cli-panel">' +
            '<div class="aew-cli-history-container">' +
              '<pre class="aew-cli-output" id="aew-cli-output">Ready to execute commands...</pre>' +
            '</div>' +
            '<div class="aew-cli-input-row">' +
              '<input type="text" id="aew-cli-input" placeholder="Type safe command (e.g. ls -la, grok status)...">' +
              '<button type="button" class="aew-btn aew-btn-primary" id="aew-btn-cli-run">Run</button>' +
            '</div>' +
          '</div>';

        chatPane.appendChild(tabsHeader);
        chatPane.appendChild(chatContent);
        chatPane.appendChild(deployContent);
        chatPane.appendChild(cliContent);

        $('aew-tab-chat').onclick = function() {
            $('aew-tab-chat').classList.add('active');
            $('aew-tab-deploy').classList.remove('active');
            $('aew-tab-cli').classList.remove('active');
            $('aew-tab-chat-content').classList.add('active-tab');
            $('aew-tab-deploy-content').classList.remove('active-tab');
            $('aew-tab-cli-content').classList.remove('active-tab');
        };

        $('aew-tab-deploy').onclick = function() {
            $('aew-tab-deploy').classList.add('active');
            $('aew-tab-chat').classList.remove('active');
            $('aew-tab-cli').classList.remove('active');
            $('aew-tab-deploy-content').classList.add('active-tab');
            $('aew-tab-chat-content').classList.remove('active-tab');
            $('aew-tab-cli-content').classList.remove('active-tab');
        };

        $('aew-tab-cli').onclick = function() {
            $('aew-tab-cli').classList.add('active');
            $('aew-tab-chat').classList.remove('active');
            $('aew-tab-deploy').classList.remove('active');
            $('aew-tab-cli-content').classList.add('active-tab');
            $('aew-tab-chat-content').classList.remove('active-tab');
            $('aew-tab-deploy-content').classList.remove('active-tab');
        };

        function runCliCommand() {
            var inputEl = $('aew-cli-input');
            var runBtn = $('aew-btn-cli-run');
            var outputEl = $('aew-cli-output');
            if (!inputEl || !runBtn || !outputEl) return;

            var cmd = (inputEl.value || '').trim();
            if (!cmd) return;

            inputEl.disabled = true;
            runBtn.disabled = true;

            outputEl.textContent += '\n$ ' + cmd + '\nExecuting...\n';
            outputEl.scrollTop = outputEl.scrollHeight;

            fetch('/ai/run_command', {
                method: 'POST',
                credentials: 'include',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: 'command=' + encodeURIComponent(cmd)
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.success) {
                    outputEl.textContent += data.output + '\n[Exit Code: ' + data.exit_code + ']\n';
                } else {
                    outputEl.textContent += 'Error: ' + (data.error || 'Unknown error') + '\n';
                }
                outputEl.scrollTop = outputEl.scrollHeight;
                inputEl.disabled = false;
                runBtn.disabled = false;
                inputEl.value = '';
                inputEl.focus();
            })
            .catch(function(e) {
                outputEl.textContent += 'Network Error: ' + e + '\n';
                outputEl.scrollTop = outputEl.scrollHeight;
                inputEl.disabled = false;
                runBtn.disabled = false;
                inputEl.focus();
            });
        }

        $('aew-btn-cli-run').onclick = runCliCommand;
        $('aew-cli-input').onkeydown = function(e) {
            if (e.key === 'Enter') {
                e.preventDefault();
                runCliCommand();
            }
        };

        $('aew-terminal-clear').onclick = function() {
            var consoleEl = $('aew-terminal-console');
            if (consoleEl) consoleEl.textContent = 'Ready to deploy...';
        };

        var deployPollingInterval = null;

        function pollDeployProgress() {
            fetch('/ai/deploy_progress', { credentials: 'include' })
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    var consoleEl = $('aew-terminal-console');
                    if (consoleEl && data.content) {
                        consoleEl.textContent = data.content;
                        consoleEl.scrollTop = consoleEl.scrollHeight;
                    }
                    if (data.done) {
                        if (deployPollingInterval) {
                            clearInterval(deployPollingInterval);
                            deployPollingInterval = null;
                        }
                        $('aew-btn-commit-deploy').disabled = false;
                        $('aew-btn-deploy-only').disabled = false;
                    }
                })
                .catch(function() {
                    if (deployPollingInterval) {
                        clearInterval(deployPollingInterval);
                        deployPollingInterval = null;
                    }
                    $('aew-btn-commit-deploy').disabled = false;
                    $('aew-btn-deploy-only').disabled = false;
                });
        }

        function runDeploy(withCommit) {
            var commitMsg = withCommit ? $('aew-deploy-commit-msg').value.trim() : '';
            if (withCommit && !commitMsg) {
                alert('Please enter a commit message for on-demand commit.');
                return;
            }

            var target = $('aew-deploy-target').value;
            var recreateVols = $('aew-deploy-vols').checked ? 1 : 0;
            var noRollback = $('aew-deploy-noroll').checked ? 1 : 0;

            $('aew-btn-commit-deploy').disabled = true;
            $('aew-btn-deploy-only').disabled = true;

            var consoleEl = $('aew-terminal-console');
            if (consoleEl) {
                consoleEl.textContent = 'Initializing connection to deployment backend...\n';
            }

            var body = 'target=' + encodeURIComponent(target) +
                       '&commit_msg=' + encodeURIComponent(commitMsg) +
                       '&recreate_volumes=' + recreateVols +
                       '&no_rollback=' + noRollback;

            fetch('/ai/deploy_docker', {
                method: 'POST',
                credentials: 'include',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: body
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.success) {
                    if (deployPollingInterval) clearInterval(deployPollingInterval);
                    deployPollingInterval = setInterval(pollDeployProgress, 1000);
                } else {
                    if (consoleEl) {
                        consoleEl.textContent += 'Error starting deployment: ' + (data.error || 'Unknown error') + '\n';
                    }
                    $('aew-btn-commit-deploy').disabled = false;
                    $('aew-btn-deploy-only').disabled = false;
                }
            })
            .catch(function(e) {
                if (consoleEl) {
                    consoleEl.textContent += 'Network error: ' + e + '\n';
                }
                $('aew-btn-commit-deploy').disabled = false;
                $('aew-btn-deploy-only').disabled = false;
            });
        }

        $('aew-btn-commit-deploy').onclick = function() {
            runDeploy(true);
        };

        $('aew-btn-deploy-only').onclick = function() {
            runDeploy(false);
        };
    }

    // ── Init ────────────────────────────────────────────────────────────────
    function init() {
        var tree = $('aew-tree');
        if (tree && !$('aew-tree-search')) {
            var searchWrap = document.createElement('div');
            searchWrap.style.padding = '0 0.3rem 0.3rem 0.3rem';
            searchWrap.innerHTML = '<input type="text" id="aew-tree-search" placeholder="Search files..." style="width:100%;box-sizing:border-box;font-size:0.72rem;padding:0.2rem;background:#1e1e1e;color:#ccc;border:1px solid #3c3c3c;border-radius:2px;margin-top:0.2rem;">';
            tree.parentNode.insertBefore(searchWrap, tree);
            $('aew-tree-search').addEventListener('input', function() {
                filterTree();
            });
        }
        refreshTree();
        loadProviders();

        var histSel = $('aew-chat-history-select');
        if (histSel) {
            histSel.onchange = function() {
                renderConversation();
            };
        }

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
        setupDeployTabs();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();