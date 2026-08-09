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
