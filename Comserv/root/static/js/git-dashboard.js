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

        if (!form) { return; }

        var opField        = form.querySelector('[data-git-op-field]');
        var permanentField = form.querySelector('[data-git-permanent-field]');

        function selectedBoxes() {
            return form.querySelectorAll('[data-git-file]:checked');
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
                form.submit();
            });
        }
    });
})();
