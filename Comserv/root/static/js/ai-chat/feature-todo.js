// ai-chat/feature-todo.js — SHARED todo feature for Chat-with-AI widget AND
// the AI2 editor chat. Both surfaces call the same /ai2/action brain
// (Model::AI2::TodoCreate): SiteName of the current site, match project /
// sub-project, ask to create a project if none match.
//
//   ComservChat.featureTodo.open({ pagePath, pageTitle, prefill, status, host });
//   ComservChat.featureTodo.handleAction(actionObj, { host, status });
//   ComservChat.featureTodo.extractActions(text);
//
// Loaded from js_load.tt BEFORE local-chat.js and ai2editor/chat.js.
(function () {
    'use strict';
    window.ComservChat = window.ComservChat || {};

    function pagePath() {
        return window.location.pathname + (window.location.search || '');
    }

    function escapeHtml(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    function extractActions(text) {
        var actions = [];
        var cleanText = String(text || '').replace(/\[ACTION:\s*(\{[\s\S]*?\})\]/g, function (match, jsonStr) {
            try {
                var obj = JSON.parse(jsonStr);
                if (obj && obj.action) actions.push(obj);
            } catch (e) {
                console.warn('AI action JSON parse error:', e, jsonStr);
            }
            return '';
        }).trim();
        return { cleanText: cleanText, actions: actions };
    }

    function postAction(action, params) {
        return fetch('/ai2/action', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: action, params: params || {} })
        }).then(function (r) { return r.json(); });
    }

    function hostEl(opts) {
        if (opts && opts.host) return opts.host;
        return document.getElementById('chat-messages') || document.body;
    }

    function card(host, title) {
        var existing = host.querySelector && host.querySelector('#ai-todo-card');
        if (existing && existing.parentNode) existing.parentNode.removeChild(existing);
        var wrap = document.createElement('div');
        wrap.id = 'ai-todo-card';
        wrap.className = 'msg-wrapper msg-wrapper-ai';
        var box = document.createElement('div');
        box.className = 'message system-message';
        box.setAttribute('role', 'dialog');
        box.style.maxWidth = '520px';
        var h = document.createElement('div');
        h.style.fontWeight = 'bold';
        h.style.marginBottom = '8px';
        h.textContent = title || 'Todo';
        box.appendChild(h);
        wrap.appendChild(box);
        host.appendChild(wrap);
        if (host.scrollTop !== undefined) host.scrollTop = host.scrollHeight;
        return box;
    }

    function btn(label, kind) {
        var b = document.createElement('button');
        b.type = 'button';
        b.className = kind === 'primary' ? 'btn btn-primary' : 'btn';
        b.textContent = label;
        b.style.marginRight = '6px';
        b.style.marginTop = '6px';
        return b;
    }

    function showResult(host, data, statusFn) {
        var box = card(host, data.success ? 'Todo created' : 'Todo');
        var p = document.createElement('p');
        p.className = 'doc-body';
        if (data.success) {
            var url = data.todo_url || ('/todo/details?record_id=' + data.todo_id);
            p.innerHTML = escapeHtml(data.message || 'Created') +
                ' <a class="doc-link" href="' + escapeHtml(url) + '" target="_blank" rel="noopener">Open todo #' +
                escapeHtml(String(data.todo_id || '')) + '</a>';
            if (data.project_url) {
                p.innerHTML += ' · <a class="doc-link" href="' + escapeHtml(data.project_url) +
                    '" target="_blank" rel="noopener">' + escapeHtml(data.project_name || ('project #' + data.project_id)) + '</a>';
            }
            if (data.sitename) {
                p.innerHTML += ' <span class="doc-muted">(' + escapeHtml(data.sitename) + ')</span>';
            }
            if (data.similar && data.similar.length) {
                p.innerHTML += '<br>Similar open: ' + data.similar.map(function (t) {
                    return '<a class="doc-link" href="/todo/details?record_id=' + t.record_id +
                        '" target="_blank">#' + t.record_id + '</a>';
                }).join(', ');
            }
        } else {
            p.textContent = data.error || data.message || 'Could not create todo';
        }
        box.appendChild(p);
        if (typeof statusFn === 'function') statusFn(data.message || data.error || '', !data.success);
    }

    function askPick(host, data, draft, statusFn) {
        var box = card(host, 'Which project?');
        var p = document.createElement('p');
        p.textContent = data.message || ('Several projects on ' + (data.sitename || 'this site') + ' could fit.');
        box.appendChild(p);
        (data.candidates || []).forEach(function (cand) {
            var b = btn((cand.project_code ? cand.project_code + ' — ' : '') + (cand.name || ('#' + cand.id)), 'primary');
            b.addEventListener('click', function () {
                var params = Object.assign({}, draft || {}, { project_id: cand.id, page_path: pagePath() });
                createTodo(params, host, statusFn);
            });
            box.appendChild(b);
        });
        var other = btn('Create new project');
        other.addEventListener('click', function () {
            askNewProject(host, data, draft, statusFn);
        });
        box.appendChild(other);
        var cancel = btn('Cancel');
        cancel.addEventListener('click', function () {
            if (box.parentNode && box.parentNode.parentNode) box.parentNode.parentNode.removeChild(box.parentNode);
        });
        box.appendChild(cancel);
    }

    function askNewProject(host, data, draft, statusFn) {
        var box = card(host, 'Create a project on ' + (data.sitename || 'this site') + '?');
        var p = document.createElement('p');
        p.textContent = data.message || 'No matching project. Name the new project, then the todo will be added to it.';
        box.appendChild(p);
        var input = document.createElement('input');
        input.type = 'text';
        input.className = 'form-control';
        input.value = (draft && (draft.project_name || draft.subject)) || '';
        input.style.width = '100%';
        input.style.boxSizing = 'border-box';
        input.style.margin = '6px 0';
        box.appendChild(input);
        var yes = btn('Create project + todo', 'primary');
        yes.addEventListener('click', function () {
            var name = input.value.trim();
            if (!name) { input.focus(); return; }
            var params = Object.assign({}, draft || {}, {
                create_project: 1,
                new_project_name: name,
                project_name: name,
                page_path: pagePath()
            });
            createTodo(params, host, statusFn);
        });
        box.appendChild(yes);
        var no = btn('Cancel');
        no.addEventListener('click', function () {
            if (box.parentNode && box.parentNode.parentNode) box.parentNode.parentNode.removeChild(box.parentNode);
        });
        box.appendChild(no);
        input.focus();
    }

    function createTodo(params, host, statusFn) {
        params = params || {};
        params.page_path = params.page_path || pagePath();
        if (typeof statusFn === 'function') statusFn('Creating todo…');
        return postAction('create_todo', params).then(function (data) {
            if (!data) throw new Error('empty response');
            if (data.need_project) {
                askNewProject(host, data, data.draft || params, statusFn);
                return data;
            }
            if (data.need_pick) {
                askPick(host, data, data.draft || params, statusFn);
                return data;
            }
            showResult(host, data, statusFn);
            return data;
        }).catch(function (err) {
            showResult(host, { success: false, error: err.message }, statusFn);
        });
    }

    function handleServerResult(data, opts) {
        opts = opts || {};
        var host = hostEl(opts);
        var statusFn = opts.status;
        if (!data) return;
        if (data.need_project) {
            askNewProject(host, data, data.draft || {}, statusFn);
            return;
        }
        if (data.need_pick) {
            askPick(host, data, data.draft || {}, statusFn);
            return;
        }
        showResult(host, data, statusFn);
    }

    function handleAction(actionObj, opts) {
        opts = opts || {};
        var host = hostEl(opts);
        var statusFn = opts.status;
        if (!actionObj || !actionObj.action) return;
        if (actionObj.action !== 'create_todo' && actionObj.action !== 'create_project') return;
        var params = Object.assign({}, actionObj.params || {});
        params.page_path = params.page_path || opts.pagePath || pagePath();
        if (actionObj.action === 'create_project') {
            params.create_project = 1;
            params.new_project_name = params.name || params.new_project_name;
            params.subject = params.subject || ('Follow-up: ' + (params.name || 'new project'));
        }
        createTodo(params, host, statusFn);
    }

    function open(opts) {
        opts = opts || {};
        var host = hostEl(opts);
        var statusFn = opts.status;
        var overlay = document.createElement('div');
        overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:9999;' +
            'display:flex;align-items:center;justify-content:center;';
        var box = document.createElement('div');
        box.className = 'card';
        box.style.cssText = 'background:var(--card-bg,var(--background-color,#fff));color:var(--text-color,#222);' +
            'min-width:320px;max-width:90vw;padding:16px;border-radius:8px;';
        box.innerHTML =
            '<h3 style="margin:0 0 8px">Add Todo</h3>' +
            '<p class="doc-muted" id="ft-site" style="font-size:.85em;margin:0 0 8px">Matching project on this site…</p>' +
            '<label style="display:block;font-size:.85em">Subject</label>' +
            '<input id="ft-subject" class="form-control" style="width:100%;box-sizing:border-box;margin-bottom:8px" />' +
            '<label style="display:block;font-size:.85em">Description (optional)</label>' +
            '<textarea id="ft-desc" rows="3" class="form-control" style="width:100%;box-sizing:border-box;margin-bottom:8px"></textarea>' +
            '<label style="display:block;font-size:.85em">Project</label>' +
            '<select id="ft-project" class="form-control" style="width:100%;box-sizing:border-box;margin-bottom:8px"></select>' +
            '<div style="display:flex;gap:8px;justify-content:flex-end">' +
            '<button type="button" class="btn" id="ft-cancel">Cancel</button>' +
            '<button type="button" class="btn btn-primary" id="ft-save">Add Todo</button>' +
            '</div>';
        overlay.appendChild(box);
        document.body.appendChild(overlay);

        var subjectEl = box.querySelector('#ft-subject');
        var descEl = box.querySelector('#ft-desc');
        var sel = box.querySelector('#ft-project');
        var siteEl = box.querySelector('#ft-site');
        subjectEl.value = (opts.prefill || opts.pageTitle || '').toString().slice(0, 120);

        function close() { if (overlay.parentNode) overlay.parentNode.removeChild(overlay); }
        box.querySelector('#ft-cancel').addEventListener('click', close);
        overlay.addEventListener('click', function (e) { if (e.target === overlay) close(); });

        var resolved = { sitename: '', projects: [] };
        postAction('resolve_todo_project', {
            page_path: opts.pagePath || pagePath(),
            subject: subjectEl.value,
            project_name: subjectEl.value
        }).then(function (data) {
            resolved = data || resolved;
            var site = data && data.sitename ? data.sitename : '';
            siteEl.textContent = site ? ('Site: ' + site) : 'Current site';
            sel.innerHTML = '';
            var none = document.createElement('option');
            none.value = '';
            none.textContent = '— match automatically / create if needed —';
            sel.appendChild(none);
            var list = (data && (data.projects && data.projects.length ? data.projects : data.candidates)) || [];
            list.forEach(function (p) {
                var o = document.createElement('option');
                o.value = String(p.id);
                o.textContent = (p.project_code ? p.project_code + ' — ' : '') + (p.name || ('#' + p.id));
                if (data.project && data.project.id === p.id) o.selected = true;
                sel.appendChild(o);
            });
            var createOpt = document.createElement('option');
            createOpt.value = '__new__';
            createOpt.textContent = 'Create a new project on ' + (site || 'this site') + '…';
            sel.appendChild(createOpt);
        }).catch(function (err) {
            siteEl.textContent = 'Could not list projects: ' + err.message;
        });

        box.querySelector('#ft-save').addEventListener('click', function () {
            var subject = subjectEl.value.trim();
            if (!subject) { subjectEl.focus(); return; }
            var params = {
                subject: subject,
                description: descEl.value.trim(),
                page_path: opts.pagePath || pagePath()
            };
            if (sel.value === '__new__') {
                params.create_project = 1;
                params.new_project_name = subject;
            } else if (sel.value) {
                params.project_id = sel.value;
            } else {
                params.project_name = subject;
            }
            close();
            createTodo(params, host, statusFn);
        });
        subjectEl.focus();
    }

    window.ComservChat.featureTodo = {
        open: open,
        handleAction: handleAction,
        extractActions: extractActions,
        createTodo: createTodo,
        handleServerResult: handleServerResult
    };
})();
