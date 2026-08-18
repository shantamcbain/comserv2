/*
 * git-diff-viewer.js  (CANONICAL shared diff renderer)
 *
 * The single diff-view component required by
 * root/Documentation/system/git_worktree_merge_plan.tt §3.5. Every surface
 * (Git Dashboard working-tree rows, AI2 editor, merge review, suggest_message)
 * embeds THIS widget and only adds its own affordance buttons around it.
 * No other file renders a diff inline.
 *
 * Public API:
 *   ComservGitDiff.render(targetEl, diffText, opts)
 *       targetEl : the container element to populate (caller-owned panel).
 *       diffText : the raw unified-diff string from the backend.
 *       opts     : {
 *           scope       : 'file' | 'branch' | 'staged' | 'working-tree' (label only)
 *           editable    : bool  (reserved — edit surface lives in the caller)
 *           onApprove   : fn()  (optional — renders an Approve button)
 *           onReject    : fn()  (optional — renders a Reject button)
 *           title       : string (optional override for the panel heading)
 *           onClose     : fn()  (optional — replaces/handles the close button)
 *       }
 *
 *   ComservGitDiff.showLoading(targetEl, msg)
 *   ComservGitDiff.showError(targetEl, msg)
 *   ComservGitDiff.showMessage(targetEl, msg)
 *       Lightweight helpers so every caller shows identical load/error states
 *       (no per-surface copy of the "Loading…" / "Diff failed:" text).
 *
 * Pure V2 module: no inline <script>, no event duplication. Loaded via
 * root/js_load.tt with ?v=[% cv %] cache-bust, BEFORE any consumer.
 */
(function () {
    'use strict';

    var NS = 'ComservGitDiff';

    // ---- theme helpers ---------------------------------------------------
    // Use CSS custom properties, never hard-coded colors, so the widget
    // follows the active theme (light/dark). These classes are defined in
    // the app's diff CSS; the <pre> borrows the existing git-diff look.
    function el(tag, cls, text) {
        var e = document.createElement(tag);
        if (cls) { e.className = cls; }
        if (text !== undefined && text !== null) { e.textContent = text; }
        return e;
    }

    // Build a single <pre> with line numbers + light add/remove tinting.
    // We textContent every line (no innerHTML) so a malicious diff cannot
    // inject markup. Tint is applied via class only.
    function buildDiffPre(diffText) {
        var pre = el('pre', 'git-diff-viewer-pre');
        // Keep the same inline pre-wrap behaviour the old panels had, but
        // expressed through a class so it stays themeable.
        if (diffText && diffText.length) {
            var lines = String(diffText).split(/\r?\n/);
            for (var i = 0; i < lines.length; i++) {
                var line = lines[i];
                var row = el('div', 'git-diff-line');
                var ln = el('span', 'git-diff-ln', String(i + 1));
                var code = el('span', 'git-diff-code');
                if (line.charAt(0) === '+') {
                    row.classList.add('git-diff-add');
                } else if (line.charAt(0) === '-') {
                    row.classList.add('git-diff-del');
                } else if (line.charAt(0) === '@') {
                    row.classList.add('git-diff-hunk');
                }
                code.textContent = line === '' ? ' ' : line;
                row.appendChild(ln);
                row.appendChild(code);
                pre.appendChild(row);
            }
        } else {
            pre.appendChild(el('span', 'git-diff-empty', '(no differences)'));
        }
        return pre;
    }

    function buildHeader(opts) {
        var head = el('div', 'git-diff-viewer-head');
        head.style.cssText = 'display:flex;justify-content:space-between;' +
            'align-items:center;margin-bottom:6px;';

        var label = el('strong', 'git-diff-viewer-title');
        label.style.color = 'var(--text-color, #222)';
        label.textContent = (opts && opts.title) ? opts.title : 'Diff';

        var right = el('div', 'git-diff-viewer-actions');

        if (opts && typeof opts.onApprove === 'function') {
            var approve = el('button', 'admin-btn admin-btn-sm git-diff-approve', 'Approve');
            approve.type = 'button';
            approve.addEventListener('click', function () { opts.onApprove(); });
            right.appendChild(approve);
        }
        if (opts && typeof opts.onReject === 'function') {
            var reject = el('button', 'admin-btn admin-btn-sm git-diff-reject', 'Reject');
            reject.type = 'button';
            reject.addEventListener('click', function () { opts.onReject(); });
            right.appendChild(reject);
        }

        var close = el('button', 'admin-btn admin-btn-sm git-diff-close', 'Close');
        close.type = 'button';
        close.addEventListener('click', function () {
            if (opts && typeof opts.onClose === 'function') { opts.onClose(); }
            else if (head.parentNode) { head.parentNode.style.display = 'none'; }
        });
        right.appendChild(close);

        head.appendChild(label);
        head.appendChild(right);
        return head;
    }

    function render(targetEl, diffText, opts) {
        if (!targetEl) { return; }
        opts = opts || {};
        targetEl.innerHTML = '';
        targetEl.style.display = 'block';
        targetEl.appendChild(buildHeader(opts));
        targetEl.appendChild(buildDiffPre(diffText));
        if (targetEl.scrollIntoView) {
            targetEl.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        }
        return targetEl;
    }

    function showLoading(targetEl, msg) {
        if (!targetEl) { return; }
        targetEl.style.display = 'block';
        targetEl.innerHTML = '';
        targetEl.appendChild(el('div', 'git-diff-loading',
            msg || 'Loading diff…'));
        return targetEl;
    }

    function showError(targetEl, msg) {
        if (!targetEl) { return; }
        targetEl.style.display = 'block';
        targetEl.innerHTML = '';
        targetEl.appendChild(el('div', 'git-diff-error',
            'Diff failed: ' + (msg || 'unknown')));
        return targetEl;
    }

    function showMessage(targetEl, msg) {
        if (!targetEl) { return; }
        targetEl.style.display = 'block';
        targetEl.innerHTML = '';
        targetEl.appendChild(el('div', 'git-diff-message', msg || ''));
        return targetEl;
    }

    window.ComservGitDiff = {
        render: render,
        showLoading: showLoading,
        showError: showError,
        showMessage: showMessage
    };

    if (typeof console !== 'undefined' && console.log) {
        console.log('%c[git-diff-viewer] ready', 'color:#2e7d32');
    }
})();
