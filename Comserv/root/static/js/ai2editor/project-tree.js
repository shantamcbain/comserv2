// static/js/ai2editor/project-tree.js
// Renders the AI2 editor "Project" panel:
//   * a live "CHANGED FILES" section at the TOP (from /ai2/git_status), each
//     row clickable to open for editing and carrying a "Diff" button that
//     opens the diff (reuses the shared git-diff-viewer via file-diff.js).
//   * the full project file tree (from /ai2/file_tree) below, collapsible
//     folders + a filter box. Every file row opens the file for editing on
//     click; changed files get an M / U badge + a Diff button.
//
// Pure V2 module: no inline <script>, event delegation only. Loaded via
// js_load.tt for the /ai2/editing_widget_popup route (after core.js + the
// shared diff widget + file-diff.js so ComservGitDiff / ComservAI2FileDiff
// already exist).

(function () {
    'use strict';

    var NS = 'AI2ProjectTree';

    function normalize(p) {
        p = (p || '').replace(/\\/g, '/');
        p = p.replace(/^Comserv\//, '');
        return p;
    }

    // ---- diff loader: reuse file-diff.js's loader if present, else inline ----
    function loadDiff(li) {
        var path = li.getAttribute('data-path');
        if (!path) return;
        if (window.ComservAI2FileDiff && typeof window.ComservAI2FileDiff.loadDiff === 'function') {
            window.ComservAI2FileDiff.loadDiff(li);
            return;
        }
        // Minimal fallback (should not happen: file-diff.js always loads first).
        var pane = document.getElementById('git-diff-pane') ||
            (function () {
                var p = document.createElement('div');
                p.id = 'git-diff-pane';
                p.style.cssText = 'padding:8px;border-top:1px solid #555;overflow:auto;display:none;max-height:40vh;';
                var ea = document.querySelector('.editor-area');
                if (ea && ea.parentNode) ea.parentNode.appendChild(p);
                return p;
            })();
        if (pane && window.ComservGitDiff) window.ComservGitDiff.showLoading(pane, 'Loading diff for ' + path + ' …');
        fetch('/ai2/file_diff?path=' + encodeURIComponent(path))
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (!data.success) { if (window.ComservGitDiff) window.ComservGitDiff.showError(pane, data.error || 'unknown'); return; }
                if (window.ComservGitDiff) window.ComservGitDiff.render(pane, data.diff, { scope: 'file', title: 'Git Diff: ' + data.path + (data.is_new ? ' (new file)' : ' (vs HEAD)') });
            })
            .catch(function (err) { if (window.ComservGitDiff) window.ComservGitDiff.showError(pane, err.message); });
    }

    // ---- open a file in the editor ----
    function openFile(path) {
        if (window.AI2EditorCore && typeof window.AI2EditorCore.openFile === 'function') {
            window.AI2EditorCore.openFile(path).catch(function (err) {
                console.error('[' + NS + '] open failed:', err);
                var statusEl = document.getElementById('file-status');
                if (statusEl) { statusEl.textContent = 'Error opening: ' + path; statusEl.style.color = '#f66'; }
            });
        } else {
            console.error('[' + NS + '] AI2EditorCore.openFile unavailable');
        }
    }

    // ---- changed-files section ----
    function renderChangedFiles(host, changedSet) {
        if (!host) return;
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
                    var li = buildFileRow(normalize(item.p), item.kind, changedSet);
                    host.appendChild(li);
                });
            })
            .catch(function () { host.innerHTML = ''; });
    }

    function buildFileRow(path, kind, changedSet) {
        var li = document.createElement('li');
        li.className = 'file-item';
        li.setAttribute('data-path', path);
        li.style.cssText = 'list-style:none;padding:2px 12px;cursor:pointer;display:flex;align-items:center;gap:6px;';
        li.addEventListener('click', function () { openFile(path); markActive(li); });

        if (kind) {
            var badge = document.createElement('span');
            badge.textContent = kind;
            badge.title = kind === 'U' ? 'New / untracked' : 'Modified';
            badge.style.cssText = 'font-weight:bold;width:14px;' +
                (kind === 'U' ? 'color:#ff9;' : 'color:#f99;');
            li.appendChild(badge);
        }
        var name = document.createElement('span');
        name.textContent = path.split('/').pop();
        name.title = path;
        name.style.cssText = 'flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
        li.appendChild(name);

        // Diff button ONLY when git lists the file as changed (M / U).
        // Unchanged files get no Diff affordance so the UI never implies a
        // phantom diff.
        if (kind) {
            var btn = document.createElement('button');
            btn.className = 'git-diff-btn';
            btn.textContent = 'Diff';
            btn.style.cssText = 'background:#3c3f41;color:#ddd;border:1px solid #555;border-radius:3px;cursor:pointer;font-size:10px;padding:0 6px;';
            btn.addEventListener('click', function (e) {
                e.stopPropagation();
                loadDiff(li);
            });
            li.appendChild(btn);
        }
        return li;
    }

    function markActive(li) {
        document.querySelectorAll('#panel-projects .file-item.active').forEach(function (el) {
            el.classList.remove('active');
        });
        li.classList.add('active');
    }

    // ---- full tree ----
    function renderTree(host, tree, changedSet, filter) {
        host.innerHTML = '';
        var ul = document.createElement('ul');
        ul.className = 'file-tree';
        ul.style.cssText = 'list-style:none;padding:0;margin:0;';
        (tree || []).forEach(function (node) {
            renderNode(node, ul, changedSet, filter, 0);
        });
        if (!ul.children.length) {
            var empty = document.createElement('div');
            empty.style.cssText = 'color:#888;font-size:11px;padding:2px 12px;';
            empty.textContent = filter ? 'No files match "' + filter + '".' : 'No files.';
            host.appendChild(empty);
            return;
        }
        host.appendChild(ul);
    }

    function fileMatches(node, filter) {
        if (!filter) return true;
        var f = filter.toLowerCase();
        // Match on full path OR base name.
        return node.path.toLowerCase().indexOf(f) !== -1;
    }

    function renderNode(node, parentEl, changedSet, filter, depth) {
        if (node.type === 'dir') {
            var dirMatches = !filter || dirHasMatch(node, filter);
            if (filter && !dirMatches) return; // hide empty dirs under filter

            var li = document.createElement('li');
            li.className = 'dir-item';
            li.style.cssText = 'list-style:none;padding:2px 12px;cursor:pointer;display:flex;align-items:center;gap:6px;color:#9cdcfe;';
            li.setAttribute('data-depth', depth);
            var caret = document.createElement('span');
            caret.textContent = '▸ ';
            caret.style.cssText = 'width:12px;display:inline-block;';
            li.appendChild(caret);
            var dn = document.createElement('span');
            dn.textContent = node.name;
            dn.style.cssText = 'flex:1;';
            li.appendChild(dn);
            parentEl.appendChild(li);

            var childUl = document.createElement('ul');
            childUl.className = 'file-tree';
            childUl.style.cssText = 'list-style:none;padding:0 0 0 ' + (10) + 'px;margin:0;display:none;';
            parentEl.appendChild(childUl);

            (node.children || []).forEach(function (child) {
                renderNode(child, childUl, changedSet, filter, depth + 1);
            });

            li.addEventListener('click', function () {
                var hidden = childUl.style.display === 'none';
                childUl.style.display = hidden ? '' : 'none';
                caret.textContent = hidden ? '▾ ' : '▸ ';
            });
        } else {
            if (!fileMatches(node, filter)) return;
            var kind = null;
            var n = normalize(node.path);
            if (changedSet.untracked[n]) kind = 'U';
            else if (changedSet.modified[n]) kind = 'M';
            var liRow = buildFileRow(node.path, kind, changedSet);
            parentEl.appendChild(liRow);
        }
    }

    function dirHasMatch(node, filter) {
        // A dir matches if any descendant file matches.
        var stack = [node];
        while (stack.length) {
            var cur = stack.pop();
            if (cur.type === 'file') {
                if (fileMatches(cur, filter)) return true;
            } else if (cur.children) {
                for (var i = 0; i < cur.children.length; i++) stack.push(cur.children[i]);
            }
        }
        return false;
    }

    function makeChangedSet(data) {
        var modified = {}, untracked = {};
        (data.modified_files || []).forEach(function (p) { modified[normalize(p)] = 1; });
        (data.staged_files    || []).forEach(function (p) { modified[normalize(p)] = 1; });
        (data.untracked_files || []).forEach(function (p) { untracked[normalize(p)] = 1; });
        return { modified: modified, untracked: untracked };
    }

    // ---- orchestration ----
    function init() {
        var panel = document.getElementById('panel-projects');
        if (!panel) return;

        // Inject a filter input + tree container if not already present.
        var existingTree = document.getElementById('ai2-project-tree');
        var changedHost = document.getElementById('ai2-changed-files');
        var filterInput;

        if (!existingTree) {
            // Build a small filter box.
            var filterWrap = document.createElement('div');
            filterWrap.style.cssText = 'padding:6px 12px 2px;';
            filterInput = document.createElement('input');
            filterInput.type = 'text';
            filterInput.placeholder = 'Filter files…';
            filterInput.id = 'ai2-tree-filter';
            filterInput.style.cssText = 'width:100%;box-sizing:border-box;background:#1e1f22;color:#ddd;border:1px solid #555;border-radius:3px;padding:3px 6px;font-size:12px;';
            filterWrap.appendChild(filterInput);
            // Insert filter ABOVE the changed-files section (which is already in
            // the template) — find the changed-files host and prepend.
            if (changedHost && changedHost.parentNode) {
                changedHost.parentNode.insertBefore(filterWrap, changedHost);
            } else {
                panel.appendChild(filterWrap);
            }

            var tree = document.createElement('div');
            tree.id = 'ai2-project-tree';
            tree.style.cssText = 'margin-top:8px;max-height:none;overflow:auto;';
            // Put the tree after the changed-files section.
            if (changedHost && changedHost.parentNode) {
                changedHost.parentNode.insertBefore(tree, changedHost.nextSibling);
            } else {
                panel.appendChild(tree);
            }
            existingTree = tree;
            filterInput.addEventListener('input', function () { refresh(filterInput.value.trim()); });
        } else {
            filterInput = document.getElementById('ai2-tree-filter');
        }

        refresh(filterInput ? filterInput.value.trim() : '');

        function refresh(filter) {
            Promise.all([
                fetch('/ai2/git_status').then(function (r) { return r.json(); }).catch(function () { return {}; }),
                fetch('/ai2/file_tree').then(function (r) { return r.json(); }).catch(function () { return { success: 0 }; })
            ]).then(function (results) {
                var gs = results[0] || {};
                var ft = results[1] || {};
                var changedSet = makeChangedSet(gs);
                if (changedHost) renderChangedFiles(changedHost, changedSet);
                if (ft.success && ft.tree) {
                    renderTree(existingTree, ft.tree, changedSet, filter);
                } else if (existingTree) {
                    existingTree.innerHTML = '<div style="color:#888;font-size:11px;padding:2px 12px;">Could not load file tree.</div>';
                }
            });
        }
    }

    window.ComservAI2ProjectTree = { init: init };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    console.log('%c[AI2] project-tree ready', 'color:#0a0');
})();
