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
        /* ---- Card open-state memory (every card starts CLOSED) --------------
           Each card on /admin/git is a <details> that starts closed. Actions on
           this page reload it (a git op reloads after ~1.5s, merge reloads too),
           so without this the card being worked in would shut after every
           Stage/Commit. Keys are the summary label with counts and the branch
           pill stripped, kept in sessionStorage for this tab only — a fresh
           visit still opens fully closed. */
        (function () {
            var KEY = 'gitdash.openCards';
            var cards = [].slice.call(document.querySelectorAll('details.git-collapse'));
            if (!cards.length) { return; }
            function keyOf(d, i) {
                var s = d.querySelector('summary');
                var label = '';
                if (s) {
                    var copy = s.cloneNode(true);
                    var strip = copy.querySelectorAll('.git-count, .git-current-branch');
                    for (var k = 0; k < strip.length; k++) {
                        if (strip[k].parentNode) { strip[k].parentNode.removeChild(strip[k]); }
                    }
                    label = (copy.textContent || '').replace(/\s+/g, ' ').trim();
                }
                return d.id || label || ('card-' + i);
            }
            function save() {
                var open = cards.filter(function (d) { return d.open; }).map(keyOf);
                try { sessionStorage.setItem(KEY, JSON.stringify(open)); } catch (e) {}
            }
            var saved = [];
            try { saved = JSON.parse(sessionStorage.getItem(KEY) || '[]') || []; } catch (e) { saved = []; }
            for (var i = 0; i < cards.length; i++) {
                if (saved.indexOf(keyOf(cards[i], i)) >= 0) { cards[i].open = true; }
                cards[i].addEventListener('toggle', save);
            }
        })();

        document.addEventListener('click', function (e) {
            var btn = e.target && e.target.closest ? e.target.closest('[data-guard-copy]') : null;
            if (!btn) { return; }
            var hit = btn.parentNode ? btn.parentNode.parentNode : null;
            var box = hit ? hit.querySelector('[data-guard-prompt]') : null;
            if (!box) { return; }
            var text = box.value || '';
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(function () {
                    btn.textContent = 'Copied';
                });
            } else {
                box.select();
                document.execCommand('copy');
                btn.textContent = 'Copied';
            }
        });

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

        function showDevConsole(branch, port, url, cmd, kind) {
            if (!devConsole) { return; }
            devTitle.textContent = 'Starting ' + branch + ' on port ' + port + '…';
            devCmd.textContent = cmd || '';
            devLog.textContent = '(waiting for output…)';
            devLog.scrollTop = 0;
            if (devOpenLink && url) { devOpenLink.href = url; devOpenLink.style.display = ''; }
            else if (devOpenLink) { devOpenLink.style.display = 'none'; }
            devConsole.style.display = 'flex';

            if (devPollTimer) { clearInterval(devPollTimer); }
            var logQs = 'branch=' + encodeURIComponent(branch);
            if (kind) { logQs += '&kind=' + encodeURIComponent(kind); }
            devPollTimer = setInterval(function () {
                fetch('/admin/branch_server_log?' + logQs, {
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
            if (!branch || !port) {
                return Promise.reject(new Error('missing branch or port'));
            }
            if (btn) { btn.disabled = true; var prev = btn.textContent; }
            var body = new URLSearchParams();
            body.set('action', action);
            body.set('branch', branch);
            body.set('port', port);
            return fetch('/admin/branch_server_action', {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: body.toString(),
                credentials: 'same-origin'
            }).then(function (r) {
                var ct = r.headers.get('content-type') || '';
                if (r.status === 302 || r.redirected || ct.indexOf('json') === -1) {
                    throw new Error('not logged in (HTTP ' + r.status + ')');
                }
                return r.json();
            }).then(function (res) {
                if (!res || res.ok == 0) {
                    throw new Error((res && res.error) || (action + ' failed'));
                }
                return res;
            }).catch(function (err) {
                window.alert(action + ' ' + branch + ': ' + err.message);
                throw err;
            }).finally(function () { if (btn) { btn.disabled = false; btn.textContent = prev; } });
        }

        function navigateWhenBranchReady(branch, port, url, branchTab) {
            var attempts = 0;
            function navigate() {
                if (branchTab && !branchTab.closed) { branchTab.location = url; }
                else if (url) { window.location.href = url; }
            }
            function poll() {
                attempts += 1;
                var body = new URLSearchParams();
                body.set('action', 'open');
                body.set('branch', branch);
                body.set('port', port);
                fetch('/admin/branch_server_action', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: body.toString(),
                    credentials: 'same-origin'
                }).then(function (r) { return r.json(); })
                  .then(function (res) {
                      if (res && res.ok && res.running) {
                          navigate();
                      } else if (attempts < 60) {
                          window.setTimeout(poll, 500);
                      } else {
                          window.alert('Branch ' + branch + ' did not become ready on port ' + port + '.');
                      }
                  }).catch(function () {
                      if (attempts < 60) { window.setTimeout(poll, 500); }
                      else { window.alert('Branch ' + branch + ' did not become ready on port ' + port + '.'); }
                  });
            }
            poll();
        }

        var devServerButtons = document.querySelectorAll('.git-dev-actions button');
        for (var ds = 0; ds < devServerButtons.length; ds++) {
            devServerButtons[ds].addEventListener('click', function () {
                var el = this;
                var openBranch = el.getAttribute('data-open-branch');
                if (openBranch) {
                    var url = el.getAttribute('data-url') || '';
                    var cmd = el.getAttribute('data-cmd') || '';
                    // Reserve the tab from the user gesture, but do not navigate
                    // until the backend confirms that the branch is listening.
                    var branchTab = url ? window.open('about:blank', '_blank') : null;
                    if (branchTab && !branchTab.closed) {
                        try { branchTab.document.write('<p>Starting ' + openBranch + '…</p>'); } catch (e2) {}
                    }
                    // Then show the console so you can watch boot / copy the command.
                    showDevConsole(openBranch, el.getAttribute('data-port'), url, cmd);
                    branchServerAction('open', openBranch, el.getAttribute('data-port'), el)
                        .then(function (res) {
                            if (res && res.running) {
                                if (branchTab && !branchTab.closed) { branchTab.location = url; }
                                else if (url) { window.location.href = url; }
                            } else {
                                navigateWhenBranchReady(openBranch, el.getAttribute('data-port'), url, branchTab);
                            }
                        })
                        .catch(function () {
                            if (branchTab && !branchTab.closed) { branchTab.close(); }
                        });
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
                    var appPort = el.getAttribute('data-port') || '';
                    var appPortN = parseInt(appPort, 10) || 0;
                    var hport = el.getAttribute('data-hermes-port') || '';
                    if (!hport && (appPortN === 3001 || hermesBranch === 'main')) {
                        hport = '9119';
                    } else if (!hport && appPortN >= 4000) {
                        hport = String(9100 + (appPortN % 100));
                    } else if (!hport) {
                        window.alert('Hermes for ' + hermesBranch + ': button has no app port.');
                        return;
                    }
                    var hcwd = el.getAttribute('data-hermes-cwd') || '';
                    if (!hcwd) {
                        hcwd = hermesBranch === 'main'
                            ? '/home/shanta/PycharmProjects/comserv2'
                            : '/home/shanta/.comserv/worktrees/' + hermesBranch + '/Comserv';
                    }
                    var hcmd = el.getAttribute('data-hermes-cmd') || (
                        'cd ' + hcwd
                        + ' && hermes dashboard --isolated --host 0.0.0.0 --port '
                        + hport + ' --no-open --skip-build'
                    );
                    var hermesUrl = window.location.protocol + '//' + window.location.hostname
                        + ':' + hport + '/';
                    // Open the dashboard on the click itself. A blank tab that we
                    // navigate later gets blocked, and a failed start used to close it.
                    var tab = window.open(hermesUrl, 'hermes-' + hermesBranch);
                    if (navigator.clipboard && navigator.clipboard.writeText) {
                        navigator.clipboard.writeText(hcmd);
                    }
                    showDevConsole(hermesBranch, hport, hermesUrl, hcmd, 'hermes');
                    function goHermes(port) {
                        var url = window.location.protocol + '//' + window.location.hostname
                            + ':' + port + '/';
                        if (devOpenLink) { devOpenLink.href = url; devOpenLink.style.display = ''; }
                        if (url === hermesUrl) { return; }
                        if (tab && !tab.closed) { tab.location = url; }
                        else { window.open(url, 'hermes-' + hermesBranch); }
                    }
                    function waitReady(port) {
                        var n = 0;
                        var timer = setInterval(function () {
                            n += 1;
                            fetch('/admin/branch_server_log?kind=hermes&branch='
                                    + encodeURIComponent(hermesBranch),
                                { credentials: 'same-origin' })
                                .then(function (r) { return r.text(); })
                                .then(function (txt) {
                                    if ((txt && txt.indexOf('HERMES_DASHBOARD_READY') !== -1) || n >= 25) {
                                        clearInterval(timer);
                                        goHermes(port);
                                    }
                                })
                                .catch(function () {
                                    if (n >= 25) { clearInterval(timer); goHermes(port); }
                                });
                        }, 400);
                    }
                    branchServerAction('hermes', hermesBranch, String(appPortN), el)
                        .then(function (res) {
                            var port = String((res && res.hermes_port) || hport);
                            if (hermesBranch !== 'main' && port === '9119') { port = hport; }
                            if (res && res.running) { goHermes(port); }
                            else { waitReady(port); }
                        })
                        .catch(function () {
                            if (devOpenLink) { devOpenLink.href = hermesUrl; devOpenLink.style.display = ''; }
                        });
                    return;
                }
                var action = el.getAttribute('data-branch-action');
                if (action) {
                    var bname = el.getAttribute('data-branch');
                    branchServerAction(action, bname, el.getAttribute('data-port'), el)
                        .then(function (res) {
                            if (action !== 'stop' && action !== 'restart' && action !== 'start') { return; }
                            var bits = [action, bname];
                            if (res && res.via) { bits.push('via ' + res.via); }
                            if (res && res.unit) { bits.push(res.unit); }
                            if (res && res.cleared && res.cleared.length) {
                                bits.push('stopped pid ' + res.cleared.join(','));
                            }
                            if (res && res.running) { bits.push('listening on :' + res.port); }
                            window.alert(bits.join(' '));
                        });
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

        function renderGuardHits(hits) {
            var host = document.querySelector('[data-git-guard-hits]');
            if (!host) { return; }
            while (host.firstChild) { host.removeChild(host.firstChild); }
            if (!hits || !hits.length) {
                host.hidden = true;
                return;
            }
            host.hidden = false;
            host.className = 'admin-alert admin-alert-danger';
            var heading = document.createElement('strong');
            heading.textContent = 'Secret guard — how to fix';
            host.appendChild(heading);
            for (var i = 0; i < hits.length; i++) {
                var h = hits[i] || {};
                var block = document.createElement('div');
                block.className = 'git-guard-hit';
                var where = document.createElement('p');
                var loc = h.file || '';
                if (h.line) { loc += ':' + h.line; }
                where.textContent = loc + ' — ' + (h.reason || '');
                block.appendChild(where);
                if (h.editor_note) {
                    var note = document.createElement('p');
                    note.textContent = h.editor_note;
                    block.appendChild(note);
                }
                if (h.editor_url) {
                    var actions = document.createElement('p');
                    var link = document.createElement('a');
                    link.className = 'admin-btn admin-btn-sm admin-btn-primary';
                    link.href = h.editor_url;
                    link.target = 'AI2Editor';
                    link.rel = 'noopener';
                    link.textContent = 'Open in AI editor';
                    actions.appendChild(link);
                    var copyBtn = document.createElement('button');
                    copyBtn.type = 'button';
                    copyBtn.className = 'admin-btn admin-btn-sm';
                    copyBtn.setAttribute('data-guard-copy', '1');
                    copyBtn.textContent = 'Copy fix prompt';
                    actions.appendChild(copyBtn);
                    block.appendChild(actions);
                }
                var box = document.createElement('textarea');
                box.className = 'form-control';
                box.rows = 8;
                box.readOnly = true;
                box.setAttribute('data-guard-prompt', '1');
                box.value = h.prompt || '';
                block.appendChild(box);
                host.appendChild(block);
            }
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
            }).then(function (r) {
                if (!r.ok || !/application\/json/.test(r.headers.get('content-type') || '')) {
                    return r.text().then(function (txt) {
                        var why = 'Merge request returned a non-JSON response (HTTP ' + r.status + ').';
                        if (r.status === 403) { why = 'Administrator access required to merge.'; }
                        else if (txt && txt.length) { why += ' ' + txt.slice(0, 400); }
                        throw new Error(why);
                    });
                }
                return r.json();
            })
              .then(function (res) {
                  console.log('[git-dashboard] merge response:', res);
                  var stashNote = '';
                  if (res.autostash_conflict) {
                      stashNote = 'WIP not cleanly reapplied \u2014 safe in stash@{0} (use Stash Pop)';
                  } else if (res.autostash) {
                      stashNote = 'uncommitted changes preserved & reapplied';
                  }

                  function buildFailBody(r) {
                      var parts = [];
                      if (r.error) { parts.push(String(r.error)); }
                      if (r.fix_hint && (!r.error || String(r.error).indexOf(r.fix_hint) < 0)) {
                          parts.push('What to do: ' + r.fix_hint);
                      }
                      if (r.uncommitted_files && r.uncommitted_files.length) {
                          parts.push('Uncommitted files:\n  - ' + r.uncommitted_files.slice(0, 20).join('\n  - '));
                      }
                      if (r.conflict_files && r.conflict_files.length) {
                          parts.push('Conflict files:\n  - ' + r.conflict_files.join('\n  - '));
                      }
                      if (r.checkout_path) {
                          parts.push('Checkout: ' + r.checkout_path
                              + (r.target_branch ? ' (branch ' + r.target_branch + ')' : ''));
                      }
                      if (r.output && String(r.output).replace(/\s/g, '').length) {
                          parts.push('--- git detail ---\n' + r.output);
                      }
                      if (r.detail && String(r.detail).replace(/\s/g, '').length) {
                          parts.push(String(r.detail));
                      }
                      return parts.join('\n\n') || 'merge failed';
                  }

                  function failTitle(r) {
                      if (r.reason === 'uncommitted_on_main') {
                          return 'blocked \u2014 main has uncommitted changes';
                      }
                      if (r.reason === 'uncommitted' || r.uncommitted) {
                          return 'blocked \u2014 uncommitted changes';
                      }
                      if (r.reason === 'worktree_collision') {
                          return 'blocked \u2014 worktree checkout collision';
                      }
                      if (r.conflict || r.reason === 'conflict') {
                          return 'conflict';
                      }
                      if (r.reason === 'merge_in_progress') {
                          return 'blocked \u2014 merge already in progress';
                      }
                      if (r.reason === 'secret_guard') {
                          return 'blocked \u2014 secret guard';
                      }
                      if (r.reason === 'missing_ref') {
                          return 'failed \u2014 branch/ref not found';
                      }
                      return 'failed';
                  }

                  if (res.conflict) {
                      showMergeResult(false, true, failTitle(res), buildFailBody(res), stashNote);
                      return;
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
                      showMergeResult(false, false, failTitle(res), buildFailBody(res), stashNote);
                      renderGuardHits(res.hits);
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
                }).then(function (r) {
                    if (!r.ok || !/application\/json/.test(r.headers.get('content-type') || '')) {
                        return r.text().then(function (txt) {
                            var why = 'Merge-abort returned a non-JSON response (HTTP ' + r.status + ').';
                            if (txt && txt.length) { why += ' ' + txt.slice(0, 400); }
                            throw new Error(why);
                        });
                    }
                    return r.json();
                })
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
                    // Default to north-mini-code (cheap/free coding model) for commit message drafting
                    // instead of letting automatic selection potentially pick Grok/SuperGrok.
                    aiModelSelect.value = 'openrouter|cohere/north-mini-code:free';
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
                        if (status && data.junk_files && data.junk_files.length) {
                            status.textContent += ' Warning: backup/runtime file(s) in this change - ' +
                                data.junk_files.join(', ') +
                                '. The commit guard will refuse them; use "Untrack + gitignore"' +
                                ' (reload the page if the button is not shown).';
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

// Oct 31 2026 (Shanta): "Update all branches from main" card. Rows are rendered with textContent only (no HTML from the server).
(function () {
    'use strict';
    var box = document.querySelector('[data-git-update-all]');
    if (!box) { return; }
    var url = box.getAttribute('data-update-all-url');
    var csrf = box.getAttribute('data-csrf') || '';
    var summary = box.querySelector('[data-update-all-summary]');
    var table = box.querySelector('[data-update-all-table]');
    var tbody = table ? table.querySelector('tbody') : null;
    var buttons = box.querySelectorAll('[data-update-all-mode]');
    // No form here on purpose: the card sits inside the Working Tree form, and a
    // nested <form> is dropped by the parser. Buttons are links, so a click always
    // navigates; when this script runs we upgrade it to an AJAX POST in place.
    var form = null;

    function cell(tr, text) { var td = document.createElement('td'); td.textContent = text == null ? '' : String(text); tr.appendChild(td); }
    function render(data) {
        summary.textContent = data.summary || data.error || '';
        if (!tbody || !data.rows) { return; }
        while (tbody.firstChild) { tbody.removeChild(tbody.firstChild); }
        data.rows.forEach(function (r) {
            var tr = document.createElement('tr');
            cell(tr, r.key); cell(tr, r.branch); cell(tr, r.port ? ':' + r.port : '');
            cell(tr, r.action + (r.autostash ? ' (autostash)' : '') + (r.tree ? ' \u2014 ' + r.tree : ''));
            cell(tr, r.needs_manual ? '\u2691 needs manual' : '');
            cell(tr, (r.behind != null ? r.behind : '') + (r.ahead != null ? ' / ' + r.ahead : ''));
            cell(tr, r.pre_merge_commit ? r.pre_merge_commit.substring(0, 10) : '');
            var bits = [];
            if (r.files && r.files.length) { bits.push(r.files.join(', ')); }
            if (r.reason) { bits.push(r.reason); }
            if (r.dirty_files && r.dirty_files.length && !(r.files && r.files.length)) { bits.push('uncommitted kept: ' + r.dirty_files.join(', ')); }
            if (r.manual_files && r.manual_files.length) { bits.push('conflict in: ' + r.manual_files.join(', ')); }
            if (r.stash) { bits.push('stash: ' + String(r.stash).substring(0, 60)); }
            cell(tr, bits.join(' - '));
            cell(tr, r.will_restart ? 'yes' : '');
            tbody.appendChild(tr);
        });
        table.hidden = false;
    }
    function run(mode) {
            if (mode === 'update' && !window.confirm('Merge main into every registered branch now? Running -r dev servers will restart. Run Preview first if unsure.')) { return; }
            var body = new URLSearchParams();
            body.set('mode', mode); body.set('csrf', csrf);
            if (summary) { summary.textContent = mode === 'update' ? 'Updating...' : 'Previewing...'; }
            Array.prototype.forEach.call(buttons, function (b) { b.disabled = true; });
            fetch(url, { method: 'POST', credentials: 'same-origin', body: body,
                         headers: { 'Content-Type': 'application/x-www-form-urlencoded',
                                    'Accept': 'application/json' } })
                .then(function (r) {
                    // A 302 to /user/login (or any HTML error page) is not JSON. Without this guard the
                    // card shows only "Request failed: SyntaxError" and looks like a dead button.
                    var ct = (r.headers.get('content-type') || '').toLowerCase();
                    if (ct.indexOf('json') === -1) {
                        // 404 is NOT an auth problem: the card markup comes from the template on
                        // disk, but Catalyst compiles controller actions at startup. A worktree
                        // whose dev server predates the merged endpoint renders this card and
                        // then 404s every click. Say that instead of blaming the session.
                        if (r.status === 404) {
                            throw new Error('HTTP 404 ' + (ct || 'no content-type') +
                                            ' — this action is not loaded in the running server' +
                                            ' (stale pre-merge code). Restart that worktree\'s dev server, then reload this page.');
                        }
                        throw new Error('HTTP ' + r.status + ' ' + (ct || 'no content-type') +
                                        ' — you are probably signed out. Reload the Git page and sign in again.');
                    }
                    return r.json();
                })
                .then(render)
                .catch(function (e) { if (summary) { summary.textContent = 'Request failed: ' + e; } })
                .then(function () { Array.prototype.forEach.call(buttons, function (b) { b.disabled = false; }); });
    }
    // Only take over the submit when the JS path can actually finish. Any doubt,
    // any throw: fall back to the browser's native POST so the click is never lost.
    // (Shanta 2026-11-03: a preventDefault() followed by a throw left the buttons
    // disabled and the card dead — no request, no message, nothing.)
    // Self-reporting: the card shows any uncaught script error inline.
    window.addEventListener('error', function (e) {
        if (!summary) { return; }
        summary.textContent = 'JS ERROR: ' + (e.message || 'unknown')
            + ' @ ' + String(e.filename || '').split('/').pop() + ':' + (e.lineno || '?');
    });
    // Links always navigate — there is no form to be swallowed by the outer one.
    // When this script runs we POST in place for a nicer result, and any failure
    // falls back to the plain link so the action is never lost.
    Array.prototype.forEach.call(buttons, function (btn) {
        btn.addEventListener('click', function (ev) {
            if (!url || !window.fetch) { return; }
            var mode = btn.getAttribute('data-update-all-mode') || 'preview';
            if (mode === 'update' && !window.confirm('Merge main into every registered branch now? Running -r dev servers will restart. Run Preview first if unsure.')) {
                ev.preventDefault();
                return;
            }
            ev.preventDefault();
            try {
                run(mode);
            } catch (e) {
                if (btn.href) { window.location = btn.href; }
            }
        });
    });
    if (summary && !summary.textContent) {
        summary.textContent = 'Ready — click Preview.';
    }
})();
