/**
 * Floating AI Code Editor — file tree (not Comserv /ai/chat by default).
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
        conversationTurns: [],
        conversationId: null,
        backend: 'grok_cli',
        treeExpanded: {},
        treeSeq: 0,
        fileIndex: [],
        fileIndexLoading: false,
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
        return fetch(url, opts).then(function(r) {
            if (!r.ok) {
                return r.text().then(function(body) {
                    var msg = 'HTTP ' + r.status;
                    try {
                        var parsed = JSON.parse(body);
                        if (parsed.error) msg += ': ' + parsed.error;
                    } catch (e) {
                        if (body && body.length < 200) msg += ': ' + body;
                    }
                    throw new Error(msg);
                });
            }
            return r.json();
        });
    }

    function escapeHtml(s) {
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    function loadPastConversations() {
        var selectEl = q('#aew-conversation-select') || document.getElementById('aew-conversation-select');
        if (!selectEl) return;
        fetch('/ai/get_conversation_list', { credentials: 'include' })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.success && data.conversations) {
                    selectEl.innerHTML = '<option value="">-- Load Past Chat (DB) --</option>';
                    data.conversations.forEach(function(conv) {
                        var opt = document.createElement('option');
                        opt.value = conv.id;
                        var label = conv.title || conv.preview || 'Untitled';
                        if (label.length > 40) {
                            label = label.substring(0, 40) + '...';
                        }
                        opt.textContent = label + ' (' + conv.message_count + ' msgs)';
                        selectEl.appendChild(opt);
                    });
                    if (state.conversationId) {
                        selectEl.value = state.conversationId;
                    }
                }
            })
            .catch(function(err) {
                console.error('Failed to load past conversations', err);
            });
    }

    function buildDom() {
        if (q('#aew-launcher-wrap')) return;

        var wrap = document.createElement('div');
        wrap.id = 'aew-launcher-wrap';
        wrap.innerHTML =
            '<button type="button" id="aew-launcher" title="AI Code Editor">💻 Code</button>';

        var panel = document.createElement('div');
        panel.id = 'aew-panel';
        panel.innerHTML =
            '<div id="aew-panel-header">' +
              '<span id="aew-drag-handle" title="Drag">⠿</span>' +
              '<span id="aew-panel-title">AI Code Editor</span>' +
              '<span id="aew-panel-sub">Local CLI · floating</span>' +
              '<select id="aew-backend" title="AI backend" style="font-size:0.72rem;margin-left:6px;">' +
                '<option value="grok_cli">AI Code Editor CLI (Cursor)</option>' +
                '<option value="comserv">Comserv AI (Ollama/Grok API)</option>' +
              '</select>' +
              '<select id="aew-branch" title="Git Branch" style="font-size:0.72rem;margin-left:6px;max-width:140px;">' +
                '<option value="">Loading branches...</option>' +
              '</select>' +
              '<select id="aew-model" title="Select AI Model" style="font-size:0.72rem;margin-left:6px;max-width:140px;background:#1e1e1e;color:#ccc;border:1px solid #3c3c3c;border-radius:2px;">' +
                '<option value="">Loading models...</option>' +
              '</select>' +
              '<button type="button" class="aew-btn" id="aew-popout" title="Open in separate window (move to another monitor)">⤢</button>' +
              '<button type="button" class="aew-btn" id="aew-dock-inline" title="Dock inline on this page">⊞</button>' +
              '<button type="button" class="aew-btn" id="aew-close">✕</button>' +
            '</div>' +
            '<div id="aew-panel-body" class="aew-panel-body">' +
              '<aside class="aew-files">' +
                '<div style="padding:0.3rem;display:flex;gap:0.25rem;align-items:center;">' +
                  '<button type="button" class="aew-btn" id="aew-refresh-tree" title="Refresh tree and load index">↻</button>' +
                  '<button type="button" class="aew-btn" id="aew-new-file-btn" title="Create a new file" style="font-weight:bold;">+</button>' +
                  '<button type="button" class="aew-btn" id="aew-delete-file-btn" title="Delete current file" style="font-weight:bold;">–</button>' +
                  '<button type="button" class="aew-btn" id="aew-rebuild-index-btn" title="Rebuild whole file index" style="font-size:0.7rem;padding:0.2rem 0.4rem;">Rebuild</button>' +
                  '<button type="button" class="aew-btn aew-btn-primary" id="aew-save-btn">Save</button>' +
                  '<button type="button" class="aew-btn" id="aew-revert-btn" title="Emergency Revert to Main branch (Discards all unsaved and uncommitted changes via Git/SSH)" style="background:#cc3333;color:#fff;font-size:0.7rem;padding:0.2rem 0.4rem;border:1px solid #990000;border-radius:2px;cursor:pointer;">Revert to Main</button>' +
                '</div>' +
                '<div style="padding:0 0.3rem 0.3rem 0.3rem;">' +
                  '<input type="text" id="aew-tree-search" placeholder="Search files..." style="width:100%;box-sizing:border-box;font-size:0.72rem;padding:0.2rem;background:#1e1e1e;color:#ccc;border:1px solid #3c3c3c;border-radius:2px;margin-top:0.2rem;">' +
                '</div>' +
                '<div class="aew-tree" id="aew-tree"></div>' +
              '</aside>' +
              '<section class="aew-editor-pane">' +
                '<div style="padding:0.25rem 0.4rem;font-size:0.72rem;color:#9cdcfe;" id="aew-editor-path">—</div>' +
                '<textarea class="aew-editor" id="aew-editor" spellcheck="false"></textarea>' +
              '</section>' +
              '<aside class="aew-chat-pane" id="aew-aside-pane">' +
                '<div class="aew-tabs-header">' +
                  '<button type="button" class="aew-tab-btn active" id="aew-tab-chat">💬 Chat</button>' +
                  '<button type="button" class="aew-tab-btn" id="aew-tab-deploy">🚀 Deploy</button>' +
                  '<button type="button" class="aew-tab-btn" id="aew-tab-cli">💻 CLI</button>' +
                '</div>' +
                '<div id="aew-tab-chat-content" class="aew-tab-content active-tab">' +
                  '<div class="aew-chat-history-bar" style="display:flex; gap:4px; padding:2px; background:#222; border-bottom:1px solid #3c3c3c;">' +
                    '<select id="aew-conversation-select" style="flex:1.2; font-size:0.7rem; padding:1px; background:#1e1e1e; color:#ccc; border:1px solid #444; border-radius:2px; min-width:0;">' +
                      '<option value="">-- Load Past Chat (DB) --</option>' +
                    '</select>' +
                    '<select id="aew-chat-history-select" style="flex:1; font-size:0.7rem; padding:1px; background:#1e1e1e; color:#ccc; border:1px solid #444; border-radius:2px; min-width:0;">' +
                      '<option value="">-- Active Chat (Show All) --</option>' +
                    '</select>' +
                  '</div>' +
                  '<div class="aew-messages" id="aew-messages"></div>' +
                  '<div class="aew-input-row">' +
                    '<textarea id="aew-chat-input" rows="2" placeholder="Ask AI Code Editor…"></textarea>' +
                    '<button type="button" class="aew-btn aew-btn-primary" id="aew-send-btn">Send</button>' +
                  '</div>' +
                  '<div class="aew-status" id="aew-status"></div>' +
                '</div>' +
                '<div id="aew-tab-deploy-content" class="aew-tab-content">' +
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
                  '</div>' +
                '</div>' +
                '<div id="aew-tab-cli-content" class="aew-tab-content">' +
                  '<div class="aew-cli-panel">' +
                    '<div class="aew-cli-history-container">' +
                      '<pre class="aew-cli-output" id="aew-cli-output">Ready to execute commands...</pre>' +
                    '</div>' +
                    '<div class="aew-cli-input-row">' +
                      '<input type="text" id="aew-cli-input" placeholder="Type safe command (e.g. ls -la, grok status)...">' +
                      '<button type="button" class="aew-btn aew-btn-primary" id="aew-btn-cli-run">Run</button>' +
                    '</div>' +
                  '</div>' +
                '</div>' +
              '</aside>' +
            '</div>' +
            '<div id="aew-resize-handle" title="Resize"></div>';

        document.body.appendChild(wrap);
        document.body.appendChild(panel);

        var deployPollingInterval = null;

        function pollDeployProgress() {
            fetch('/ai/deploy_progress', { credentials: 'include' })
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    var consoleEl = q('#aew-terminal-console');
                    if (consoleEl && data.content) {
                        consoleEl.textContent = data.content;
                        consoleEl.scrollTop = consoleEl.scrollHeight;
                    }
                    if (data.done) {
                        if (deployPollingInterval) {
                            clearInterval(deployPollingInterval);
                            deployPollingInterval = null;
                        }
                        q('#aew-btn-commit-deploy').disabled = false;
                        q('#aew-btn-deploy-only').disabled = false;
                    }
                })
                .catch(function() {
                    if (deployPollingInterval) {
                        clearInterval(deployPollingInterval);
                        deployPollingInterval = null;
                    }
                    q('#aew-btn-commit-deploy').disabled = false;
                    q('#aew-btn-deploy-only').disabled = false;
                });
        }

        function runDeploy(withCommit) {
            var commitMsg = withCommit ? q('#aew-deploy-commit-msg').value.trim() : '';
            if (withCommit && !commitMsg) {
                alert('Please enter a commit message for on-demand commit.');
                return;
            }

            var target = q('#aew-deploy-target').value;
            var recreateVols = q('#aew-deploy-vols').checked ? 1 : 0;
            var noRollback = q('#aew-deploy-noroll').checked ? 1 : 0;

            q('#aew-btn-commit-deploy').disabled = true;
            q('#aew-btn-deploy-only').disabled = true;

            var consoleEl = q('#aew-terminal-console');
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
                    q('#aew-btn-commit-deploy').disabled = false;
                    q('#aew-btn-deploy-only').disabled = false;
                }
            })
            .catch(function(e) {
                if (consoleEl) {
                    consoleEl.textContent += 'Network error: ' + e + '\n';
                }
                q('#aew-btn-commit-deploy').disabled = false;
                q('#aew-btn-deploy-only').disabled = false;
            });
        }

        q('#aew-tab-chat').onclick = function() {
            q('#aew-tab-chat').classList.add('active');
            q('#aew-tab-deploy').classList.remove('active');
            q('#aew-tab-cli').classList.remove('active');
            q('#aew-tab-chat-content').classList.add('active-tab');
            q('#aew-tab-deploy-content').classList.remove('active-tab');
            q('#aew-tab-cli-content').classList.remove('active-tab');
        };

        q('#aew-tab-deploy').onclick = function() {
            q('#aew-tab-deploy').classList.add('active');
            q('#aew-tab-chat').classList.remove('active');
            q('#aew-tab-cli').classList.remove('active');
            q('#aew-tab-deploy-content').classList.add('active-tab');
            q('#aew-tab-chat-content').classList.remove('active-tab');
            q('#aew-tab-cli-content').classList.remove('active-tab');
        };

        q('#aew-tab-cli').onclick = function() {
            q('#aew-tab-cli').classList.add('active');
            q('#aew-tab-chat').classList.remove('active');
            q('#aew-tab-deploy').classList.remove('active');
            q('#aew-tab-cli-content').classList.add('active-tab');
            q('#aew-tab-chat-content').classList.remove('active-tab');
            q('#aew-tab-deploy-content').classList.remove('active-tab');
        };

        function runCliCommand() {
            var inputEl = q('#aew-cli-input');
            var runBtn = q('#aew-btn-cli-run');
            var outputEl = q('#aew-cli-output');
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

        q('#aew-btn-cli-run').onclick = runCliCommand;
        q('#aew-cli-input').onkeydown = function(e) {
            if (e.key === 'Enter') {
                e.preventDefault();
                runCliCommand();
            }
        };

        q('#aew-terminal-clear').onclick = function() {
            var consoleEl = q('#aew-terminal-console');
            if (consoleEl) consoleEl.textContent = 'Ready to deploy...';
        };

        q('#aew-btn-commit-deploy').onclick = function() {
            runDeploy(true);
        };

        q('#aew-btn-deploy-only').onclick = function() {
            runDeploy(false);
        };

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

        var newFileBtn = q('#aew-new-file-btn');
        if (newFileBtn) {
            newFileBtn.onclick = function() {
                var path = prompt("Enter new file path relative to project root (e.g. lib/Comserv/Controller/MyTest.pm):");
                if (!path) return;
                path = path.trim();
                if (!path) return;
                setStatus("Creating " + path + "...");
                fetch("/ai/create_file", {
                    method: 'POST',
                    credentials: 'include',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: 'path=' + encodeURIComponent(path)
                })
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    if (data.success) {
                        setStatus("Created file: " + path, "ok");
                        loadFileIndex().then(function() {
                            refreshTree();
                            loadFile(path);
                        });
                    } else {
                        setStatus("Create failed: " + (data.error || "unknown"), "err");
                    }
                })
                .catch(function(err) {
                    setStatus("Create error: " + err, "err");
                });
            };
        }

        var deleteFileBtn = q('#aew-delete-file-btn');
        if (deleteFileBtn) {
            deleteFileBtn.onclick = function() {
                if (!state.currentPath) {
                    alert("Please open a file first to delete it.");
                    return;
                }
                if (!confirm("Are you sure you want to permanently delete " + state.currentPath + "?")) {
                    return;
                }
                var path = state.currentPath;
                setStatus("Deleting " + path + "...");
                fetch("/ai/delete_file", {
                    method: 'POST',
                    credentials: 'include',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: 'path=' + encodeURIComponent(path)
                })
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    if (data.success) {
                        setStatus("Deleted file: " + path, "ok");
                        state.currentPath = '';
                        state.currentContent = '';
                        state.dirty = false;
                        q('#aew-editor').value = '';
                        q('#aew-editor-path').textContent = '—';
                        loadFileIndex().then(function() {
                            refreshTree();
                        });
                    } else {
                        setStatus("Delete failed: " + (data.error || "unknown"), "err");
                    }
                })
                .catch(function(err) {
                    setStatus("Delete error: " + err, "err");
                });
            };
        }

        var rebuildIndexBtn = q('#aew-rebuild-index-btn');
        if (rebuildIndexBtn) {
            rebuildIndexBtn.onclick = function() {
                setStatus("Rebuilding file index...");
                fetchJson("/ai/rebuild_file_index")
                    .then(function(data) {
                        if (data.success) {
                            state.fileIndex = data.files || [];
                            setStatus("Rebuilt file index with " + state.fileIndex.length + " files", "ok");
                            refreshTree();
                        } else {
                            setStatus("Rebuild failed: " + (data.error || "unknown"), "err");
                        }
                    })
                    .catch(function(err) {
                        setStatus("Rebuild error: " + err, "err");
                    });
            };
        }

        var revertBtn = q('#aew-revert-btn');
        if (revertBtn) {
            revertBtn.onclick = function() {
                if (!confirm("⚠️ WARNING: This will discard all unsaved/uncommitted changes and revert /home/shanta/PycharmProjects/comserv2 to the 'main' branch. Continue?")) {
                    return;
                }
                setStatus("Reverting codebase to main...", "info");
                fetch("/ai/revert_to_main", { method: 'POST', credentials: 'include' })
                    .then(function(r) { return r.json(); })
                    .then(function(data) {
                        if (data.success) {
                            setStatus("Successfully reverted to main!", "ok");
                            alert(data.message + "\n\nGit Output:\n" + data.output);
                            loadBranches();
                            if (window.AEW && AEW.refreshTree) {
                                AEW.refreshTree();
                            }
                        } else {
                            setStatus("Revert failed: " + data.error, "err");
                            alert("Revert failed: " + data.error);
                        }
                    })
                    .catch(function(err) {
                        setStatus("Revert network error: " + err, "err");
                        alert("Revert network error: " + err);
                    });
            };
        }

        var searchInput = q('#aew-tree-search');
        if (searchInput) {
            searchInput.addEventListener('input', function() {
                filterTree();
            });
        }
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

        function loadBranches() {
            var selectEl = q('#aew-branch');
            if (!selectEl) return;
            fetch('/ai/list_branches', { credentials: 'include' })
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    if (data.success && data.branches) {
                        selectEl.innerHTML = '';
                        data.branches.forEach(function(b) {
                            var opt = document.createElement('option');
                            opt.value = b.name;
                            opt.textContent = b.name;
                            if (b.current) {
                                opt.selected = true;
                            }
                            selectEl.appendChild(opt);
                        });
                    }
                })
                .catch(function(err) {
                    console.error('Failed to load branches', err);
                });
        }

        q('#aew-branch').onchange = function() {
            var branch = this.value;
            if (!branch) return;
            if (!confirm('Are you sure you want to switch to branch "' + branch + '"? Unsaved changes may be lost.')) {
                loadBranches();
                return;
            }
            setStatus('Switching branch...', 'info');
            fetch('/ai/switch_branch', {
                method: 'POST',
                credentials: 'include',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: 'branch=' + encodeURIComponent(branch)
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.success) {
                    setStatus('Switched branch successfully', 'ok');
                    loadBranches();
                    if (window.AEW && AEW.refreshTree) {
                        AEW.refreshTree();
                    }
                } else {
                    setStatus('Error: ' + data.error, 'err');
                    loadBranches();
                }
            })
            .catch(function(e) {
                setStatus('Network error: ' + e, 'err');
                loadBranches();
            });
        };

        loadBranches();
        q('#aew-chat-history-select').onchange = function() {
            renderConversation();
        };

        var convSel = q('#aew-conversation-select');
        if (convSel) {
            convSel.onchange = function() {
                var convId = this.value;
                if (!convId) {
                    state.conversationId = null;
                    state.chatHistory = [];
                    state.conversationTurns = [];
                    updateHistoryDropdown();
                    renderConversation();
                    return;
                }
                setStatus('Loading past chat ' + convId + '...', 'info');
                fetch('/ai/get_conversation_messages/' + convId, { credentials: 'include' })
                    .then(function(r) { return r.json(); })
                    .then(function(data) {
                        if (data.success && data.messages) {
                            state.conversationId = convId;
                            state.chatHistory = [];
                            state.conversationTurns = [];
                            
                            var lastUser = null;
                            data.messages.forEach(function(msg) {
                                state.chatHistory.push({
                                    role: msg.role,
                                    content: msg.content
                                });
                                
                                if (msg.role === 'user') {
                                    lastUser = msg.content;
                                } else if (msg.role === 'assistant' && lastUser !== null) {
                                    var turnIndex = state.conversationTurns.length + 1;
                                    state.conversationTurns.push({
                                        id: turnIndex,
                                        user: lastUser,
                                        ai: msg.content
                                    });
                                    lastUser = null;
                                }
                            });
                            
                            setStatus('Loaded past chat successfully', 'ok');
                            updateHistoryDropdown();
                            renderConversation();
                        } else {
                            setStatus('Failed to load past chat: ' + (data.error || 'unknown'), 'err');
                        }
                    })
                    .catch(function(err) {
                        setStatus('Network error loading chat: ' + err, 'err');
                    });
            };
        }

        q('#aew-editor').addEventListener('input', function() {
            state.dirty = q('#aew-editor').value !== state.currentContent;
        });

        initDrag(panel);
        initResize(panel);
    }

    function populateModels(cfg) {
        var selectEl = q('#aew-model');
        if (!selectEl) return;
        selectEl.innerHTML = '';

        if (cfg.installed_models && cfg.installed_models.length > 0) {
            var localGrp = document.createElement('optgroup');
            localGrp.label = 'Ollama (Local)';
            cfg.installed_models.forEach(function(m) {
                var opt = document.createElement('option');
                opt.value = m.name;
                var label = m.name;
                if (m.details && m.details.parameter_size) {
                    label += ' (' + m.details.parameter_size + ')';
                }
                opt.textContent = label;
                if (m.name === cfg.current_model) {
                    opt.selected = true;
                }
                localGrp.appendChild(opt);
            });
            selectEl.appendChild(localGrp);
        }

        if (cfg.external_models && cfg.external_models.length > 0) {
            var extGrp = document.createElement('optgroup');
            extGrp.label = 'External AI';
            cfg.external_models.forEach(function(m) {
                var opt = document.createElement('option');
                opt.value = m.name;
                opt.textContent = m.label;
                if (m.name === cfg.current_model) {
                    opt.selected = true;
                }
                extGrp.appendChild(opt);
            });
            selectEl.appendChild(extGrp);
        }

        if (!selectEl.childElementCount) {
            selectEl.innerHTML = '<option value="">No models available</option>';
        }
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

    function formatMessageHtml(text) {
        if (!text) return '';
        var escaped = text
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;');

        var codeBlocks = [];
        escaped = escaped.replace(/```([a-zA-Z0-9_\-#\+]*)\n([\s\S]*?)```/g, function(match, lang, code) {
            var placeholder = '___CODEBLOCK_' + codeBlocks.length + '___';
            codeBlocks.push('<pre class="aew-pre-code"><code class="language-' + escapeHtml(lang) + '">' + code + '</code></pre>');
            return placeholder;
        });

        escaped = escaped.replace(/\[READ_FILE:\s*([^\]]+)\]/gi, function(match, path) {
            var cleanPath = path.trim();
            return '<button type="button" class="aew-btn-inline-tool" onclick="window.AEW.loadFile(\'' + cleanPath.replace(/'/g, "\\'") + '\')">📄 Load: ' + escapeHtml(cleanPath) + '</button>';
        });

        escaped = escaped.replace(/\[RUN_COMMAND:\s*([^\]]+)\]/gi, function(match, cmd) {
            var cleanCmd = cmd.trim();
            return '<button type="button" class="aew-btn-inline-tool run-cmd-btn" onclick="window.AEW.runApprovedCommand(\'' + cleanCmd.replace(/'/g, "\\'") + '\')">💻 Run: <code>' + escapeHtml(cleanCmd) + '</code></button>';
        });

        escaped = escaped.replace(/\[SEARCH_GREP:\s*([^\]]+)\]/gi, function(match, pattern) {
            var cleanPattern = pattern.trim();
            return '<button type="button" class="aew-btn-inline-tool search-grep-btn" onclick="window.AEW.runApprovedGrep(\'' + cleanPattern.replace(/'/g, "\\'") + '\')">🔍 Search: ' + escapeHtml(cleanPattern) + '</button>';
        });

        escaped = escaped.replace(/`([^`]+)`/g, '<code>$1</code>');
        escaped = escaped.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
        escaped = escaped.replace(/\n/g, '<br>');

        codeBlocks.forEach(function(block, idx) {
            escaped = escaped.replace('___CODEBLOCK_' + idx + '___', block);
        });

        return escaped;
    }

    function runApprovedCommand(cmd) {
        if (!confirm('Execute command on server?\n\n' + cmd)) return;
        setStatus('Running command…');
        addMsg('Running: ' + cmd, 'system');
        fetch('/ai/run_command', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: 'command=' + encodeURIComponent(cmd),
        })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            if (data.success) {
                var outText = 'Command output (exit code: ' + data.exit_code + '):\n' + (data.output || '(no output)');
                addMsg(outText, 'system');
                setStatus('Command complete', 'ok');
            } else {
                addMsg('Error: ' + data.error, 'system');
                setStatus('Command failed', 'err');
            }
        })
        .catch(function(e) {
            addMsg('Command request failed: ' + e, 'system');
            setStatus('Command error', 'err');
        });
    }

    function runApprovedGrep(pattern) {
        var cmd = 'grep -rn -I --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=logs ' + shellEscape(pattern) + ' .';
        runApprovedCommand(cmd);
    }

    function shellEscape(s) {
        return '"' + s.replace(/(["\\])/g, '\\$1') + '"';
    }

    function parseFixBlock(raw) {
        var re = /##\s*FIX:\s*([^\n\r]+)[\r\n]+```[^\n\r]*\n([\s\S]*?)```/i;
        var m = raw.match(re);
        if (!m) return null;
        return { path: m[1].trim(), content: m[2] };
    }

    function showFixPanel(fix) {
        var box = q('#aew-messages');
        if (!box) return;
        var panel = document.createElement('div');
        panel.className = 'aew-fix-panel';
        panel.innerHTML = '<strong>Proposed fix:</strong> ' + escapeHtml(fix.path)
            + '<pre class="aew-pre-code">' + escapeHtml(fix.content.slice(0, 2000)) + (fix.content.length > 2000 ? '\n…' : '') + '</pre>';
        var applyBtn = document.createElement('button');
        applyBtn.className = 'aew-btn aew-btn-success';
        applyBtn.textContent = 'Apply Fix';
        applyBtn.style.marginTop = '4px';
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
                    addMsg('Applied fix to ' + fix.path, 'system');
                    if (fix.path === state.currentPath) {
                        state.currentContent = fix.content;
                        state.dirty = false;
                        var ed = q('#aew-editor');
                        if (ed) ed.value = fix.content;
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

    function addMsg(text, role, isHtml) {
        var box = q('#aew-messages');
        if (!box) return;
        var d = document.createElement('div');
        d.className = 'aew-msg aew-msg-' + role;
        d.innerHTML = isHtml ? text : formatMessageHtml(text);
        box.appendChild(d);
        box.scrollTop = box.scrollHeight;
    }

    function renderConversation() {
        var box = q('#aew-messages');
        if (!box) return;
        box.innerHTML = '';
        var selectEl = q('#aew-chat-history-select');
        var selectedVal = selectEl ? selectEl.value : '';
        if (selectedVal) {
            var turnId = parseInt(selectedVal, 10);
            var turn = state.conversationTurns.find(function(t) { return t.id === turnId; });
            if (turn) {
                var dUser = document.createElement('div');
                dUser.className = 'aew-msg aew-msg-user';
                dUser.innerHTML = formatMessageHtml(turn.user);
                box.appendChild(dUser);
                var dAi = document.createElement('div');
                dAi.className = 'aew-msg aew-msg-ai';
                dAi.innerHTML = formatMessageHtml(turn.ai);
                box.appendChild(dAi);
            }
        } else {
            if (!window.AEW_POPUP_MODE) {
                var dSys = document.createElement('div');
                dSys.className = 'aew-msg aew-msg-system';
                dSys.innerHTML = formatMessageHtml('Inline dock — use ⤢ for a separate window (recommended).');
                box.appendChild(dSys);
            }
            state.chatHistory.forEach(function(m) {
                var d = document.createElement('div');
                d.className = 'aew-msg aew-msg-' + m.role;
                d.innerHTML = formatMessageHtml(m.content);
                box.appendChild(d);
            });
        }
        box.scrollTop = box.scrollHeight;
    }

    function updateHistoryDropdown() {
        var selectEl = q('#aew-chat-history-select');
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

    function applySearchIfActive() {
        var searchInput = q('#aew-tree-search');
        if (searchInput && searchInput.value.trim()) {
            filterTree();
        }
    }

    function searchFilesRemote(query, limit) {
        var url = '/ai/search_files?q=' + encodeURIComponent(query);
        if (limit) url += '&limit=' + encodeURIComponent(limit);
        return fetchJson(url);
    }

    function loadFileIndex() {
        if (state.fileIndexLoading) {
            return Promise.resolve({ success: true, files: state.fileIndex });
        }
        state.fileIndexLoading = true;
        return fetchJson('/ai/get_file_index')
            .then(function(data) {
                if (data.success) {
                    state.fileIndex = data.files || [];
                    if (state.fileIndex.length) {
                        setStatus('File index: ' + state.fileIndex.length + ' files', 'ok');
                    }
                } else if (data.error) {
                    setStatus('File index: ' + data.error, 'err');
                }
                return data;
            })
            .catch(function(err) {
                console.error("Failed to load file index:", err);
                setStatus('File index load failed — use search box or chat "find filename"', 'err');
                return { success: false, error: String(err) };
            })
            .finally(function() {
                state.fileIndexLoading = false;
                applySearchIfActive();
            });
    }

    function extractFileFindQuery(text) {
        var m = String(text || '').match(/^(?:find|locate|search(?:\s+for)?|where\s+is|open|show)\s+(.+)$/i);
        return m ? m[1].trim() : '';
    }

    function levenshtein(a, b) {
        a = a || '';
        b = b || '';
        if (!a.length) return b.length;
        if (!b.length) return a.length;
        var row = [];
        for (var j = 0; j <= b.length; j++) row[j] = j;
        for (var i = 1; i <= a.length; i++) {
            var prev = i;
            for (var j = 1; j <= b.length; j++) {
                var cur = row[j];
                var cost = a.charAt(i - 1) === b.charAt(j - 1) ? 0 : 1;
                row[j] = Math.min(prev + 1, row[j - 1] + 1, row[j] + cost);
                prev = cur;
            }
        }
        return row[b.length];
    }

    function formatFileFindReply(query, files, fuzzy) {
        if (!files || !files.length) {
            return 'No files matching "' + query + '" in the project index.\n'
                + 'Try the **Search files** box above the tree.\n'
                + 'Common typo: DailyPlan.tt (not DailPlan.tt)';
        }
        var lines = [];
        if (fuzzy) {
            lines.push('No exact match for "' + query + '" — showing close matches:', '');
        } else {
            lines.push('Found ' + files.length + ' match(es) for "' + query + '":', '');
        }
        files.forEach(function(path, i) {
            lines.push((i + 1) + '. ' + path);
        });
        lines.push('', 'Say: open ' + files[0].split('/').pop() + ' — or use the Search files box.');
        return lines.join('\n');
    }

    function extractRouteFromQuestion(text) {
        var t = String(text || '');
        if (/\/plan[n]?ing\/daily\b/i.test(t) || /\bplan[n]?ing\/daily\b/i.test(t)) {
            return '/planning/daily';
        }
        var m = t.match(/(\/[a-z][a-z0-9_\/-]{2,})/i);
        if (m && /(?:\.tt|template|route|return|what|which|file|url|path)/i.test(t)) {
            return m[1].replace(/\/+$/, '');
        }
        return '';
    }

    function formatRouteReply(data) {
        if (!data.success) {
            if (data.guessed_templates && data.guessed_templates.length) {
                return 'Route ' + data.route + ' — no exact mapping. Guessed templates:\n'
                    + data.guessed_templates.map(function(p, i) { return (i + 1) + '. ' + p; }).join('\n');
            }
            return 'Could not map route ' + (data.route || '') + ' to a template.';
        }
        var lines = [
            'Route: ' + data.route,
            'Template: ' + data.template,
            'Controller: ' + (data.controller || '—'),
        ];
        if (data.note) lines.push('Note: ' + data.note);
        if (data.related && data.related.length) {
            lines.push('', 'Related copies:');
            data.related.forEach(function(p, i) { lines.push('  ' + (i + 1) + '. ' + p); });
        }
        lines.push('', 'Say: open ' + data.template.split('/').pop());
        return lines.join('\n');
    }

    function tryLocalRouteLookup(userText) {
        var route = extractRouteFromQuestion(userText);
        if (!route) return null;
        setStatus('Resolving route ' + route + '…');
        return fetchJson('/ai/resolve_route?path=' + encodeURIComponent(route))
            .then(function(data) {
                var reply = formatRouteReply(data);
                addMsg(reply, 'ai');
                state.chatHistory.push({ role: 'assistant', content: reply });
                updateHistoryDropdown();
                setStatus('Route resolved locally', 'ok');
                if (data.template) {
                    var searchInput = q('#aew-tree-search');
                    if (searchInput) {
                        searchInput.value = data.template.split('/').pop();
                        filterTree();
                    }
                }
                return true;
            })
            .catch(function(err) {
                addMsg('Route lookup error: ' + err, 'system');
                setStatus(String(err), 'err');
                return true;
            });
    }

    function tryLocalFileFind(userText) {
        var query = extractFileFindQuery(userText);
        if (!query) return null;

        function renderResults(files, fuzzy) {
            var reply = formatFileFindReply(query, files, fuzzy);
            addMsg(reply, 'ai');
            state.chatHistory.push({ role: 'assistant', content: reply });
            updateHistoryDropdown();
            setStatus('Found ' + files.length + ' file(s) locally (no AI call)', 'ok');
            if (files.length >= 1) {
                var searchInput = q('#aew-tree-search');
                if (searchInput) {
                    searchInput.value = files[0].split('/').pop();
                    filterTree();
                }
            }
        }

        setStatus('Searching files for "' + query + '"…');
        return searchFilesRemote(query, 50).then(function(data) {
            if (!data.success) {
                addMsg('File search failed: ' + (data.error || 'unknown'), 'system');
                setStatus(data.error || 'search failed', 'err');
                return true;
            }
            renderResults(data.files || [], data.fuzzy);
            return true;
        }).catch(function(err) {
            addMsg('File search error: ' + err + '\nUse the Search files box above the tree.', 'system');
            setStatus(String(err), 'err');
            return true;
        });
    }

    function scoreFileMatch(path, query) {
        var lower = path.toLowerCase();
        var name = lower.split('/').pop();
        if (name === query) return 100;
        if (name.indexOf(query) === 0) return 80;
        if (name.indexOf(query) !== -1) return 60;
        if (lower.indexOf(query) !== -1) return 40;
        if (query.length >= 4 && name) {
            var dist = levenshtein(name, query);
            var maxLen = Math.max(name.length, query.length);
            var sim = 1 - (dist / maxLen);
            if (sim >= 0.72) return Math.floor(30 + 20 * sim);
        }
        return 0;
    }

    function filterTree() {
        var searchInput = q('#aew-tree-search');
        var query = ((searchInput || {}).value || '').toLowerCase().trim();
        var root = q('#aew-tree');
        if (!root) return;

        // If no query, restore standard tree directory structure
        if (!query) {
            root.innerHTML = '';
            appendTreeEntries(root, '', 0, state.treeSeq);
            return;
        }

        if (!state.fileIndex || state.fileIndex.length === 0) {
            root.innerHTML = '';
            var loading = document.createElement('div');
            loading.className = 'aew-tree-hint';
            loading.style.padding = '0.5rem';
            loading.style.color = '#888';
            loading.style.fontSize = '0.72rem';
            loading.textContent = 'Searching...';
            root.appendChild(loading);
            searchFilesRemote(query, 80).then(function(data) {
                if (data.success && data.files && data.files.length) {
                    state.fileIndex = data.files;
                    filterTree();
                    return;
                }
                return loadFileIndex().then(function() {
                    if (searchInput && searchInput.value.trim()) {
                        filterTree();
                    }
                });
            }).catch(function() {
                return loadFileIndex().then(function() {
                    if (searchInput && searchInput.value.trim()) {
                        filterTree();
                    }
                });
            });
            return;
        }

        // Whole-project matched file search in state.fileIndex
        var matched = state.fileIndex
            .map(function(path) {
                return { path: path, score: scoreFileMatch(path, query) };
            })
            .filter(function(item) { return item.score > 0; })
            .sort(function(a, b) {
                return b.score - a.score || a.path.localeCompare(b.path);
            })
            .map(function(item) { return item.path; });

        // Render matched files as a flat list
        root.innerHTML = '';
        if (matched.length === 0) {
            var empty = document.createElement('div');
            empty.className = 'aew-tree-hint';
            empty.style.padding = '0.5rem';
            empty.style.color = '#888';
            empty.style.fontSize = '0.72rem';
            empty.textContent = 'No files found matching "' + query + '"';
            root.appendChild(empty);
            return;
        }

        matched.forEach(function(path) {
            var row = document.createElement('div');
            row.className = 'aew-tree-item';
            row.dataset.rel = path;
            // Get the filename only for display name
            var name = path.split('/').pop();
            row.dataset.name = name;
            if (path === state.currentPath) row.classList.add('active');
            
            // Show file icon and name, with path in small font or parentheses
            row.innerHTML = '📄 ' + escapeHtml(name) + ' <span style="font-size:0.65rem;color:#777;margin-left:4px;">(' + escapeHtml(path) + ')</span>';
            row.title = path;

            row.onclick = function(ev) {
                ev.stopPropagation();
                loadFile(path);
            };

            root.appendChild(row);
        });
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
                    row.dataset.name = ent.name;
                    if (ent.path === state.currentPath) row.classList.add('active');
                    var open = ent.type === 'dir' && state.treeExpanded[ent.path];
                    row.innerHTML = (ent.type === 'dir' ? (open ? '📂 ' : '📁 ') : '📄 ') + escapeHtml(ent.name);

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
                            var openNow = state.treeExpanded[ent.path];
                            row.innerHTML = (openNow ? '📂 ' : '📁 ') + escapeHtml(row.dataset.name);
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
        if (!state.treeExpanded || Object.keys(state.treeExpanded).length === 0) {
            state.treeExpanded = { lib: true };
        }
        var searchInput = q('#aew-tree-search');
        var hasSearch = searchInput && searchInput.value.trim();
        if (!hasSearch) {
            root.innerHTML = '';
            appendTreeEntries(root, '', 0, seq);
        }
        loadFileIndex();
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
        var input = q('#aew-chat-input') || document.getElementById('aew-chat-input');
        if (input) {
            input.value = promptText;
            input.focus();
        }
        addMsg("Detected error source on parent page. Loaded file: " + errInfo.path + (errInfo.lineNum ? " (line " + errInfo.lineNum + ")" : ""), "system");
    }

    function checkForErrorSourceAndLoad() {
        var errInfo = null;
        try {
            errInfo = detectPageErrorSource();
        } catch (e) {}

        if (errInfo && errInfo.path) {
            applyErrorSource(errInfo);
        } else if (window.AEW_POPUP_MODE) {
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
        setStatus('AI Code Editor running…');
        q('#aew-send-btn').disabled = true;
        var ctx = openerContext();
        var modelEl = q('#aew-model');
        var selectedModel = modelEl ? modelEl.value : '';
        var body = 'prompt=' + encodeURIComponent(prompt)
            + '&page_path=' + encodeURIComponent(ctx.page_path)
            + '&page_title=' + encodeURIComponent(ctx.page_title)
            + '&model=' + encodeURIComponent(selectedModel);
        if (state.conversationId) {
            body += '&conversation_id=' + encodeURIComponent(state.conversationId);
        }
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
        var modelEl = q('#aew-model');
        var selectedModel = modelEl ? modelEl.value : '';
        return fetch('/ai/chat', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                prompt: prompt,
                agent_id: 'coding',
                model: selectedModel,
                history: state.chatHistory.slice(-20),
                page_path: window.location.pathname,
                conversation_id: state.conversationId || undefined,
            }),
        })
        .then(function(r) { return r.json(); })
        .finally(function() { q('#aew-send-btn').disabled = false; });
    }

    function sendChat(userText) {
        var selectEl = q('#aew-chat-history-select');
        if (selectEl && selectEl.value !== '') {
            selectEl.value = '';
            renderConversation();
        }
        addMsg(userText, 'user');
        state.chatHistory.push({ role: 'user', content: userText });

        var routeLookup = tryLocalRouteLookup(userText);
        if (routeLookup) {
            routeLookup.then(function(handled) {
                if (handled) return;
                var fileFind = tryLocalFileFind(userText);
                if (fileFind) {
                    fileFind.then(function(h2) { if (!h2) sendChatToBackend(userText); });
                } else {
                    sendChatToBackend(userText);
                }
            });
            return;
        }
        var fileFind = tryLocalFileFind(userText);
        if (fileFind) {
            fileFind.then(function(handled) {
                if (!handled) sendChatToBackend(userText);
            });
            return;
        }
        sendChatToBackend(userText);
    }

    function sendChatToBackend(userText) {
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

            if (data.conversation_id) {
                state.conversationId = data.conversation_id;
                loadPastConversations();
            }

            var turnIndex = state.conversationTurns.length + 1;
            state.conversationTurns.push({
                id: turnIndex,
                user: userText,
                ai: reply
            });
            updateHistoryDropdown();

            var backendLabel = data.backend === 'grok_api' ? 'Grok xAI API' : (data.backend || state.backend);
            setStatus(backendLabel + ' done', 'ok');
            var rf = reply.match(/\[READ_FILE:\s*([^\]]+)\]/i);
            if (rf) loadFile(rf[1].trim());

            var fix = parseFixBlock(reply);
            if (fix) showFixPanel(fix);
        }).catch(function(e) {
            var errMsg = String(e);
            var hint = '';
            if (/NetworkError|Failed to fetch|fetch resource/i.test(errMsg)) {
                hint = '\n\nTip: For finding files, use the Search files box (above the tree) '
                    + 'or type "find DailyPlan.tt" — that uses local index, not Grok CLI.';
                if (state.backend === 'grok_cli') {
                    hint += '\nRemote? Switch backend to "Comserv AI" or ensure SSH tunnel stays open for long Grok CLI calls.';
                }
            }
            addMsg('Network error: ' + errMsg + hint, 'system');
            setStatus(errMsg, 'err');
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
        loadPastConversations();
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
        runApprovedCommand: runApprovedCommand,
        runApprovedGrep: runApprovedGrep,
    };

    fetchJson('/ai/editor_config').then(function(cfg) {
        if (!cfg.success || !cfg.enabled) return;
        state.enabled = true;
        buildDom();
        populateModels(cfg);
        loadPastConversations();
        var diagHtml = '<details style="font-size:0.75rem; color:#dcdcaa; cursor:pointer;">' +
            '<summary style="font-weight:bold; outline:none; color:#dcdcaa;">🔌 Remote Connection Info (Click to Expand)</summary>' +
            '<div style="margin-top:6px; padding:6px; background:#111; border:1px solid #444; border-radius:3px; color:#ccc; font-family:monospace; line-height:1.4;">';
        if (cfg.grok_cli) {
            var authNote = cfg.grok_auth ? (' auth=' + cfg.grok_auth) : '';
            var modeNote = cfg.grok_mode === 'xai_api'
                ? ' — uses xAI API (works from tablet/remote; no local CLI)'
                : ' — local CLI (workstation only)';
            diagHtml += '<strong>Grok:</strong> ' + escapeHtml(cfg.grok_cli) + escapeHtml(authNote) + escapeHtml(modeNote) + '<br>';
        }
        if (cfg.remote_ok) {
            if (cfg.zerotier_dns_note) {
                diagHtml += '<strong>ZeroTier DNS:</strong> ' + escapeHtml(cfg.zerotier_dns_note) + '<br>';
            }
            if (cfg.editor_url_workstation_zero) {
                diagHtml += '<strong>Dev (ZT hostname):</strong> ' + escapeHtml(cfg.editor_url_workstation_zero) + '<br>';
            }
            if (cfg.editor_url_zerotier) {
                diagHtml += '<strong>Dev (ZT IP):</strong> ' + escapeHtml(cfg.editor_url_zerotier) + '<br>';
            }
            diagHtml += '<strong>LAN hostname:</strong> ' + escapeHtml(cfg.editor_url_lan || 'http://workstation.local:3001/ai/editing_widget_popup') + '<br>';
            if (cfg.ssh_tunnel_cmd) {
                diagHtml += '<strong>SSH:</strong> <code>' + escapeHtml(cfg.ssh_tunnel_cmd) + '</code><br>';
                diagHtml += '<strong>Tunnel browser:</strong> ' + escapeHtml(cfg.editor_url_tunnel || 'http://workstation.local:3001/ai/editing_widget_popup') + '<br>';
                diagHtml += '<strong>Hosts Hint:</strong> ' + escapeHtml(cfg.tunnel_hosts_hint || 'Tablet hosts: 127.0.0.1 workstation.local') + '<br>';
            }
            if (cfg.ssh_tunnel_cmd_named) {
                diagHtml += '<strong>SSH alias:</strong> <code>' + escapeHtml(cfg.ssh_tunnel_cmd_named) + '</code> (Host ' + escapeHtml(cfg.ssh_config_host || 'comserv-aew') + ')<br>';
            }
            diagHtml += '<span style="color:#ffaa00;">⚠️ Do not use raw IP 192.168.1.199 — not a configured site domain.</span><br>';
        }
        if (cfg.project_root) {
            diagHtml += '<strong>Project root:</strong> ' + escapeHtml(cfg.project_root) + ' — expand lib/ or root/ in the tree.<br>';
        }
        diagHtml += '</div></details>';
        addMsg(diagHtml, 'system', true);

        var host = window.location.hostname || '';
        var isRemote = cfg.remote_ok && !/^(localhost|127\.0\.0\.1)$/i.test(host)
            && !/\.local$/i.test(host);
        if (isRemote || cfg.grok_mode === 'xai_api') {
            state.backend = 'comserv';
            var be = q('#aew-backend');
            if (be) be.value = 'comserv';
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