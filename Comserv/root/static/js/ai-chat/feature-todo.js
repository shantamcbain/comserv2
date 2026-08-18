// ai-chat/feature-todo.js — SHARED "Add Todo" chat feature.
//
// A chat button (any widget can add one) that creates a todo attached to the
// project/sub-project for the current page. Reusable: any widget calls
//   ComservChat.featureTodo.open({ pagePath, pageTitle, prefill, status });
//
// Project resolution (configurable, with safe fallback to project 1 = CSC):
//   - /project/details?record_id=N           -> N (explicit project page)
//   - /ai2/... or editor file paths (Comserv)  -> CODE_PROJECT_ID (default 1)
//   - /todo/...                                -> TODO_PROJECT_ID (default 1)
//   - /ENCY/...                                -> ENCY_PROJECT_ID (default 1)
//   - else                                     -> DEFAULT_PROJECT_ID (1)
// Override per deployment via ComservChat.featureTodo.setProjectMap({...}).
//
// Loaded before the widgets via js_load.tt. Attaches to window.ComservChat.featureTodo.
(function () {
    'use strict';
    window.ComservChat = window.ComservChat || {};

    var DEFAULT_PROJECT_ID = 1;
    var PROJECT_MAP = {
        code:  DEFAULT_PROJECT_ID,   // ai2 editor / Comserv code
        todo:  DEFAULT_PROJECT_ID,
        ency:  DEFAULT_PROJECT_ID,
        doc:   DEFAULT_PROJECT_ID
    };

    function setProjectMap(map) {
        if (map && typeof map === 'object') {
            Object.keys(map).forEach(function (k) { PROJECT_MAP[k] = map[k]; });
        }
    }

    // Best-effort project resolution from a page path.
    function resolveProjectId(pagePath) {
        if (!pagePath) return DEFAULT_PROJECT_ID;
        // Explicit project page: /project/details?record_id=123
        var m = pagePath.match(/[?&]record_id=(\d+)/);
        if (m && /\/project\//i.test(pagePath)) return parseInt(m[1], 10);
        if (/\/ai2\//i.test(pagePath) || /\/Comserv\//i.test(pagePath) || /editing_widget/i.test(pagePath)) return PROJECT_MAP.code;
        if (/\/ENCY\//i.test(pagePath)) return PROJECT_MAP.ency;
        if (/\/Documentation\//i.test(pagePath) || /\/doc\//i.test(pagePath)) return PROJECT_MAP.doc;
        if (/\/todo\//i.test(pagePath)) return PROJECT_MAP.todo;
        return DEFAULT_PROJECT_ID;
    }

    function isoDate(d) {
        return d.toISOString().slice(0, 10);
    }

    function open(opts) {
        opts = opts || {};
        var pagePath = opts.pagePath || (window.location.pathname + (window.location.search || ''));
        var pageTitle = opts.pageTitle || document.title || '';
        var prefill = (opts.prefill || '').toString().slice(0, 500).trim();
        var status = opts.status || function () {};   // (msg, isError) -> void
        var projectId = resolveProjectId(pagePath);

        // Build a tiny inline form appended to <body> (centered modal-ish).
        var overlay = document.createElement('div');
        overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:9999;' +
            'display:flex;align-items:center;justify-content:center;';
        overlay.setAttribute('title', 'Add a todo for this page’s project');

        var box = document.createElement('div');
        box.style.cssText = 'background:var(--card-bg,#fff);color:var(--text-color,#222);' +
            'min-width:320px;max-width:90vw;padding:16px;border-radius:8px;box-shadow:0 6px 24px rgba(0,0,0,.3);' +
            'font-family:system-ui,sans-serif;';
        box.innerHTML =
            '<h3 style="margin:0 0 8px">Add Todo</h3>' +
            '<div style="font-size:.8em;opacity:.7;margin-bottom:8px;">Project #' + projectId +
                (pageTitle ? ' · ' + escapeHtml(pageTitle) : '') + '</div>' +
            '<label style="display:block;font-size:.85em;margin-bottom:2px;">Subject</label>' +
            '<input id="ft-subject" style="width:100%;box-sizing:border-box;padding:6px;margin-bottom:8px;' +
                'border:1px solid var(--border-color,#ccc);border-radius:4px;" />' +
            '<label style="display:block;font-size:.85em;margin-bottom:2px;">Description (optional)</label>' +
            '<textarea id="ft-desc" rows="3" style="width:100%;box-sizing:border-box;padding:6px;margin-bottom:8px;' +
                'border:1px solid var(--border-color,#ccc);border-radius:4px;"></textarea>' +
            '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
            '<button id="ft-cancel" style="padding:6px 12px;border:1px solid var(--border-color,#ccc);' +
                'background:transparent;color:inherit;border-radius:4px;cursor:pointer;">Cancel</button>' +
            '<button id="ft-save" style="padding:6px 12px;border:none;background:var(--accent-color,#1a6bb5);' +
                'color:#fff;border-radius:4px;cursor:pointer;">Add Todo</button>' +
            '</div>';

        overlay.appendChild(box);
        document.body.appendChild(overlay);

        var subjectEl = box.querySelector('#ft-subject');
        var descEl = box.querySelector('#ft-desc');
        // Prefill subject from the page title or last AI text.
        subjectEl.value = prefill ? prefill.slice(0, 120) : (pageTitle ? pageTitle.slice(0, 120) : '');
        subjectEl.focus();

        function close() { if (overlay.parentNode) overlay.parentNode.removeChild(overlay); }

        box.querySelector('#ft-cancel').addEventListener('click', close);
        overlay.addEventListener('click', function (e) { if (e.target === overlay) close(); });

        box.querySelector('#ft-save').addEventListener('click', function () {
            var subject = subjectEl.value.trim();
            if (!subject) { subjectEl.focus(); status('Subject is required', true); return; }
            var today = new Date();
            var due = new Date(); due.setDate(due.getDate() + 7);
            var payload = {
                subject: subject,
                description: descEl.value.trim(),
                start_date: isoDate(today),
                due_date: isoDate(due),
                priority: 3,
                status: 1,
                project_id: projectId
            };
            status('Creating todo…');
            fetch('/api/todo/create', {
                method: 'POST',
                credentials: 'include',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            })
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (data && data.success) {
                    status('Todo #' + (data.todo_id || '?') + ' created on project #' + projectId);
                    close();
                } else {
                    status('Todo create failed: ' + ((data && (data.error || data.message)) || 'unknown'), true);
                }
            })
            .catch(function (err) {
                status('Todo create error: ' + err.message, true);
            });
        });
    }

    function escapeHtml(s) {
        return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    window.ComservChat.featureTodo = {
        open: open,
        setProjectMap: setProjectMap,
        resolveProjectId: resolveProjectId,
        _projectMap: PROJECT_MAP
    };
})();
