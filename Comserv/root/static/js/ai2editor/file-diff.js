// static/js/ai2editor/file-diff.js
// Adds git-diff-on-demand to the AI2 editor file tree.
//
// On load it fetches GET /ai2/git_status, badging every file-tree entry that is
// modified (M) or untracked/new (U) and injecting a "Diff" button. Clicking the
// button fetches GET /ai2/file_diff?path=<editor path> and renders the unified
// diff in a dedicated #git-diff-pane (kept separate from the AI-suggestion
// #ai-diff-pane so the two never clobber each other). Pure V2 module: no inline
// <script>, event delegation only.

(function () {
    'use strict';

    var NS = 'AI2FileDiff';

    // Build a Set of repo-relative-ish editor paths that are changed. The
    // server returns paths relative to the repo root (one level above the app);
    // the file tree uses app-relative paths (e.g. "root/...", "lib/..."). We
    // normalise by stripping a leading "Comserv/" so the two line up.
    function normalize(p) {
        p = (p || '').replace(/\\/g, '/');
        p = p.replace(/^Comserv\//, '');
        return p;
    }

    function changesToSets(data) {
        var modified = {}, untracked = {};
        (data.modified_files || []).forEach(function (p) { modified[normalize(p)] = 1; });
        (data.staged_files    || []).forEach(function (p) { modified[normalize(p)] = 1; });
        (data.untracked_files || []).forEach(function (p) { untracked[normalize(p)] = 1; });
        return { modified: modified, untracked: untracked };
    }

    function badgeFor(li, sets) {
        var path = li.getAttribute('data-path') || '';
        var n = normalize(path);
        if (sets.untracked[n]) return 'U';   // new / untracked
        if (sets.modified[n])  return 'M';   // modified / staged
        return null;
    }

    function ensureDiffPane() {
        var pane = document.getElementById('git-diff-pane');
        if (pane) return pane;
        pane = document.createElement('div');
        pane.id = 'git-diff-pane';
        pane.className = 'git-diff-pane';
        // Sits in the right rail beside the editor (flex:1 so it fills the
        // rail height below the AI suggestion pane). Not a bottom strip.
        pane.style.cssText = 'flex:1 1 auto; min-height:0; padding:8px;' +
            'font-size:0.82em;overflow:auto;display:none;';
        var rail = document.getElementById('editor-right-rail');
        if (rail) {
            rail.appendChild(pane);
        } else {
            var editorArea = document.querySelector('.editor-area');
            if (editorArea && editorArea.parentNode) editorArea.parentNode.appendChild(pane);
            else document.body.appendChild(pane);
        }
        return pane;
    }

    // ---- Diff view: Unified (via shared widget) OR Side-by-side (local) ----
    // We keep the shared widget as the canonical unified renderer, and add a
    // local side-by-side view (editor-only presentation of the same data) so
    // the user can flip between them without us forking the renderer.
    function ensureHeader(pane) {
        var head = pane.querySelector('.ai2-diff-head');
        if (head) return head;
        head = document.createElement('div');
        head.className = 'ai2-diff-head';
        head.style.cssText = 'display:flex;align-items:center;gap:8px;padding:4px 6px;' +
            'border-bottom:1px solid var(--border-color,#555);margin-bottom:4px;';
        var title = document.createElement('span');
        title.className = 'ai2-diff-title';
        title.style.cssText = 'flex:1;font-size:11px;color:#aaa;overflow:hidden;' +
            'text-overflow:ellipsis;white-space:nowrap;';
        var btnU = document.createElement('button');
        btnU.textContent = 'Unified';
        btnU.className = 'ai2-diff-view-btn';
        btnU.style.cssText = 'background:#3c3f41;color:#ddd;border:1px solid #555;' +
            'border-radius:3px;cursor:pointer;font-size:10px;padding:1px 6px;';
        var btnS = document.createElement('button');
        btnS.textContent = 'Split';
        btnS.className = 'ai2-diff-view-btn';
        btnS.style.cssText = 'background:#3c3f41;color:#ddd;border:1px solid #555;' +
            'border-radius:3px;cursor:pointer;font-size:10px;padding:1px 6px;';
        btnU.addEventListener('click', function () { setView(pane, 'unified'); });
        btnS.addEventListener('click', function () { setView(pane, 'split'); });
        head.appendChild(title);
        head.appendChild(btnU);
        head.appendChild(btnS);
        pane.insertBefore(head, pane.firstChild);
        return head;
    }

    function setView(pane, view) {
        pane._view = view;
        var btns = pane.querySelectorAll('.ai2-diff-view-btn');
        // Unified is first button, Split second.
        if (btns[0]) btns[0].style.background = (view === 'unified') ? '#0e639c' : '#3c3f41';
        if (btns[1]) btns[1].style.background = (view === 'split') ? '#0e639c' : '#3c3f41';
        if (pane._diffData) renderBody(pane, pane._diffData);
    }

    function renderDiff(pane, data) {
        ensureHeader(pane);
        pane._diffData = data;
        if (!pane._view) pane._view = 'unified';
        renderBody(pane, data);
        // Wire scroll-lock so the editor and diff stay aligned.
        attachScrollSync(pane);
    }

    function renderBody(pane, data) {
        var head = pane.querySelector('.ai2-diff-head');
        var titleEl = head ? head.querySelector('.ai2-diff-title') : null;
        if (titleEl) {
            titleEl.textContent = 'Git Diff: ' + data.path +
                (data.is_new ? ' (new file)' : ' (vs HEAD)');
        }
        // Remove any previously rendered body (everything after the header).
        var kids = Array.prototype.slice.call(pane.children);
        kids.forEach(function (k) {
            if (k !== head) pane.removeChild(k);
        });
        if (pane._view === 'split') {
            renderSplit(pane, data.diff);
        } else {
            // Delegate unified rendering to the canonical shared widget.
            var wrap = document.createElement('div');
            pane.appendChild(wrap);
            ComservGitDiff.render(wrap, data.diff, {
                scope: 'file',
                title: ''  // title shown in our own header instead
            });
        }
    }

    // ---- Local side-by-side renderer (no external dependency) ----
    // Parses a unified diff into paired old/new columns. Within each hunk we
    // pair consecutive '-' (old) and '+' (new) lines; context lines fill both
    // sides. Text is set via textContent (no innerHTML) so a hostile diff
    // cannot inject markup.
    function renderSplit(pane, diffText) {
        var container = document.createElement('div');
        container.className = 'ai2-diff-split';
        container.style.cssText = 'display:flex;gap:0;font-family:monospace;' +
            'font-size:11px;overflow:auto;';
        pane.appendChild(container);

        var lines = (diffText || '').split('\n');
        var left = document.createElement('div');
        var right = document.createElement('div');
        left.style.cssText = 'flex:1;min-width:0;border-right:1px solid #555;';
        right.style.cssText = 'flex:1;min-width:0;';
        container.appendChild(left);
        container.appendChild(right);

        function row(parent, text, kind) {
            var d = document.createElement('div');
            d.style.cssText = 'white-space:pre-wrap;padding:0 6px;' +
                (kind === 'old' ? 'background:#3a1f1f;color:#f99;' :
                 kind === 'new' ? 'background:#1f3a22;color:#9f9;' :
                 'color:#aaa;');
            d.textContent = text === '' ? ' ' : text;
            parent.appendChild(d);
        }

        var i = 0;
        while (i < lines.length) {
            var line = lines[i];
            if (line.indexOf('@@') === 0) {
                // hunk header — show on both sides
                row(left, line, 'hunk');
                row(right, line, 'hunk');
                i++;
                continue;
            }
            if (line.charAt(0) === '-') {
                // collect a run of '-' then a run of '+'
                var removed = [];
                while (i < lines.length && lines[i].charAt(0) === '-') {
                    removed.push(lines[i].slice(1)); i++;
                }
                var added = [];
                while (i < lines.length && lines[i].charAt(0) === '+') {
                    added.push(lines[i].slice(1)); i++;
                }
                var n = Math.max(removed.length, added.length);
                for (var k = 0; k < n; k++) {
                    row(left, k < removed.length ? removed[k] : '', 'old');
                    row(right, k < added.length ? added[k] : '', 'new');
                }
                continue;
            }
            if (line.charAt(0) === '+') {
                // a lone '+' with no preceding '-' (pure addition)
                while (i < lines.length && lines[i].charAt(0) === '+') {
                    row(left, '', 'old');
                    row(right, lines[i].slice(1), 'new');
                    i++;
                }
                continue;
            }
            if (line.charAt(0) === '\\') { i++; continue; } // "\ No newline" marker
            // context line — both sides
            row(left, line.slice(1), 'ctx');
            row(right, line.slice(1), 'ctx');
            i++;
        }
    }

    function loadDiff(li) {
        var path = li.getAttribute('data-path');
        if (!path) return;
        var pane = ensureDiffPane();
        ComservGitDiff.showLoading(pane, 'Loading diff for ' + path + ' …');

        fetch('/ai2/file_diff?path=' + encodeURIComponent(path))
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (!data.success) {
                    ComservGitDiff.showError(pane, data.error || 'unknown');
                    return;
                }
                renderDiff(pane, data);
            })
            .catch(function (err) {
                ComservGitDiff.showError(pane, err.message);
            });
    }

    function decorate(li, badge) {
        if (li.querySelector('.git-diff-btn')) return;
        if (badge) {
            var b = document.createElement('span');
            b.textContent = ' ' + badge + ' ';
            b.title = badge === 'U' ? 'New / untracked' : 'Modified';
            b.style.cssText = 'font-weight:bold;' +
                (badge === 'U' ? 'color:#ff9;' : 'color:#f99;');
            li.appendChild(b);
        }
        var btn = document.createElement('button');
        btn.className = 'git-diff-btn';
        btn.textContent = 'Diff';
        btn.style.cssText = 'margin-left:auto;background:#3c3f41;color:#ddd;border:1px solid #555;' +
            'border-radius:3px;cursor:pointer;font-size:10px;padding:0 6px;';
        btn.addEventListener('click', function (e) {
            e.stopPropagation();
            loadDiff(li);
        });
        li.appendChild(btn);
    }

    function init() {
        var tree = document.querySelector('#panel-projects .file-tree');
        if (tree) {
            // Badge/Diff any statically-listed file items that happen to match a
            // changed path (only meaningful if the template lists real files).
            fetch('/ai2/git_status')
                .then(function (r) { return r.json(); })
                .then(function (data) {
                    if (!data.success) return;
                    var sets = changesToSets(data);
                    tree.querySelectorAll('li.file-item').forEach(function (li) {
                        decorate(li, badgeFor(li, sets));
                    });
                })
                .catch(function () { /* git status optional; ignore */ });
        }
        // Always build a real "Changed Files" list from the live git status so
        // the Diff action is available on the actual modified/new files even when
        // the file tree is only a placeholder.
        buildChangedFilesList();

        // Title-bar "Diff" button: show the currently-open file's git diff.
        var titleBtn = document.getElementById('editor-diff-btn');
        if (titleBtn) titleBtn.addEventListener('click', function () {
            loadDiffForCurrentFile();
        });

        // When the editor was opened directly on a file (e.g. from the Git
        // Dashboard "Diff" button), auto-show that file's diff after the list
        // builds, so the user sees it without an extra click. We go straight to
        // the endpoint (routed through the shared widget) rather than depending
        // on the file appearing in the changed-list.
        var opened = window.AI2_FILE_TO_LOAD;
        if (opened) {
            setTimeout(function () {
                var pane = ensureDiffPane();
                if (!pane) return;
                ComservGitDiff.showLoading(pane, 'Loading diff for ' + opened + ' …');
                fetch('/ai2/file_diff?path=' + encodeURIComponent(opened))
                    .then(function (r) { return r.json(); })
                    .then(function (data) {
                        if (!data.success) {
                            ComservGitDiff.showError(pane, data.error || 'unknown');
                            return;
                        }
                        renderDiff(pane, data);
                    })
                    .catch(function (err) {
                        ComservGitDiff.showError(pane, err.message);
                    });
            }, 0);
        }
    }

    function buildChangedFilesList() {
        var host = document.getElementById('ai2-changed-files');
        if (!host) return;
        host.innerHTML = '<div style="color:#888;font-size:11px;padding:2px 0;">Checking git status…</div>';
        fetch('/ai2/git_status')
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (!data.success) { host.innerHTML = ''; return; }
                var all = [];
                (data.modified_files || []).forEach(function (p) { all.push({ p: p, kind: 'M' }); });
                (data.staged_files    || []).forEach(function (p) { all.push({ p: p, kind: 'M' }); });
                (data.untracked_files || []).forEach(function (p) { all.push({ p: p, kind: 'U' }); });
                if (!all.length) {
                    host.innerHTML = '<div style="color:#888;font-size:11px;padding:2px 0;">No uncommitted changes.</div>';
                    return;
                }
                host.innerHTML = '';
                var head = document.createElement('div');
                head.style.cssText = 'font-size:11px;color:#aaa;margin:4px 0 2px;';
                head.textContent = 'CHANGED FILES (' + all.length + ')';
                host.appendChild(head);
                all.forEach(function (item) {
                    var norm = normalize(item.p);
                    var li = document.createElement('li');
                    li.className = 'file-item';
                    li.setAttribute('data-path', norm);
                    li.style.cssText = 'padding:2px 12px;cursor:pointer;display:flex;align-items:center;gap:6px;';
                    var badge = document.createElement('span');
                    badge.textContent = item.kind;
                    badge.title = item.kind === 'U' ? 'New / untracked' : 'Modified';
                    badge.style.cssText = 'font-weight:bold;width:14px;' +
                        (item.kind === 'U' ? 'color:#ff9;' : 'color:#f99;');
                    var name = document.createElement('span');
                    name.textContent = norm.split('/').pop();
                    name.title = norm;
                    name.style.cssText = 'flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
                    var btn = document.createElement('button');
                    btn.className = 'git-diff-btn';
                    btn.textContent = 'Diff';
                    btn.style.cssText = 'background:#3c3f41;color:#ddd;border:1px solid #555;' +
                        'border-radius:3px;cursor:pointer;font-size:10px;padding:0 6px;';
                    btn.addEventListener('click', function (e) {
                        e.stopPropagation();
                        loadDiff(li);
                    });
                    li.appendChild(badge);
                    li.appendChild(name);
                    li.appendChild(btn);
                    host.appendChild(li);
                });
            })
            .catch(function () { host.innerHTML = ''; });
    }

    // Show the diff for the file currently open in the editor (title-bar Diff button).
    function currentEditorPath() {
        if (window.AI2_FILE_TO_LOAD) return window.AI2_FILE_TO_LOAD;
        try {
            var p = new URLSearchParams(window.location.search).get('file');
            if (p) return p;
        } catch (e) {}
        return '';
    }

    function loadDiffForCurrentFile() {
        var path = currentEditorPath();
        if (!path) {
            var pane = ensureDiffPane();
            if (pane) ComservGitDiff.showMessage(pane, 'Open a file first to diff it.');
            return;
        }
        var pane = ensureDiffPane();
        if (!pane) return;
        ComservGitDiff.showLoading(pane, 'Loading diff for ' + path + ' …');
        fetch('/ai2/file_diff?path=' + encodeURIComponent(path))
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (!data.success) { ComservGitDiff.showError(pane, data.error || 'unknown'); return; }
                renderDiff(pane, data);
            })
            .catch(function (err) { ComservGitDiff.showError(pane, err.message); });
    }

    // ---- Scroll lock: keep the editor and the diff pane scrolled in sync ----
    // so the same code stays visible in both. Proportional: scrollTop is
    // mapped by fraction of scrollable height. A guard flag avoids feedback
    // loops between the two scroll listeners.
    function syncScroll(editorEl, diffEl) {
        if (!editorEl || !diffEl) return;
        var lock = false;
        function link(src, dst) {
            src.addEventListener('scroll', function () {
                if (lock) return;
                lock = true;
                var sMax = src.scrollHeight - src.clientHeight;
                var dMax = dst.scrollHeight - dst.clientHeight;
                if (sMax > 0 && dMax > 0) {
                    dst.scrollTop = (src.scrollTop / sMax) * dMax;
                }
                // release on next frame
                requestAnimationFrame(function () { lock = false; });
            });
        }
        link(editorEl, diffEl);
        link(diffEl, editorEl);
    }

    // Attach scroll-sync once a diff is rendered. The editor scroller is the
    // Ace viewport (.ace_scrollbar / .ace_scroller); fall back to the pane.
    function attachScrollSync(pane) {
        var editorEl = document.querySelector('.ace_scroller') ||
                        document.getElementById('ace-editor');
        var diffEl = pane;
        // Defer so the diff content (and Ace) is laid out first.
        setTimeout(function () { syncScroll(editorEl, diffEl); }, 50);
    }

    window.ComservAI2FileDiff = {
        init: init,
        loadDiff: loadDiff,
        loadDiffForCurrentFile: loadDiffForCurrentFile
    };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    console.log('%c[AI2] file-diff ready', 'color:#0a0');
})();
