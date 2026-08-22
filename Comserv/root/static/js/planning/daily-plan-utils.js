/**
 * planning/daily-plan-utils.js
 * Utility functions for /planning/daily page and /Documentation/DailyPlan
 * Extracted from inline <script> blocks in DailyPlan.tt — modular load via js_load.tt
 *
 * Functions: switchTab, dailyLogAction, saveLogEntry, saveLogNotes, toggleLogPanel,
 *   linkPlanToProject, resolveDep, saveProjectOrder, startWorkTodoCard, closeLogTodoCard,
 *   doneWithLogTodoCard, smartOpenBranch, showBranchStartModal, closeBranchModal,
 *   selectDeployOption, cancelDeployModal
 */
(function() {
    'use strict';

    /* ── Tab switching ────────────────────────────────────────────────────

       Two paths must keep the visible tab in sync with the URL hash:
       1. A click on a .tab-button  -> switchTab() pushes the hash AND shows it.
       2. Browser Back/Forward      -> the hash changes WITHOUT a click, so a
          popstate/hashchange listener must re-show the tab. Without it the
          hash reverts but no tab gets .active and the page goes blank
          ("go back and nothing shows").

       _activateTab(name) does the pure show/hide. switchTab() calls it then
       pushState()s. The popstate/hashchange listeners call it WITHOUT pushing
       (so navigating history never spawns duplicate entries). */

    function _activateTab(name) {
        var tabEl = document.getElementById(name);
        if (!tabEl) return false;
        var i;
        var tabcontent = document.getElementsByClassName('tab-content');
        for (i = 0; i < tabcontent.length; i++) {
            tabcontent[i].classList.remove('active');
        }
        var tabbuttons = document.getElementsByClassName('tab-button');
        for (i = 0; i < tabbuttons.length; i++) {
            tabbuttons[i].classList.remove('active');
        }
        tabEl.classList.add('active');
        // Highlight the matching button(s) by data-tab (robust to currentTarget
        // quirks when this is called from a non-click path).
        var btns = document.querySelectorAll('.tab-button[data-tab="' + name + '"]');
        for (i = 0; i < btns.length; i++) {
            btns[i].classList.add('active');
        }
        return true;
    }

    function switchTab(evt, tabName) {
        if (!_activateTab(tabName)) return;
        if (history.pushState) {
            history.pushState(null, null, '#' + tabName);
        } else {
            location.hash = '#' + tabName;
        }
        // Lazy-load tab content if not already fetched
        var tabEl = document.getElementById(tabName);
        if (tabEl && tabEl.hasAttribute('data-lazy') && !tabEl.classList.contains('lazy-loaded')) {
            lazyLoadTab(tabEl);
        }
    }

    function lazyLoadTab(tabEl, optDate) {
        var tab = tabEl.getAttribute('data-lazy');
        var date = optDate || tabEl.getAttribute('data-lazy-date');
        tabEl.classList.remove('lazy-loaded');
        if (optDate) {
            tabEl.setAttribute('data-lazy-date', optDate);
        }
        if (!tab || !date) return;
        // Show loading indicator during re-navigation
        tabEl.innerHTML = '<div class="tab-loading"><span class="spinner"></span> Loading <span class="tab-loading-name">' + tab + '</span>...</div>';
        fetch('/planning/daily/' + date + '?tab=' + tab)
            .then(function(r) {
                if (!r.ok) throw new Error('HTTP ' + r.status);
                return r.text();
            })
            .then(function(html) {
                // Script tags DO NOT execute when set via innerHTML.
                // Extract them, set the HTML, then re-inject for execution.
                var scriptContents = [];
                var externalScripts = [];
                html = html.replace(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi, function(match, attrs, content) {
                    var srcMatch = attrs.match(/src="([^"]+)"/);
                    if (srcMatch) {
                        externalScripts.push(srcMatch[1]);
                    } else if (content.trim()) {
                        scriptContents.push(content);
                    }
                    return '';
                });

                tabEl.innerHTML = html;
                tabEl.classList.add('lazy-loaded');

                // Re-inject inline scripts — executes immediately on DOM append
                scriptContents.forEach(function(code) {
                    try {
                        var s = document.createElement('script');
                        s.textContent = code;
                        document.body.appendChild(s);
                        document.body.removeChild(s);
                    } catch(e) {
                        console.warn('lazyLoadTab: script exec failed:', e);
                    }
                });

                // Load external scripts referenced in the fetched HTML
                externalScripts.forEach(function(src) {
                    var s = document.createElement('script');
                    s.src = src;
                    s.async = false;
                    document.body.appendChild(s);
                });

                // Initialize the daily-schedule calendar (gcal functions defined above)
                if (typeof _gcalInitDayView === 'function') {
                    _gcalInitDayView();
                }
                // Replace view-select onchange with lazy tab-switch
                var selects = tabEl.querySelectorAll('.gcal-view-select');
                for (var i = 0; i < selects.length; i++) {
                    (function(sel) {
                        sel.onchange = function() {
                            var val = sel.value;
                            var match = val.match(/#(.+)$/);
                            if (match && match[1]) {
                                switchTab(null, match[1]);
                            }
                        };
                    })(selects[i]);
                }
                // Patch site filter to re-fetch tab instead of full page reload
                var siteFilter = tabEl.querySelector('#gcal-site-filter');
                if (siteFilter) {
                    siteFilter.onchange = function() {
                        var filterSite = siteFilter.value;
                        fetch('/planning/set_filter', {
                            method: 'POST',
                            credentials: 'same-origin',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ site: filterSite, user: '' })
                        }).catch(function() {}).then(function() {
                            lazyLoadTab(tabEl);
                        });
                    };
                }
            })
            .catch(function(err) {
                tabEl.innerHTML = '<div class="error-banner"><h4>⚠️ Failed to load tab</h4><p>' + err.message + '</p></div>';
            });
    }

    function activateHashTarget(hash) {
        if (!hash) return;
        var target = document.getElementById(hash);
        if (!target) return;
        if (target.classList.contains('tab-content')) {
            switchTab(null, hash);
        } else {
            var parent = target.parentElement;
            while (parent && !parent.classList.contains('tab-content')) {
                parent = parent.parentElement;
            }
            if (parent) {
                switchTab(null, parent.id);
                setTimeout(function() {
                    target.scrollIntoView({ behavior: 'smooth', block: 'start' });
                }, 150);
            }
        }
    }

    function updateNavLinks() {
        var hash = window.location.hash;
        if (hash) {
            document.querySelectorAll('.prev-day-link, .next-day-link').forEach(function(link) {
                var url = new URL(link.href, window.location.origin);
                url.hash = hash;
                link.href = url.pathname + url.search + url.hash;
            });
        }
    }

    /* ── Daily log actions ──────────────────────────────────────────────── */

    function dailyLogAction(action) {
        var startBtn = document.getElementById('dl-start-btn');
        var endBtn   = document.getElementById('dl-end-btn');
        var feedback = document.getElementById('dl-feedback');
        if (startBtn) startBtn.disabled = true;
        if (endBtn)   endBtn.disabled   = true;
        // NOTE: the rebuilt DailyPlan.tt index does NOT carry the dl-feedback /
        // dl-start-btn / dl-end-btn ids (those lived on the old monolith). Guard
        // every use so a missing node can never throw before the fetch fires.
        if (feedback) {
            feedback.textContent = action === 'start' ? 'Starting…' : 'Closing…';
            feedback.style.color = '';
        }

        fetch('/planning/daily_log', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: 'action=' + encodeURIComponent(action)
        })
        .then(function(r) { return r.json(); })
        .then(function(d) {
            if (startBtn) startBtn.disabled = false;
            if (endBtn)   endBtn.disabled   = false;
            var msg = d.response || d.message || (d.success ? (action === 'start' ? 'Day started!' : 'Day closed!') : (d.error || 'Error'));
            var plainMsg = msg.replace(/<[^>]+>/g, '');
            if (d.success) {
                alert(plainMsg);
                if (feedback) {
                    feedback.innerHTML = msg;
                    feedback.style.color = '#2a7a2a';
                }
                window.location.reload();
            } else {
                alert(plainMsg);
                if (feedback) {
                    feedback.innerHTML = msg;
                    feedback.style.color = '#9b0000';
                }
            }
        })
        .catch(function(e) {
            if (startBtn) startBtn.disabled = false;
            if (endBtn)   endBtn.disabled   = false;
            alert('Request failed: ' + e);
            if (feedback) {
                feedback.textContent = 'Request failed';
                feedback.style.color = '#9b0000';
            }
        });
    }

    function toggleLogPanel() {
        var panel = document.getElementById('log-panel');
        if (!panel) return;
        panel.style.display = (panel.style.display === 'none' || panel.style.display === '') ? 'block' : 'none';
    }

    function saveLogEntry(entryId) {
        var title = (document.getElementById('log-title-edit') || {}).value || '';
        var desc  = (document.getElementById('log-desc-edit')  || {}).value || '';
        var statusEl  = document.getElementById('log-save-status');
        if (statusEl) statusEl.textContent = 'Saving…';

        fetch('/planning/update_log_entry', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: 'entry_id=' + encodeURIComponent(entryId)
                + '&title='       + encodeURIComponent(title)
                + '&description=' + encodeURIComponent(desc)
        })
        .then(function(r) { return r.json(); })
        .then(function(d) {
            if (statusEl) {
                statusEl.textContent = d.success ? '✅ Saved' : ('❌ ' + (d.error || 'Save failed'));
                statusEl.style.color = d.success ? '#2a7a2a' : '#9b0000';
            }
        })
        .catch(function() {
            if (statusEl) { statusEl.textContent = '❌ Request failed'; statusEl.style.color = '#9b0000'; }
        });
    }

    function saveLogNotes(entryId) {
        var notes    = (document.getElementById('morning-notes-inline') || {}).value || '';
        var statusEl = document.getElementById('morning-notes-status');
        if (statusEl) statusEl.textContent = 'Saving…';

        fetch('/planning/update_log_entry', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: 'entry_id='    + encodeURIComponent(entryId)
                + '&description=' + encodeURIComponent(notes)
                + '&notes_only=1'
        })
        .then(function(r) { return r.json(); })
        .then(function(d) {
            if (statusEl) {
                statusEl.textContent = d.success ? '✅ Saved' : ('❌ ' + (d.error || 'Save failed'));
                statusEl.style.color = d.success ? '#2a7a2a' : '#9b0000';
            }
        })
        .catch(function() {
            if (statusEl) { statusEl.textContent = '❌ Request failed'; statusEl.style.color = '#9b0000'; }
        });
    }

    /* ── Deploy popup (opens separate window for Admin/Docker deploy_form) ─ */

    function openDeployPopup(todoId, quickDeploy) {
        var url = '/admin/docker/deploy_form';
        var params = [];
        if (quickDeploy) params.push('quick_deploy=1');
        if (todoId) params.push('todo_record_id=' + encodeURIComponent(todoId));
        if (params.length > 0) url += '?' + params.join('&');
        var popup = window.open(
            url,
            'docker_deploy',
            'width=720,height=540,resizable=yes,scrollbars=yes,toolbar=no,menubar=no,location=no,status=no'
        );
        if (popup) {
            popup.focus();
            window.addEventListener('message', function onMsg(e) {
                if (e.data && e.data.type === 'deploy_done') {
                    window.removeEventListener('message', onMsg);
                    var msg = e.data.success
                        ? '✅ Deploy complete — check the log for details.'
                        : '⚠️ Deploy had errors — review the popup log before closing.';
                    alert(msg);
                    location.reload();
                }
            });
        } else {
            alert('⚠ Popup blocked — allow popups for this site and try again.');
        }
    }

    /* ── Project linking ────────────────────────────────────────────────── */

    function linkPlanToProject(btn, projectId) {
        var sel = document.getElementById('link-plan-' + projectId);
        var planId = sel ? sel.value : '';
        if (!planId) { alert('Please select a plan first.'); return; }
        btn.disabled = true;
        btn.textContent = '…';
        fetch('/admin/plan/link_project', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: 'plan_id=' + encodeURIComponent(planId) + '&project_id=' + encodeURIComponent(projectId)
        })
        .then(function(r) { return r.json(); })
        .then(function(d) {
            if (d.success) {
                btn.closest('div').innerHTML = '<em style="color:#28a745;">✅ Linked — <a href="">Reload page</a> to see changes</em>';
            } else {
                btn.disabled = false;
                btn.textContent = 'Link';
                alert('Error: ' + (d.error || 'Unknown error'));
            }
        })
        .catch(function(e) {
            btn.disabled = false;
            btn.textContent = 'Link';
            alert('Request failed: ' + e);
        });
    }

    function resolveDep(depId, btn) {
        if (!confirm('Mark this dependency as resolved?')) return;
        btn.disabled = true;
        btn.textContent = '…';
        fetch('/project/resolve_dependency', {
            method: 'POST',
            headers: {'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest'},
            body: JSON.stringify({id: depId})
        }).then(function(r){ return r.json(); }).then(function(d){
            if (d.ok) {
                var row = btn.closest('tr');
                if (row) row.style.opacity = '0.4';
                setTimeout(function(){ if (row) row.remove(); }, 900);
            } else {
                btn.disabled = false;
                btn.textContent = '✓ Resolved';
                alert('Error: ' + (d.error || 'unknown'));
            }
        }).catch(function(e){
            btn.disabled = false;
            btn.textContent = '✓ Resolved';
            alert('Error: ' + e);
        });
    }

    /* ── Project drag-and-drop reorder ──────────────────────────────────── */

    (function() {
        var list = document.getElementById('project-sortable-list');
        if (!list) return;
        var cards = list.querySelectorAll('.project-card');
        if (!cards.length) return;

        var bar = document.getElementById('project-reorder-bar');
        var dragged = null;

        cards.forEach(function(card) {
            card.addEventListener('dragstart', function(e) {
                dragged = card;
                setTimeout(function() { card.style.opacity = '0.4'; }, 0);
                e.dataTransfer.effectAllowed = 'move';
                if (bar) bar.style.display = 'flex';
            });
            card.addEventListener('dragend', function() {
                card.style.opacity = '1';
                dragged = null;
                list.querySelectorAll('.project-card').forEach(function(c) {
                    c.style.borderTop = '';
                });
            });
            card.addEventListener('dragover', function(e) {
                e.preventDefault();
                e.dataTransfer.dropEffect = 'move';
                if (dragged && dragged !== card) {
                    list.querySelectorAll('.project-card').forEach(function(c) { c.style.borderTop = ''; });
                    card.style.borderTop = '2px solid var(--primary-color)';
                }
            });
            card.addEventListener('drop', function(e) {
                e.preventDefault();
                if (dragged && dragged !== card) {
                    card.style.borderTop = '';
                    var allCards = Array.from(list.querySelectorAll('.project-card'));
                    var fromIdx = allCards.indexOf(dragged);
                    var toIdx   = allCards.indexOf(card);
                    if (fromIdx < toIdx) {
                        card.after(dragged);
                    } else {
                        card.before(dragged);
                    }
                }
            });
        });
    })();

    function saveProjectOrder() {
        var list = document.getElementById('project-sortable-list');
        if (!list) return;
        var ids = Array.from(list.querySelectorAll('.project-card')).map(function(c) {
            return parseInt(c.getAttribute('data-project-id'), 10);
        }).filter(Boolean);

        var btn = document.getElementById('save-order-btn');
        var msg = document.getElementById('save-order-msg');
        if (btn) { btn.disabled = true; btn.textContent = 'Saving…'; }
        if (msg) msg.style.display = 'none';

        fetch('/project/reorder', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ order: ids })
        })
        .then(function(r) { return r.json(); })
        .then(function(d) {
            if (btn) { btn.disabled = false; btn.textContent = 'Save Order'; }
            if (d.ok) {
                if (msg) { msg.style.display = 'inline'; }
                setTimeout(function() { if (msg) msg.style.display = 'none'; }, 3000);
            } else {
                alert('Save failed: ' + (d.error || 'Unknown error'));
            }
        })
        .catch(function(e) {
            if (btn) { btn.disabled = false; btn.textContent = 'Save Order'; }
            alert('Request failed: ' + e);
        });
    }

    /* ── Todo card operations ───────────────────────────────────────────── */

    function _todoCardSetActive(btn, recordId) {
        btn.textContent = '⏸ Active';
        btn.style.border = '';
        btn.style.background = '#ffc107';
        btn.style.color = '#000';
        btn.title = 'Session active — click to close session';
        btn.disabled = false;
        btn.setAttribute('data-record-id', recordId);
        btn.setAttribute('data-is-active', '1');
        var card = btn.closest('[id^="ap-row-"]') || btn.closest('[id^="pr-row-"]') || btn.closest('[data-todo-id]');
        if (card) {
            card.style.background = 'rgba(255, 193, 7, 0.08)';
            var doneBtn = card.querySelector('button[data-done-btn]');
            if (doneBtn) doneBtn.setAttribute('data-is-active', '1');
        }
    }

    function _todoCardSetStart(btn, recordId) {
        btn.textContent = '▶ Start';
        btn.style.border = '1px solid #0d6efd';
        btn.style.background = 'transparent';
        btn.style.color = '#0d6efd';
        btn.title = 'Start working — creates a log entry, marks todo active';
        btn.disabled = false;
        btn.setAttribute('data-record-id', recordId);
        btn.setAttribute('data-is-active', '0');
        var card = btn.closest('[id^="ap-row-"]') || btn.closest('[id^="pr-row-"]') || btn.closest('[data-todo-id]');
        if (card) {
            card.style.background = '';
            var doneBtn = card.querySelector('button[data-done-btn]');
            if (doneBtn) doneBtn.setAttribute('data-is-active', '0');
        }
    }

    // NOTE: no _ensureSession pre-call. Server-side close_log / done_with_log
    // (Comserv::Util::TodoLog) are self-sufficient: close is graceful when no
    // log is open, and done inserts a completed log if none was open. Calling
    // open_log first would now TOGGLE-stop an active session (open_log is a
    // start/stop toggle), which is not what Close/Done mean.

    function startWorkTodoCard(btn, recordId) {
        btn.disabled = true;
        btn.textContent = '…';
        fetch('/todo/open_log', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ record_id: recordId })
        }).then(function(r) { return r.json(); }).then(function(d) {
            if (d.ok) {
                _todoCardSetActive(btn, recordId);
            } else {
                btn.disabled = false;
                btn.textContent = '▶ Start';
                alert('Could not start: ' + (d.error || 'unknown error'));
            }
        }).catch(function(e) {
            btn.disabled = false;
            btn.textContent = '▶ Start';
            alert('Error: ' + e);
        });
    }

    function closeLogTodoCard(btn, recordId) {
        var notes = prompt('Close session — notes on progress (optional):');
        if (notes === null) return;
        notes = notes || '';
        btn.disabled = true;
        btn.textContent = '…';
        // Server-side close_log is self-sufficient and graceful (no open log
        // is a warn, not an error) — no pre-call needed.
        fetch('/todo/close_log', {
                method: 'POST',
                credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ record_id: recordId, notes: notes })
            }).then(function(r) { return r.json(); }).then(function(d) {
                if (d.ok) {
                    _todoCardSetStart(btn, recordId);
                } else {
                    btn.disabled = false;
                    btn.textContent = '⏸ Active';
                }
            }).catch(function() {
                btn.disabled = false;
                btn.textContent = '⏸ Active';
            });
    }

    function doneWithLogTodoCard(btn, recordId) {
        var isActive = btn.getAttribute('data-is-active') === '1';
        var notes = prompt('Mark todo DONE — resolution / notes (optional):');
        if (notes === null) return;
        notes = notes || '';
        var payload = { record_id: recordId, notes: notes };
        btn.disabled = true;
        btn.textContent = '…';
        // Server-side done_with_log is self-sufficient (closes the open log or
        // inserts a completed one) — no pre-call, no double popup.
        fetch('/todo/done_with_log', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        }).then(function(r) { return r.json(); }).then(function(d) {
            if (d.ok) {
                var card = btn.closest('[id^="ap-row-"]') || btn.closest('[id^="pr-row-"]') || btn.closest('[data-todo-id]');
                if (card) {
                    card.style.opacity = '0.4';
                    card.style.textDecoration = 'line-through';
                    card.querySelectorAll('button').forEach(function(b) { b.disabled = true; });
                }
                btn.textContent = '✓ Done';
                btn.disabled = true;
            } else {
                btn.disabled = false;
                btn.textContent = 'Done';
            }
        }).catch(function() {
            btn.disabled = false;
            btn.textContent = 'Done';
        });
    }

    /* ── Branch server operations ───────────────────────────────────────── */

    function smartOpenBranch(branch, port, targetUrl) {
        // Open synchronously from the user's click.  A delayed window.open is
        // treated as a popup by browsers and is blocked, which made an already
        // running branch appear not to open.
        var branchWindow = targetUrl ? window.open(targetUrl, '_blank') : null;
        fetch('/admin/branch_server_action', {
            method: 'POST',
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'action=open&branch=' + encodeURIComponent(branch) + '&port=' + port
        }).catch(function() {});
        // Keep the command-output terminal available without making it the
        // only new tab.  The branch page is the primary Open action.
        if (!branchWindow && targetUrl) window.location.href = targetUrl;
    }

    function showBranchStartModal(branch, port, targetUrl) {
        var modal = document.getElementById('branch-start-modal');
        var title = document.getElementById('branch-modal-title');
        var cmdEl = document.getElementById('branch-modal-cmd');
        var logEl = document.getElementById('branch-modal-log');

        title.textContent = 'Starting ' + branch + ' on port ' + port + '…';
        cmdEl.textContent = '';
        logEl.textContent = 'Waiting for output...\\n';
        modal.style.display = 'flex';

        var poll = setInterval(function() {
            fetch('/admin/branch_server_log?file=' + encodeURIComponent('/tmp/branch-' + branch + '.log'))
                .then(function(r) { return r.text(); })
                .then(function(text) {
                    logEl.textContent = text;
                    logEl.scrollTop = logEl.scrollHeight;
                })
                .catch(function() {});
            fetch('/admin/branch_server_action', {
                method: 'POST',
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: 'action=open&branch=' + encodeURIComponent(branch) + '&port=' + port
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.running) {
                    clearInterval(poll);
                    closeBranchModal();
                    window.open(targetUrl, '_blank');
                }
            });
        }, 2000);
    }

    function closeBranchModal() {
        var modal = document.getElementById('branch-start-modal');
        if (modal) modal.style.display = 'none';
    }

    /* ── Deploy modal (second system, older, in-template) ───────────────── */

    function selectDeployOption(choice, todoId) {
        var modal = window._deployModal;
        if (modal) modal.parentNode.removeChild(modal);

        var target = 'production1';
        if (choice === 2) target = 'production2';
        if (choice === 3) target = 'workstation';
        if (choice === 'local-test') target = 'local-test';

        var url = '/admin/docker/deploy_form?todo_record_id=' + (todoId || '') + '&target=' + encodeURIComponent(target);
        window.open(url, 'dockerDeploy', 'width=900,height=700,resizable=yes,scrollbars=yes');
    }

    function cancelDeployModal(element) {
        var modal = element.closest('div[style*="position:fixed"]');
        if (modal) modal.parentNode.removeChild(modal);
    }

    /* ── AI Focus-Tune (phase 5b): diff the code sort vs what each chosen model
           thinks, with EXPLICIT multi-model selection (no silent swap) ───────── */

    // Selected models: array of {name, host}. Defaults to the first available.
    // _aiTuneDefault: the catalog default "provider|model" seeded from
    // window.ComservConfig.aiFocusDefault (set by the daily page), falling back
    // to the value returned by /api/focus/models. No hardcoded localhost Ollama.
    var _aiTuneSelected = [];
    var _aiTuneDefault  = (window.ComservConfig && window.ComservConfig.aiFocusDefault)
                          ? window.ComservConfig.aiFocusDefault : '';

    function _aiTuneModelList() {
        var sel = document.getElementById('ai-tune-model-pop');
        return sel ? sel : null;
    }

    function _aiTuneUpdateCount() {
        var el = document.getElementById('ai-tune-count');
        if (el) el.textContent = '(' + (_aiTuneSelected.length || 1) + ')';
    }

    function _aiTuneRenderResult(model, host, data, container) {
        if (!data || data.success !== 1) {
            container.innerHTML = '<div class="AITuneMisSet"><strong>' + esc(model) + '</strong> ⚠ '
                + ((data && (data.error || data.detail)) ? (data.error + ' ' + (data.detail || '')) : 'AI ranking unavailable')
                + '</div>';
            container.style.display = 'block';
            return;
        }
        var html = '';
        html += '<div class="AITuneModelHead">🤖 <code>' + esc(data.model || model) + '</code>'
            + (host ? ' <small>@' + esc(host) + '</small>' : '') + '</div>';

        if (data.picks && data.picks.length) {
            html += '<h4>Top picks</h4>';
            data.picks.forEach(function(p) {
                if (p.type === 'plan_item') {
                    html += '<div class="AITunePlanItem"><strong>' + esc(p.step || '(plan step)') + '</strong> '
                        + '<small>(' + esc(p.title || '') + (p.path ? ' · ' + esc(p.path) : '') + ')</small>'
                        + (p.why ? '<div><small>' + esc(p.why) + '</small></div>' : '') + '</div>';
                } else {
                    html += '<div class="AITunePick"><a href="/todo/details?record_id=' + p.record_id + '" '
                        + 'target="_blank">#' + p.record_id + '</a> ' + esc(p.why || '') + '</div>';
                }
            });
        } else {
            html += '<p><small>No picks returned.</small></p>';
        }

        var comp = data.comparison || {};
        var coded = comp.coded_top20 || [];
        var sim   = comp.simulated_top20 || [];
        if (coded.length || sim.length) {
            html += '<h4>🔁 Difference vs the code sort (lower = more important)</h4>';
            html += '<table><thead><tr><th>#</th><th>Code sort</th><th>AI thinks</th><th>Move</th></tr></thead><tbody>';
            var maxRows = Math.max(coded.length, sim.length);
            var codedByPos = {};
            coded.forEach(function(r, i) { codedByPos[r.record_id] = i + 1; });
            for (var i = 0; i < maxRows; i++) {
                var c = coded[i], s = sim[i];
                var cTxt = c ? ('#' + c.record_id + ' ' + esc((c.subject || '').slice(0, 38))) : '—';
                var sTxt = s ? ('#' + s.record_id + ' ' + esc((s.subject || '').slice(0, 38))) : '—';
                var move = '';
                if (c && s) {
                    if (c.record_id === s.record_id) { move = '<span class="ai-same">same</span>'; }
                    else {
                        var aiPos = codedByPos[s.record_id];
                        if (aiPos) {
                            var delta = aiPos - (i + 1);
                            if (delta > 0) move = '<span class="ai-up">▲ +' + delta + '</span>';
                            else if (delta < 0) move = '<span class="ai-down">▼ ' + delta + '</span>';
                            else move = '<span class="ai-same">—</span>';
                        } else { move = '<span class="ai-up">▲ new</span>'; }
                    }
                }
                html += '<tr><td>' + (i + 1) + '</td><td>' + cTxt + '</td><td>' + sTxt + '</td><td>' + move + '</td></tr>';
            }
            html += '</tbody></table>';
            html += '<p><small>' + esc(comp.note || '') + '</small></p>';
        }

        if (data.weights && Object.keys(data.weights).length) {
            html += '<h4>⚖ Proposed scorer weights (retune, not replace)</h4>';
            html += '<div class="AITuneWeights">' + Object.keys(data.weights).map(function(k) {
                return k + '=' + data.weights[k];
            }).join('  ') + '</div>';
            if (data.weights_why) html += '<p><small>' + esc(data.weights_why) + '</small></p>';
        }

        if (data.mis_set_todos && data.mis_set_todos.length) {
            html += '<h4>🛠 Mis-set todos to clean up (' + data.mis_set_todos.length + ')</h4>';
            data.mis_set_todos.forEach(function(m) {
                html += '<div class="AITuneMisSet"><a href="/todo/details?record_id=' + m.record_id
                    + '" target="_blank">#' + m.record_id + '</a> — ' + esc(m.issue || '') + '</div>';
            });
        }

        container.innerHTML = html;
        container.style.display = 'block';
    }

    function _aiTuneCall(target, statusEl, resultEl, onDone) {
        statusEl.textContent = 'Thinking with ' + target.name + '…';
        fetch('/api/focus/top5', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            // Send explicit models array (name+host) so the exact model is honored.
            body: JSON.stringify({ models: [ { name: target.name, host: target.host || '' } ] }),
            cache: 'no-store'
        }).then(function(r) { return r.json(); }).then(function(d) {
            statusEl.textContent = '';
            if (onDone) onDone(target, d); else _aiTuneRenderResult(target.name, target.host, d, resultEl);
        }).catch(function(e) {
            statusEl.textContent = '';
            if (onDone) onDone(target, { success: 0, error: '' + e });
            else { resultEl.innerHTML = '<div class="AITuneMisSet">⚠ Request failed: ' + esc('' + e) + '</div>'; resultEl.style.display = 'block'; }
        });
    }

    // Render a batch of per-model results side by side inside resultEl.
    function _aiTuneRenderBatch(models, results, resultEl) {
        resultEl.innerHTML = '<h4>⚖ Comparison — ' + models.length + ' models side by side</h4>'
            + '<div class="AITuneCompareGrid"></div>';
        var grid = resultEl.querySelector('.AITuneCompareGrid');
        models.forEach(function(m, i) {
            var block = document.createElement('div');
            block.className = 'AITuneCompareModel';
            var holder = document.createElement('div');
            _aiTuneRenderResult(m.name, m.host, results[i] || {}, holder);
            block.appendChild(holder);
            grid.appendChild(block);
        });
        resultEl.style.display = 'block';
    }

    function _aiTuneTargets() {
        // Use explicit selection if any; else the catalog default seeded from
        // window.ComservConfig.aiFocusDefault (no hardcoded model anywhere).
        if (_aiTuneSelected.length) return _aiTuneSelected.slice();
        if (_aiTuneDefault) {
            var dp = _aiTuneDefault.split('|');
            return [ { name: dp[1] || dp[0], host: '' } ];
        }
        return [];
    }

    function aiTuneRun() {
        var statusEl = document.getElementById('ai-tune-status');
        var resultEl = document.getElementById('ai-tune-result');
        var targets = _aiTuneTargets();
        // Split by execution class: remote providers (openrouter/grok/supergrok)
        // are network-bound and run IN PARALLEL; Ollama models are CPU-bound on
        // the workstation (Ollama serializes at -np 1 anyway), so they still run
        // ONE AT A TIME. Both groups render into the same side-by-side batch.
        var isLocal = function(t) { return /^(ollama\b|.*localhost)/i.test((t.host || '') + ' ' + (t.name || '')) && !/openrouter|grok|supergrok/i.test(t.name || ''); };
        var remote = [], local = [];
        targets.forEach(function(t) { (isLocal(t) ? local : remote).push(t); });
        var all = remote.concat(local);
        var collected = new Array(all.length);
        var pending = all.length;
        if (!pending) return;
        resultEl.innerHTML = '';
        function launch(t, idx) {
            _aiTuneCall(t, statusEl, resultEl, function(target, d) {
                collected[idx] = { target: target, data: d };
                pending--;
                if (!pending) {
                    _aiTuneRenderBatch(all, collected.map(function(c) { return c ? c.data : {}; }), resultEl);
                }
            });
        }
        // Remote first, all at once; local models launched sequentially as each
        // previous one finishes (chained after remote launches).
        remote.forEach(function(t, i) { launch(t, i); });
        var li = remote.length;
        function nextLocal() {
            if (li >= all.length) return;
            var idx = li++;
            _aiTuneCall(all[idx], statusEl, resultEl, function(target, d) {
                collected[idx] = { target: target, data: d };
                pending--;
                if (!pending) {
                    _aiTuneRenderBatch(all, collected.map(function(c) { return c ? c.data : {}; }), resultEl);
                }
                nextLocal();
            });
        }
        nextLocal();
    }

    function aiTuneCompare() {
        aiTuneRun(); // comparison of 2+ selected models is the same side-by-side render
    }

    function aiTuneToggleModels() {
        var pop = document.getElementById('ai-tune-model-pop');
        if (!pop) return;
        if (pop.style.display === 'block') { pop.style.display = 'none'; return; }
        fetch('/api/focus/models', { credentials: 'same-origin', cache: 'no-store' })
            .then(function(r) { return r.json(); })
            .then(function(d) {
                var list = (d && d.models) || [];
                // Capture the catalog default from the server (no client hardcode).
                _aiTuneDefault = (d && d.default) ? d.default : (_aiTuneDefault || '');
                if (!list.length) {
                    var dv = _aiTuneDefault.split('|');
                    list = [ { name: dv[1] || dv[0], host: 'localhost' } ];
                }
                // Initialize selection from current _aiTuneSelected or the server default.
                if (!_aiTuneSelected.length) {
                    if (_aiTuneDefault) {
                        var pd = _aiTuneDefault.split('|');
                        _aiTuneSelected = [ { name: pd[1] || pd[0], host: '' } ];
                    } else if (list.length) {
                        _aiTuneSelected = [ { name: list[0].name, host: list[0].host || '' } ];
                    }
                }
                // Provider order: Ollama (local) first, then SuperGrok, xAI Grok,
                // everything else; within OpenRouter free models first, then
                // lowest per-token price ascending.
                var svcOrder = { ollama: 0, supergrok: 1, grok: 2 };
                function svcOf(m) {
                    return m.provider || String(m.name || '').split('|')[0] || 'external';
                }
                function costOf(m) {
                    return Math.max(Number(m.price_prompt) || 0, Number(m.price_completion) || 0);
                }
                list.sort(function(a, b) {
                    var sa = svcOf(a), sb = svcOf(b);
                    var ra = svcOrder[sa] != null ? svcOrder[sa] : 3;
                    var rb = svcOrder[sb] != null ? svcOrder[sb] : 3;
                    if (ra !== rb) return ra - rb;
                    var la = !!a.local, lb = !!b.local;
                    if (la !== lb) return la ? -1 : 1;
                    var ca = costOf(a), cb2 = costOf(b);
                    if (ca !== cb2) return ca - cb2;
                    return String(a.name).localeCompare(String(b.name));
                });
                var html = '<div class="AITuneModelPopInner">';
                list.forEach(function(m) {
                    var checked = _aiTuneSelected.some(function(s) { return s.name === m.name; }) ? 'checked' : '';
                    var label = esc(m.name) + (m.provider && m.provider !== 'ollama' ? ' <small>(' + esc(m.provider) + ')</small>' : '');
                    // Cost marker so the user sees what a choice costs (matches the chat dropdown).
                    var pp = Number(m.price_prompt) || 0, pc = Number(m.price_completion) || 0;
                    if (m.local) {
                        label += ' — local';
                    } else if (m.free || (m.provider === 'openrouter' && /(^|:)(free)$/i.test(m.name || ''))
                              || (!m.local && pp === 0 && pc === 0 && !m.price_tier)) {
                        // Free + zero-priced external entries (stealth/ox-alpha,
                        // openrouter/auto, ...) — cost nothing, say so.
                        label += ' — free';
                    } else if (pp > 0 || pc > 0 || m.price_tier) {
                        var fmt = function(n) { return (Math.round(n * 100) / 100).toFixed(2); };
                        var tier = m.price_tier || (pp === 0 && pc === 0 ? 'free' : 'paid');
                        label += ' — $' + fmt(pp) + '/$' + fmt(pc) + ' per 1M (' + tier + ')';
                    }
                    html += '<label class="AITuneModelOpt"><input type="checkbox" data-model="'
                        + esc(m.name) + '" data-host="' + esc(m.host || '') + '" ' + checked + '> '
                        + label + '</label>';
                });
                html += '<div class="AITuneModelPopFoot"><button class="ActionBarBtn ActionBarBtn--blue" data-action="ai-tune-models-done">Done</button></div>';
                html += '</div>';
                pop.innerHTML = html;
                pop.style.display = 'block';
                // Wire checkbox changes.
                Array.prototype.forEach.call(pop.querySelectorAll('input[type=checkbox]'), function(cb) {
                    cb.addEventListener('change', function() {
                        var n = cb.getAttribute('data-model'), h = cb.getAttribute('data-host') || '';
                        if (cb.checked) {
                            if (!_aiTuneSelected.some(function(s){ return s.name === n; })) _aiTuneSelected.push({ name: n, host: h });
                        } else {
                            _aiTuneSelected = _aiTuneSelected.filter(function(s){ return s.name !== n; });
                        }
                        if (!_aiTuneSelected.length) {
                            var dd = _aiTuneDefault.split('|');
                            _aiTuneSelected = [ { name: dd[1] || dd[0] || list[0].name, host: '' } ];
                        }
                        _aiTuneUpdateCount();
                    });
                });
            })
            .catch(function() {
                var dv = (_aiTuneDefault || '').split('|');
                var fb = dv[1] || dv[0];
                if (!fb) { pop.innerHTML = '<div class="AITuneModelPopInner">Model list unavailable</div>'; pop.style.display = 'block'; return; }
                pop.innerHTML = '<div class="AITuneModelPopInner"><label class="AITuneModelOpt"><input type="checkbox" data-model="'
                    + esc(fb) + '" data-host="localhost" checked> ' + esc(fb) + '</label></div>';
                pop.style.display = 'block';
            });
    }

    function aiTuneModelsDone() {
        var pop = document.getElementById('ai-tune-model-pop');
        if (pop) pop.style.display = 'none';
    }

    function esc(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    /* ── Floating Done button ─────────────────────────────────────────────
       On long todo lists the per-card Done button can sit below the fold.
       This tracks the LAST todo card the user interacted with (click or
       expand) and shows a fixed "✓ Done" button that fires the SAME
       delegated data-done-btn path — no scrolling to reach the card. */
    var _lastTodoCard = null;

    function ensureFloatDoneBtn() {
        if (document.getElementById('float-done-btn')) return;
        // Only build it on pages that actually render todo cards.
        if (!document.querySelector('.todo-card-list [data-todo-id]')) return;
        var b = document.createElement('button');
        b.id = 'float-done-btn';
        b.type = 'button';
        b.className = 'btn btn-sm btn-outline-success';
        b.textContent = '✓ Done';
        b.title = 'Mark the last todo you clicked as done';
        b.style.cssText = 'position:fixed;bottom:5.5rem;left:50%;transform:translateX(-50%);'
            + 'z-index:1050;display:none;box-shadow:0 2px 8px rgba(0,0,0,.25);';
        document.body.appendChild(b);
        b.addEventListener('click', function() {
            if (!_lastTodoCard || !document.contains(_lastTodoCard)) { hideFloatDoneBtn(); return; }
            var doneBtn = _lastTodoCard.querySelector('button[data-done-btn]');
            if (doneBtn && !doneBtn.disabled) {
                doneBtn.click();   // reuses the delegated doneWithLogTodoCard path
            } else {
                hideFloatDoneBtn();
            }
        });
    }

    function showFloatDoneBtn(card) {
        ensureFloatDoneBtn();
        _lastTodoCard = card;
        var b = document.getElementById('float-done-btn');
        if (!b) return;
        var subject = card.querySelector('.todo-card-subject, .todo-card-title, .card-title, h4, h3, strong');
        var label = '✓ Done';
        if (subject && subject.textContent.trim().length) {
            var t = subject.textContent.trim();
            label += ': ' + (t.length > 40 ? t.slice(0, 40) + '…' : t);
        }
        b.textContent = label;
        b.style.display = 'block';
    }

    function hideFloatDoneBtn() {
        _lastTodoCard = null;
        var b = document.getElementById('float-done-btn');
        if (b) b.style.display = 'none';
    }

    document.addEventListener('click', function(e) {
        // Track the last-touched todo card for the floating Done button.
        var touchedCard = e.target.closest('[data-todo-id]');
        if (touchedCard && !touchedCard.closest('#float-done-btn')) {
            var stillOpen = touchedCard.querySelector('button[data-done-btn]:not([disabled])');
            if (stillOpen) { showFloatDoneBtn(touchedCard); } else { hideFloatDoneBtn(); }
        }
    }, true);   // capture phase: runs even when other handlers stopPropagation

    /* ── Event delegation — replaces all onclick= in template ──────────── */

    document.addEventListener('click', function(e) {
        // Tab buttons: <button data-tab="today-work">
        var tabBtn = e.target.closest('[data-tab]');
        if (tabBtn) {
            e.preventDefault();
            switchTab(e, tabBtn.getAttribute('data-tab'));
            return;
        }
        // Date navigation inside lazy-loaded tab: prev/next arrows, Today button, week/month nav
        var navLink = e.target.tagName === 'A' ? e.target : e.target.closest('a');
        if (navLink) {
            var lazyTab = navLink.closest('[data-lazy]');
            if (lazyTab) {
                var href = navLink.getAttribute('href') || '';
                if (href.indexOf('/planning/daily/') === 0) {
                    e.preventDefault();
                    var dateMatch = href.match(/\/planning\/daily\/(\d{4}-\d{2}-\d{2})/);
                    var hashMatch = href.match(/#(.+)$/);
                    if (dateMatch) {
                        var hash = hashMatch && hashMatch[1] || '';
                        var lazyId = lazyTab.getAttribute('data-lazy');
                        if (hash && hash !== lazyId) {
                            // Switching to a different tab via navigation link with new date
                            switchTab(null, hash);
                            var targetTab = document.querySelector('[data-lazy="' + hash + '"]');
                            if (targetTab && dateMatch) {
                                lazyLoadTab(targetTab, dateMatch[1]);
                            }
                        } else {
                            // Same tab, new date
                            lazyLoadTab(lazyTab, dateMatch[1]);
                        }
                    }
                    return;
                }
            }
        }
        // Daily log actions: <button data-action="start-day"> or "end-day"
        var da = e.target.closest('[data-action]');
        if (da) {
            var action = da.getAttribute('data-action');
            if (action === 'start-day') { dailyLogAction('start'); return; }
            if (action === 'end-day')   { dailyLogAction('end');   return; }
            if (action === 'dismiss-log-panel') { toggleLogPanel(); document.getElementById('log-panel').style.display = 'none'; return; }
            if (action === 'toggle-log-panel')  { toggleLogPanel(); return; }
            if (action === 'close-deploy-center') { if (typeof openDeployControlCenter !== 'undefined') closeDeployControlCenter(); return; }
            if (action === 'start-deploy-center') { if (typeof startDeploymentAction !== 'undefined') startDeploymentAction(); return; }
            if (action === 'close-branch-modal')  { closeBranchModal(); return; }
            if (action === 'cancel-deploy-modal') { cancelDeployModal(da); return; }
            // Today work tab actions
            if (action === 'triage-stale')  { if (typeof window.triageStale === 'function') { window.triageStale(); return; } }
            if (action === 'reschedule')    { if (typeof window.rescheduleTodos === 'function') { window.rescheduleTodos(da); return; } }
            if (action === 'refresh-audit') { if (typeof window.refreshAudit === 'function') { window.refreshAudit(e); return; } }
            if (action === 'refresh-page')  { if (typeof window.refreshPage === 'function') { window.refreshPage(e); return; } }
            if (action === 'sort-queue')    { if (typeof window.sortTodos === 'function') { window.sortTodos('queue'); return; } }
            if (action === 'sort-priority') { if (typeof window.sortTodos === 'function') { window.sortTodos('priority'); return; } }
            if (action === 'sort-project')  { if (typeof window.sortTodos === 'function') { window.sortTodos('project'); return; } }
            if (action === 'sort-due')      { if (typeof window.sortTodos === 'function') { window.sortTodos('due'); return; } }
            if (action === 'clear-filters') { if (typeof window.clearAllFilters === 'function') { window.clearAllFilters(); return; } }
            // AI Focus-Tune (phase 5b): show code-vs-AI diff, pick the model(s).
            if (action === 'ai-tune')              { aiTuneRun();              return; }
            if (action === 'ai-tune-compare')     { aiTuneCompare();          return; }
            if (action === 'ai-tune-toggle-models'){ aiTuneToggleModels();     return; }
            if (action === 'ai-tune-models-done')  { aiTuneModelsDone();       return; }
        }
        // Todo card: Start/Active button <button data-start-btn="1" data-record-id="N">
        // Decide open-vs-close from the button's data-is-active attribute
        // (rendered from the todo's DB status), NOT the button label text —
        // text matching broke when the label was "⏸ Active" (no 'Start' in it).
        var startBtn = e.target.closest('[data-start-btn]');
        if (startBtn) {
            e.preventDefault();
            var recordId = startBtn.getAttribute('data-record-id');
            if (recordId) {
                var isActive = startBtn.getAttribute('data-is-active') === '1';
                if (isActive) {
                    closeLogTodoCard(startBtn, parseInt(recordId, 10));
                } else {
                    startWorkTodoCard(startBtn, parseInt(recordId, 10));
                }
            }
            return;
        }
        // Todo card: Done button <button data-done-btn="1" data-record-id="N">
        var doneBtn = e.target.closest('[data-done-btn]');
        if (doneBtn) {
            e.preventDefault();
            var doneRecordId = doneBtn.getAttribute('data-record-id');
            if (doneRecordId) {
                doneWithLogTodoCard(doneBtn, parseInt(doneRecordId, 10));
            }
            return;
        }
        // Todo card: Chat button <button data-chat-todo="N" data-chat-subject="S">
        var chatBtn = e.target.closest('[data-chat-todo]');
        if (chatBtn) {
            e.preventDefault();
            var chatId = chatBtn.getAttribute('data-chat-todo');
            var chatSubject = chatBtn.getAttribute('data-chat-subject') || '';
            if (typeof window.openAiChat === 'function') {
                window.openAiChat({
                    context: 'todo',
                    record_id: chatId,
                    subject: chatSubject,
                    prompt: 'Help me with this task: ' + chatSubject + '. What should I do next?'
                });
            } else {
                window.location.href = '/todo/details?record_id=' + chatId + '&chat=1';
            }
            return;
        }
        // Save log entry: <button data-save-log="ENTRY_ID">
        var sel = e.target.closest('[data-save-log]');
        if (sel) {
            saveLogEntry(parseInt(sel.getAttribute('data-save-log'), 10));
            return;
        }
        // Save log notes: <button data-save-notes="ENTRY_ID">
        var sn = e.target.closest('[data-save-notes]');
        if (sn) {
            saveLogNotes(parseInt(sn.getAttribute('data-save-notes'), 10));
            return;
        }
        // Deploy popup: <button data-deploy-popup>
        var dp = e.target.closest('[data-deploy-popup]');
        if (dp) {
            openDeployPopup(dp.getAttribute('data-todo-id'), dp.getAttribute('data-quick-deploy'));
            return;
        }
        // Link plan to project
        var lp = e.target.closest('[data-link-plan]');
        if (lp) {
            linkPlanToProject(lp, parseInt(lp.getAttribute('data-link-plan'), 10));
            return;
        }
        // Resolve dependency
        var rd = e.target.closest('[data-resolve-dep]');
        if (rd) {
            resolveDep(parseInt(rd.getAttribute('data-resolve-dep'), 10), rd);
            return;
        }
        // Save project order
        var so = e.target.closest('[data-save-order]');
        if (so) {
            saveProjectOrder();
            return;
        }
        // Select deploy option (older modal)
        var sdo = e.target.closest('[data-deploy-option]');
        if (sdo) {
            selectDeployOption(sdo.getAttribute('data-deploy-option'), sdo.getAttribute('data-todo-id'));
            return;
        }
        // Branch server
        // Planning markup uses data-open-branch/data-url; accept the older
        // data-smart-open/data-target-url contract too.
        var selectedOpen = e.target.closest('[data-open-selected]');
        if (selectedOpen) {
            e.preventDefault();
            var branchSelect = document.getElementById('bs-select');
            if (branchSelect && branchSelect.value) window.open(branchSelect.value, '_blank');
            return;
        }
        var sob = e.target.closest('[data-open-branch], [data-smart-open]');
        if (sob) {
            e.preventDefault();
            smartOpenBranch(
                sob.getAttribute('data-open-branch') || sob.getAttribute('data-branch'),
                sob.getAttribute('data-port'),
                sob.getAttribute('data-url') || sob.getAttribute('data-target-url')
            );
            return;
        }
        var sbm = e.target.closest('[data-branch-modal]');
        if (sbm) {
            e.preventDefault();
            showBranchStartModal(
                sbm.getAttribute('data-branch'),
                sbm.getAttribute('data-port'),
                sbm.getAttribute('data-target-url')
            );
            return;
        }
    });

    /* ── Change event delegation for filter checkboxes ──────────── */

    document.addEventListener('change', function(e) {
        var cb = e.target.closest('[data-filter]');
        if (cb && cb.tagName === 'INPUT' && cb.type === 'checkbox') {
            var filterAction = cb.getAttribute('data-filter');
            if (filterAction === 'apply') { applyAllFilters(); return; }
            if (filterAction === 'site-all') { onSiteAllChange(cb); return; }
            if (filterAction === 'parent-change') { onProjectParentChange(cb); return; }
            if (filterAction === 'apply-update') { applyAllFilters(); updateProjectSummary(); return; }
        }
    });

    /* ── Hash handling on load / hashchange ─────────────────────────────── */

    window.addEventListener('load', function() {
        // Hash-based tab activation
        var hash = window.location.hash.substring(1);
        if (hash) activateHashTarget(hash);
        updateNavLinks();
        // Legacy: log panel hash
        if (hash === 'log-panel-open') {
            var panel = document.getElementById('log-panel');
            if (panel) { panel.style.display = 'block'; panel.scrollIntoView({ behavior: 'smooth' }); }
            history.replaceState(null, '', window.location.pathname + window.location.search);
        }
        // Master Plan tab is server-rendered inline (not an iframe). Its doc
        // links would otherwise navigate the whole browser away from
        // /planning/daily and lose the tab bar. Open them in a new tab so the
        // daily index stays put. (The Calendar tab is an iframe and handles
        // its own breakout via the embed script in day.tt.)
        var mp = document.getElementById('master-plan');
        if (mp) {
            var mpLinks = mp.querySelectorAll('a[href]');
            for (var i = 0; i < mpLinks.length; i++) {
                var href = mpLinks[i].getAttribute('href') || '';
                // Leave in-page anchors and external doc routes alone; only
                // force real navigations to a new tab.
                if (href.indexOf('#') !== 0 && href.indexOf('javascript:') !== 0) {
                    mpLinks[i].setAttribute('target', '_blank');
                    mpLinks[i].setAttribute('rel', 'noopener');
                }
            }
        }
    });

    // Browser Back/Forward changes the URL hash WITHOUT a click. Re-sync the
    // visible tab to the hash so navigating history never leaves every tab
    // hidden (the "go back and nothing shows" bug). Called WITHOUT pushState
    // so we don't spawn a second history entry.
    function _syncTabFromHash() {
        var hash = window.location.hash.replace(/^#/, '');
        if (hash && document.getElementById(hash)) {
            _activateTab(hash);
        }
    }
    window.addEventListener('popstate', _syncTabFromHash);
    window.addEventListener('hashchange', _syncTabFromHash);

    /* ── Expose start/done handlers for inline onclick callers (e.g. todo_row.tt
       on the project-details page, which calls startWorkTodoCard via onclick).
       Without this, those inline handlers throw ReferenceError because the
       functions are scoped inside this IIFE. ── */
    window.startWorkTodoCard   = startWorkTodoCard;
    window.doneWithLogTodoCard = doneWithLogTodoCard;
    window.closeLogTodoCard    = closeLogTodoCard;
    window.aiTuneRun            = aiTuneRun;
    window.aiTuneCompare        = aiTuneCompare;
    window.aiTuneToggleModels   = aiTuneToggleModels;
    window.aiTuneModelsDone     = aiTuneModelsDone;

})();