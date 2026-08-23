/*
 * git-dashboard.js
 * Behaviour for the Admin Git dashboard (/admin/git).
 *
 * Modular, delegation-based — no inline script in the template. Wires:
 *   - "select all" checkbox
 *   - the per-file action buttons (stage/unstage/commit/stash/gitignore/delete)
 *   - simple confirm() gating (delete of untracked files gets a SECOND confirm)
 *
 * Each action button sets the hidden `op` field on the shared file form and submits it,
 * so only the checked `paths` are posted. The server re-validates every path against
 * `git status` before acting, so this JS is convenience/UX only, not a security boundary.
 */
(function () {
    'use strict';

    function ready(fn) {
        if (document.readyState !== 'loading') { fn(); }
        else { document.addEventListener('DOMContentLoaded', fn); }
    }

    ready(function () {
        // Shared branch + worktree creation used by both the Git dashboard and
        // the AI editor Git panel.  Both surfaces call the same admin endpoint.
        var createForms = document.querySelectorAll('[data-create-worktree-form]');
        for (var cf = 0; cf < createForms.length; cf++) {
            createForms[cf].addEventListener('submit', function (e) {
                e.preventDefault();
                var formEl = this;
                var statusEl = formEl.querySelector('[data-create-worktree-status]')
                    || formEl.parentNode.querySelector('[data-create-worktree-status]');
                var data = new URLSearchParams(new FormData(formEl));
                var branch = data.get('branch') || '';
                if (!branch) return;
                if (statusEl) statusEl.textContent = 'Creating branch and worktree…';
                fetch('/admin/git/create_worktree', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                    credentials: 'same-origin',
                    body: data.toString()
                }).then(function (r) { return r.json(); })
                  .then(function (result) {
                      if (!result.success) throw new Error(result.error || 'Creation failed');
                      if (statusEl) statusEl.textContent = 'Created ' + result.branch +
                          ' on port ' + result.port + '\n' + (result.path || '');
                      formEl.reset();
                      var parent = formEl.querySelector('[name="parent"]');
                      if (parent) parent.value = 'main';
                  })
                  .catch(function (err) {
                      if (statusEl) statusEl.textContent = 'Git error: ' + err.message;
                  });
            });
        }

        var form = document.querySelector('[data-git-file-form]');

        // "Select all" toggle (only present when the working tree has changes).
        var checkAll = document.querySelector('[data-git-check-all]');
        if (checkAll) {
            checkAll.addEventListener('change', function () {
                var boxes = document.querySelectorAll('[data-git-file]');
                for (var i = 0; i < boxes.length; i++) {
                    boxes[i].checked = checkAll.checked;
                }
            });
        }

        // Top-level (Pull/Safe Pull/Push) forms carrying a confirm prompt.
        var confirmForms = document.querySelectorAll('form[data-git-confirm]');
        for (var i = 0; i < confirmForms.length; i++) {
            confirmForms[i].addEventListener('submit', function (e) {
                var prompt = this.getAttribute('data-git-confirm');
                if (prompt && !window.confirm(prompt)) {
                    e.preventDefault();
                }
            });
        }

        // Host / target selector: re-scope the whole dashboard to the chosen host
        // (local, or a remote host the app SSHes into). Reloading with ?target=KEY
        // keeps everything else (branch, working tree) consistent for that host.
        var targetSelect = document.getElementById('git-target-select');
        if (targetSelect) {
            targetSelect.addEventListener('change', function () {
                var key = this.value || 'local';
                var base = window.location.pathname.split('?')[0];
                var q = new URLSearchParams(window.location.search);
                q.set('target', key);
                window.location.href = base + '?' + q.toString();
            });
        }

        // Before any action form posts, make sure it carries the current host
        // target so the write lands on the right machine.
        function appendTarget(formEl) {
            if (!formEl || !targetSelect) { return; }
            var existing = formEl.querySelector('input[name="target"]');
            if (existing) { existing.value = targetSelect.value; return; }
            var hidden = document.createElement('input');
            hidden.type = 'hidden';
            hidden.name = 'target';
            hidden.value = targetSelect.value;
            formEl.appendChild(hidden);
        }

        // Branch switch via dropdown: submit the parent form on change, with a
        // confirm (uncommitted changes are auto-stashed server-side).
        var switchSelect = document.querySelector('[data-git-switch-select]');
        if (switchSelect) {
            switchSelect._gitPrev = switchSelect.value;
            switchSelect.addEventListener('change', function () {
                if (!window.confirm("Switch to branch '" + this.value +
                        "'? Uncommitted changes are auto-stashed.")) {
                    this.value = this._gitPrev;   // revert selection
                    return;
                }
                var f = this.closest('form[data-git-switch-form]');
                appendTarget(f);
                if (f) { f.submit(); }
            });
        }

        // All POST action forms (Pull / Safe Pull / Push / Switch / Remove) need
        // the target so they run against the selected host.
        var postForms = document.querySelectorAll('form[action*="/admin/git/action"],'
            + 'form[action*="/admin/git_pull"],form[action*="/admin/safe_git_pull"]');
        for (var p = 0; p < postForms.length; p++) {
            appendTarget(postForms[p]);
        }

        // --- "Develop Servers" card: Open / Stop / Restart for zenflow worktree
        // branches. BOUND BEFORE the `if (!form) return` guard below, because the
        // working-tree form is absent when the tree is clean — otherwise these
        // buttons would never get wired and clicking would do nothing. Open opens the
        // branch in a new window (like the old planning-tab button) AND shows a live
        // console you can copy the command from; Stop/Restart POST to
        // /admin/branch_server_action and surface the JSON result.

        // Live console modal elements (resolved once).
        var devConsole    = document.getElementById('git-dev-console');
        var devTitle      = document.getElementById('git-dev-console-title');
        var devCmd        = document.getElementById('git-dev-console-cmd');
        var devLog        = document.getElementById('git-dev-console-log');
        var devOpenLink   = document.getElementById('git-dev-console-open');
        var devPollTimer  = null;

        function closeDevConsole() {
            if (devConsole) { devConsole.style.display = 'none'; }
            if (devPollTimer) { clearInterval(devPollTimer); devPollTimer = null; }
        }

        function showDevConsole(branch, port, url, cmd) {
            if (!devConsole) { return; }
            devTitle.textContent = 'Starting ' + branch + ' on port ' + port + '…';
            devCmd.textContent = cmd || '';
            devLog.textContent = '(waiting for output…)';
            devLog.scrollTop = 0;
            if (devOpenLink && url) { devOpenLink.href = url; devOpenLink.style.display = ''; }
            else if (devOpenLink) { devOpenLink.style.display = 'none'; }
            devConsole.style.display = 'flex';

            if (devPollTimer) { clearInterval(devPollTimer); }
            devPollTimer = setInterval(function () {
                fetch('/admin/branch_server_log?branch=' + encodeURIComponent(branch), {
                    credentials: 'same-origin'
                }).then(function (r) { return r.text(); })
                  .then(function (text) {
                      if (devLog) {
                          devLog.textContent = text || '(no output yet)';
                          devLog.scrollTop = devLog.scrollHeight;
                      }
                  })
                  .catch(function () {});
            }, 1500);
        }

        // Close buttons inside the console.
        var devCloseBtns = document.querySelectorAll('[data-git-dev-console-close]');
        for (var dc = 0; dc < devCloseBtns.length; dc++) {
            devCloseBtns[dc].addEventListener('click', closeDevConsole);
        }

        function branchServerAction(action, branch, port, btn) {
            if (!branch || !port) return;
            if (btn) { btn.disabled = true; var prev = btn.textContent; }
            var body = new URLSearchParams();
            body.set('action', action);
            body.set('branch', branch);
            body.set('port', port);
            fetch('/admin/branch_server_action', {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: body.toString(),
                credentials: 'same-origin'
            }).then(function (r) { return r.json(); })
              .then(function (res) {
                  if (!res || res.ok == 0) {
                      throw new Error((res && res.error) || (action + ' failed'));
                  }
              })
              .catch(function (err) { window.alert(action + ' ' + branch + ': ' + err.message); })
              .finally(function () { if (btn) { btn.disabled = false; btn.textContent = prev; } });
        }

        var devServerButtons = document.querySelectorAll('.git-dev-actions button');
        for (var ds = 0; ds < devServerButtons.length; ds++) {
            devServerButtons[ds].addEventListener('click', function () {
                var el = this;
                var openBranch = el.getAttribute('data-open-branch');
                if (openBranch) {
                    var url = el.getAttribute('data-url') || '';
                    var cmd = el.getAttribute('data-cmd') || '';
                    // Old behaviour first: open the branch in a new browser window.
                    if (url) { window.open(url, '_blank'); }
                    // Then show the console so you can watch boot / copy the command.
                    showDevConsole(openBranch, el.getAttribute('data-port'), url, cmd);
                    branchServerAction('open', openBranch, el.getAttribute('data-port'), el);
                    return;
                }
                // "Hermes" button: copy the branch's Hermes launch command to the
                // clipboard. cwd = the worktree git-root, so Hermes auto-loads the
                // branch .hermes.md (global rules + domain expertise). Do NOT add
                // -w here: Comserv worktrees already isolate; -w nests a
                // hermes/hermes-* scratch branch. The dev console also shows the
                // command for manual copy.
                var hermesBranch = el.getAttribute('data-hermes-branch');
                if (hermesBranch) {
                    var hcmd = el.getAttribute('data-hermes-cmd') || '';
                    if (navigator.clipboard && navigator.clipboard.writeText) {
                        navigator.clipboard.writeText(hcmd).then(function () {
                            if (typeof window.HermesNotify === 'function') {
                                window.HermesNotify('Copied Hermes command for ' + hermesBranch);
                            } else {
                                window.alert('Copied to clipboard:\n' + hcmd);
                            }
                        }).catch(function () { window.alert(hcmd); });
                    } else {
                        window.alert(hcmd);
                    }
                    showDevConsole(hermesBranch, el.getAttribute('data-port') || '', '', hcmd);
                    return;
                }
                var action = el.getAttribute('data-branch-action');
                if (action) {
                    branchServerAction(action, el.getAttribute('data-branch'),
                        el.getAttribute('data-port'), el);
                }
            });
        }

        // --- "Merge" card: merge main into a selected branch, or the selected
        // branch into main. POSTs to /admin/git/merge (source/target) and renders
        // a status badge + output <pre>. On conflict, reveals the Abort button
        // (POST /admin/git/merge/abort). Both directions run inside the branch's
        // own worktree checkout (main->branch) or by branch-name ref (branch->main),
        // so neither requires switching the active branch.
        var mergeSelect = document.querySelector('[data-git-merge-select]');
        var mergeStatus = document.querySelector('[data-git-merge-status]');
        var mergeOutput = document.querySelector('[data-git-merge-output]');
        var mergeAbortBtn = document.querySelector('[data-git-merge-abort]');

        var MERGE_RESULT_KEY = 'comserv-git-merge-result';

        function persistMergeResult(payload) {
            try {
                sessionStorage.setItem(MERGE_RESULT_KEY, JSON.stringify(payload));
            } catch (e) {
                // sessionStorage can be blocked; reload still proceeds.
            }
        }

        function restorePersistedMergeResult() {
            try {
                var raw = sessionStorage.getItem(MERGE_RESULT_KEY);
                if (!raw) { return; }
                sessionStorage.removeItem(MERGE_RESULT_KEY);
                var p = JSON.parse(raw);
                if (!p || !p.title) { return; }
                showMergeResult(!!p.success, !!p.conflict, p.title, p.output || '');
            } catch (e) {
                try { sessionStorage.removeItem(MERGE_RESULT_KEY); } catch (e2) {}
            }
        }

        function reloadGitDashboardSoon() {
            window.setTimeout(function () {
                window.location.reload();
            }, 1500);
        }

        function showMergeResult(success, conflict, title, output, autostashNote) {
            if (!mergeStatus) { return; }
            mergeStatus.innerHTML = '';
            var badge = document.createElement('span');
            badge.className = 'status-badge ' + (conflict ? 'status-badge-warn'
                : (success ? 'status-badge-ok' : 'status-badge-err'));
            badge.textContent = title;
            mergeStatus.appendChild(badge);
            if (autostashNote) {
                var note = document.createElement('span');
                note.className = 'status-badge status-badge-warn';
                note.style.marginLeft = '6px';
                note.textContent = autostashNote;
                mergeStatus.appendChild(note);
            }
            if (mergeOutput) {
                mergeOutput.style.display = (output && output.length) ? 'block' : 'none';
                mergeOutput.textContent = output || '';
            }
            if (mergeAbortBtn) {
                mergeAbortBtn.style.display = conflict ? '' : 'none';
            }
        }

        restorePersistedMergeResult();

        function runMerge(btn) {
            if (!mergeSelect) { return; }
            var direction = btn.getAttribute('data-merge-direction');
            var selBranch = mergeSelect.value || '';
            var source, target;
            if (direction === 'main-to-branch') { source = 'main'; target = selBranch; }
            else { source = selBranch; target = 'main'; }

            var curEl = document.querySelector('[data-git-current-branch]');
            var current = (curEl && curEl.textContent) ? curEl.textContent.trim() : '';
            if (current && current !== 'main' && current !== 'master') {
                if (direction === 'main-to-branch') { target = current; }
                else { source = current; }
            }
            if (source === target || !target || target === 'main' && direction === 'main-to-branch') {
                showMergeResult(false, false, 'failed',
                    'Pick the worktree branch. main cannot merge into itself.');
                return;
            }

            if (btn.getAttribute('data-git-confirm')) {
                var prompt = btn.getAttribute('data-git-confirm');
                if (prompt && !window.confirm(prompt)) { return; }
            }

            if (mergeStatus) {
                mergeStatus.innerHTML = '<span class="status-badge">working…</span>';
            }
            if (mergeAbortBtn) { mergeAbortBtn.style.display = 'none'; }
            if (mergeOutput) { mergeOutput.style.display = 'none'; }

            var body = new URLSearchParams();
            body.set('source', source);
            body.set('target', target);
            if (targetSelect) { body.set('target_host', targetSelect.value); }

            fetch(btn.getAttribute('data-merge-url'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: body.toString(),
                credentials: 'same-origin'
            }).then(function (r) { return r.json(); })
              .then(function (res) {
                  console.log('[git-dashboard] merge response:', res);
                  if (res.conflict) {
                      // Lead with WHY: the server now names the conflicting
                      // files (or the uncommitted-changes blocker) in res.error;
                      // raw git output stays in the <pre> as detail.
                      var why = res.error || 'Merge conflict';
                      showMergeResult(false, true, 'conflict', why + '\n\n' + (res.output || ''));
                      return;
                  }
                  var stashNote = '';
                  if (res.autostash_conflict) {
                      stashNote = 'WIP not cleanly reapplied \u2014 safe in stash@{0} (use Stash Pop)';
                  } else if (res.autostash) {
                      stashNote = 'uncommitted changes preserved & reapplied';
                  }
                  if (res.success) {
                      showMergeResult(true, false, 'merged \u2014 reloading\u2026', res.output || '', stashNote);
                      persistMergeResult({
                          success: true,
                          conflict: false,
                          title: 'merged',
                          output: res.output || ''
                      });
                      reloadGitDashboardSoon();
                  } else {
                      var failText = (res.error || '') + (res.output && res.output.replace(/\s/g,'') ? ('\n' + res.output) : '') + (res.detail ? ('\n' + res.detail) : '');
                      showMergeResult(false, false, 'failed', failText || 'merge failed', stashNote);
                  }
              })
              .catch(function (err) {
                  showMergeResult(false, false, 'error', String(err));
              });
        }

        var mergeBtns = document.querySelectorAll('[data-git-merge]');
        for (var mb = 0; mb < mergeBtns.length; mb++) {
            mergeBtns[mb].addEventListener('click', function () { runMerge(this); });
        }

        if (mergeAbortBtn) {
            mergeAbortBtn.addEventListener('click', function () {
                if (!window.confirm('Abort the in-progress merge? This discards the merge attempt.')) {
                    return;
                }
                if (mergeStatus) {
                    mergeStatus.innerHTML = '<span class="status-badge">aborting…</span>';
                }
                var body = new URLSearchParams();
                if (targetSelect) { body.set('target_host', targetSelect.value); }
                fetch(mergeAbortBtn.getAttribute('data-merge-abort-url'), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: body.toString(),
                    credentials: 'same-origin'
                }).then(function (r) { return r.json(); })
                  .then(function (res) {
                      showMergeResult(res.success, false, res.success ? 'aborted' : 'abort failed',
                          res.output || res.error || '');
                      if (res.success) {
                          if (typeof window.refreshGitDashboard === 'function') {
                              window.refreshGitDashboard();
                          } else { window.location.reload(); }
                      }
                  })
                  .catch(function (err) {
                      showMergeResult(false, false, 'abort error', String(err));
                  });
            });
        }

        if (!form) { return; }

        var opField        = form.querySelector('[data-git-op-field]');
        var permanentField = form.querySelector('[data-git-permanent-field]');

        function selectedBoxes() {
            return form.querySelectorAll('[data-git-file]:checked');
        }

        // "Suggest message with AI" — POST selected paths (if any) to the suggest
        // endpoint and drop the returned message into the commit/stash input.
        var suggestBtn = document.querySelector('[data-git-suggest]');
        var aiModelSelect = document.querySelector('[data-git-ai-model]');
        if (aiModelSelect && window.ComservChat && ComservChat.modelSelect) {
            ComservChat.modelSelect.init({
                selectEl: aiModelSelect,
                context: 'code',
                onReady: function () {
                    // Full provider list is shown (Ollama + Grok + OpenRouter) so
                    // the user can choose a model that won't stall the workstation.
                    // Per explicit direction, all models are available everywhere;
                    // per-page defaulting/visibility is a separate later choice.
                    var automatic = document.createElement('option');
                    automatic.value = '';
                    automatic.textContent = 'Use automatic model selection';
                    aiModelSelect.insertBefore(automatic, aiModelSelect.firstChild);
                    aiModelSelect.value = '';
                },
                onError: function () {
                    aiModelSelect.innerHTML = '<option value="">Automatic model selection</option>';
                }
            });
        }
        if (suggestBtn) {
            suggestBtn.addEventListener('click', function () {
                var url    = suggestBtn.getAttribute('data-git-suggest-url');
                var status = document.querySelector('[data-git-suggest-status]');
                var msgInput = form.querySelector('[data-git-message]');
                if (!url) { return; }

                var body = new URLSearchParams();
                var boxes = selectedBoxes();
                for (var k = 0; k < boxes.length; k++) {
                    body.append('paths', boxes[k].value);
                }
                if (aiModelSelect && aiModelSelect.value) {
                    body.append('model', aiModelSelect.value);
                }

                suggestBtn.disabled = true;
                if (status) { status.textContent = 'Asking AI…'; }

                fetch(url, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: body.toString(),
                    credentials: 'same-origin'
                })
                .then(function (r) { return r.json(); })
                .then(function (data) {
                    if (data && data.success && data.message) {
                        if (msgInput) { msgInput.value = data.message; }
                        if (status) {
                            status.textContent = 'Drafted with ' + (data.model || 'AI') +
                                ' — review before committing.';
                        }
                    } else {
                        if (status) {
                            status.textContent = 'AI could not draft a message: ' +
                                ((data && data.error) || 'unknown error');
                        }
                    }
                })
                .catch(function (err) {
                    if (status) { status.textContent = 'Request failed: ' + err; }
                })
                .finally(function () { suggestBtn.disabled = false; });
            });
        }

        function anyUntrackedSelected() {
            var boxes = selectedBoxes();
            for (var j = 0; j < boxes.length; j++) {
                if (boxes[j].getAttribute('data-git-untracked')) { return true; }
            }
            return false;
        }

        // --- Per-file "Diff" buttons: open the file in the AI2 editor (which
        // shows its own diff via ai2editor/file-diff.js), instead of the inline
        // panel. The AI2 editor accepts ?file=<repo-relative path> and loads it.
        // (git_worktree_merge_plan §3.5 — the editor is one of the widget's
        // consumer surfaces; we route the user there rather than re-render.)
        function bindFileDiff() {
            var diffBtns = document.querySelectorAll('[data-git-view-diff]');
            for (var i = 0; i < diffBtns.length; i++) {
                diffBtns[i].addEventListener('click', function () {
                    var path = this.getAttribute('data-git-view-diff');
                    if (!path) return;
                    // git status is repo-relative (e.g. "Comserv/root/..."), but
                    // the AI2 editor + /ai2/file_diff expect app-relative paths
                    // (e.g. "root/..."), so strip the leading app-dir segment.
                    path = path.replace(/^Comserv\//, '');
                    var url = '/ai2/editing_widget_popup?file=' + encodeURIComponent(path);
                    window.open(url, 'AI2Editor',
                        'width=1250,height=820,resizable=yes,scrollbars=yes,' +
                        'menubar=no,toolbar=no,status=no,noopener,noreferrer');
                });
            }
        }
        bindFileDiff();

        var actionButtons = form.querySelectorAll('[data-git-action]');
        for (var b = 0; b < actionButtons.length; b++) {
            actionButtons[b].addEventListener('click', function () {
                var op = this.getAttribute('data-git-action');

                // Commit acts on the staging area, not the checkboxes.
                if (op !== 'commit' && selectedBoxes().length === 0) {
                    window.alert('Select at least one file first.');
                    return;
                }

                var prompt = this.getAttribute('data-git-confirm');
                if (prompt && !window.confirm(prompt)) { return; }

                // Untracked deletes are irreversible -> require a distinct second confirm.
                if (op === 'delete' && anyUntrackedSelected()) {
                    var ok = window.confirm(
                        'One or more selected files are UNTRACKED. Deleting them removes them ' +
                        'permanently from disk — git cannot recover them. Continue?');
                    if (!ok) { return; }
                    if (permanentField) { permanentField.value = '1'; }
                } else if (permanentField) {
                    permanentField.value = '';
                }

                if (opField) { opField.value = op; }
                appendTarget(form);
                form.submit();
            });
        }
    });
})();
