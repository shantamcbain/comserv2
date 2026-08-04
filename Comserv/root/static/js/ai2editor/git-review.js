// static/js/ai2editor/git-review.js
// Review & Merge panel for the AI2 editor: lists zenflow worktree branches,
// shows the diff vs main, runs the test gate, and (admin) merges to main / pushes
// to GitHub. Also wires the Hermes dashboard iframe from a ?hermes=URL param.
(function () {
    'use strict';

    function el(id) { return document.getElementById(id); }

    function setStatus(msg, isError) {
        var s = el('review-status');
        if (!s) return;
        s.textContent = msg || '';
        s.style.color = isError ? '#f66' : '#9f9';
    }

    function populateBranches() {
        var sel = el('review-branch');
        if (!sel) return;
        fetch('/admin/git/worktrees')
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (!data.success) { setStatus('Could not list worktrees: ' + (data.error || ''), true); return; }
                sel.innerHTML = '<option value="">— select worktree branch —</option>';
                (data.worktrees || []).forEach(function (wt) {
                    if (wt.is_main) return;
                    var o = document.createElement('option');
                    o.value = wt.branch;
                    o.textContent = wt.branch + '  (ahead ' + (wt.ahead || 0) + ' / behind ' + (wt.behind || 0) + ', port ' + (wt.port || '?') + ')';
                    sel.appendChild(o);
                });
            })
            .catch(function (err) { setStatus('worktrees error: ' + err.message, true); });
    }

    function loadDiff() {
        var sel = el('review-branch');
        var branch = sel ? sel.value : '';
        var out = el('review-diff');
        if (!branch) { setStatus('Select a worktree branch first.', true); return; }
        fetch('/admin/git/review/' + encodeURIComponent(branch))
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (!data.success) { setStatus(data.error || 'diff failed', true); if (out) out.textContent = ''; return; }
                if (out) out.textContent = data.diff || '(no changes vs main)';
                setStatus('Loaded diff for ' + branch);
            })
            .catch(function (err) { setStatus('diff error: ' + err.message, true); });
    }

    function runTestGate() {
        var sel = el('review-branch');
        var branch = sel ? sel.value : '';
        var out = el('review-testgate-out');
        if (!branch) { setStatus('Select a worktree branch first.', true); return; }
        if (out) out.textContent = 'Running test gate on ' + branch + ' ...';
        fetch('/admin/git/test_gate/' + encodeURIComponent(branch))
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (out) out.textContent = (data.success ? 'PASS\n' : 'FAIL\n')
                + (data.output || data.error || '');
            setStatus(data.success ? ('Test gate passed for ' + branch)
                                   : ('Test gate FAILED for ' + branch), !data.success);
        })
        .catch(function (err) { if (out) out.textContent = 'error: ' + err.message; });
    }

    function mergeToMain() {
        var sel = el('review-branch');
        var branch = sel ? sel.value : '';
        if (!branch) { setStatus('Select a worktree branch first.', true); return; }
        if (!confirm('Merge ' + branch + ' into main? Tests must be green. Continue?')) return;
        setStatus('Merging ' + branch + ' ...');
        fetch('/admin/git/merge_to_main', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: 'branch=' + encodeURIComponent(branch)
        })
        .then(function (r) { return r.json(); })
        .then(function (data) {
            if (data.success) {
                setStatus('Merged ' + branch + ' into main. Remember to Push GitHub.');
                populateBranches();
            } else if (data.conflict) {
                setStatus('CONFLICT: ' + (data.error || ''), true);
            } else {
                setStatus('Merge blocked: ' + (data.error || ''), true);
            }
        })
        .catch(function (err) { setStatus('merge error: ' + err.message, true); });
    }

    function pushGitHub() {
        if (!confirm('Push main to GitHub (origin)?')) return;
        setStatus('Pushing main to GitHub ...');
        fetch('/admin/git/push_main', { method: 'POST' })
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (data.success) setStatus('Pushed to GitHub.');
                else setStatus('Push failed: ' + (data.error || ''), true);
            })
            .catch(function (err) { setStatus('push error: ' + err.message, true); });
    }

    function wireHermes() {
        var params = new URLSearchParams(window.location.search);
        var url = params.get('hermes');
        if (!url) return;
        var frame = el('hermes-iframe');
        var ph = el('hermes-placeholder');
        if (frame) { frame.src = url; frame.style.display = 'block'; }
        if (ph) ph.style.display = 'none';
    }

    function wire() {
        var b;
        if ((b = el('review-load-btn'))) b.addEventListener('click', loadDiff);
        if ((b = el('review-testgate-btn'))) b.addEventListener('click', runTestGate);
        if ((b = el('review-merge-btn'))) b.addEventListener('click', mergeToMain);
        if ((b = el('review-push-btn'))) b.addEventListener('click', pushGitHub);
        // Header Merge button: open the Review panel and focus branch picker
        if ((b = el('merge-main-btn'))) b.addEventListener('click', function () {
            var icon = document.querySelector('.sidebar-icon[data-panel="review"]');
            if (icon) icon.click();
            populateBranches();
        });
        wireHermes();
        populateBranches();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', wire);
    } else {
        wire();
    }

    console.log('%c[AI2] git-review ready', 'color:#0a0');
})();
