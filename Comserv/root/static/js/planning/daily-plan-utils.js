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

    /* ── Tab switching ──────────────────────────────────────────────────── */

    function switchTab(evt, tabName) {
        var i, tabcontent, tabbuttons;
        tabcontent = document.getElementsByClassName('tab-content');
        for (i = 0; i < tabcontent.length; i++) {
            tabcontent[i].classList.remove('active');
        }
        tabbuttons = document.getElementsByClassName('tab-button');
        for (i = 0; i < tabbuttons.length; i++) {
            tabbuttons[i].classList.remove('active');
        }
        var tabEl = document.getElementById(tabName);
        if (!tabEl) return;
        tabEl.classList.add('active');
        if (evt && evt.currentTarget && evt.currentTarget.classList.contains('tab-button')) {
            evt.currentTarget.classList.add('active');
        }
        if (history.pushState) {
            history.pushState(null, null, '#' + tabName);
        } else {
            location.hash = '#' + tabName;
        }
        // Lazy-load tab content if not already fetched
        if (tabEl.hasAttribute('data-lazy') && !tabEl.classList.contains('lazy-loaded')) {
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
        feedback.textContent = action === 'start' ? 'Starting…' : 'Closing…';
        feedback.style.color = '';

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
                feedback.innerHTML = msg;
                feedback.style.color = '#2a7a2a';
                window.location.reload();
            } else {
                alert(plainMsg);
                feedback.innerHTML = msg;
                feedback.style.color = '#9b0000';
            }
        })
        .catch(function(e) {
            if (startBtn) startBtn.disabled = false;
            if (endBtn)   endBtn.disabled   = false;
            alert('Request failed: ' + e);
            feedback.textContent = 'Request failed';
            feedback.style.color = '#9b0000';
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
        btn.style.background = '#fd7e14';
        btn.style.color = '#fff';
        btn.style.border = '1px solid #fd7e14';
        btn.style.borderColor = '#fd7e14';
        btn.title = 'Session active — click to close';
        btn.disabled = false;
        btn.setAttribute('data-record-id', recordId);
        var card = btn.closest('[id^="ap-row-"]') || btn.closest('[id^="pr-row-"]');
        if (card) {
            card.style.background = 'color-mix(in srgb,#fd7e14 8%,var(--bg-color,#fff))';
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
        var card = btn.closest('[id^="ap-row-"]') || btn.closest('[id^="pr-row-"]');
        if (card) {
            card.style.background = '';
            var doneBtn = card.querySelector('button[data-done-btn]');
            if (doneBtn) doneBtn.setAttribute('data-is-active', '0');
        }
    }

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
                alert('Could not close log: ' + (d.error || 'unknown'));
            }
        }).catch(function(e) {
            btn.disabled = false;
            btn.textContent = '⏸ Active';
            alert('Error: ' + e);
        });
    }

    function doneWithLogTodoCard(btn, recordId) {
        var isActive = btn.getAttribute('data-is-active') === '1';
        var notes = prompt('Mark todo DONE — resolution / notes (optional):');
        if (notes === null) return;
        notes = notes || '';
        var payload = { record_id: recordId, notes: notes };
        if (!isActive) {
            var durStr = prompt('No active log session.\\nHow many minutes did this take? (leave blank for default)');
            if (durStr === null) return;
            var durMins = parseInt(durStr, 10);
            if (!isNaN(durMins) && durMins > 0) { payload.duration_mins = durMins; }
        }
        btn.disabled = true;
        btn.textContent = '…';
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
                alert('Could not mark done: ' + (d.error || 'unknown'));
            }
        }).catch(function(e) {
            btn.disabled = false;
            btn.textContent = 'Done';
            alert('Error: ' + e);
        });
    }

    /* ── Branch server operations ───────────────────────────────────────── */

    function smartOpenBranch(branch, port, targetUrl) {
        fetch('/admin/branch_server_action', {
            method: 'POST',
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'action=open&branch=' + encodeURIComponent(branch) + '&port=' + port
        }).catch(function() {});
        var cmd = encodeURIComponent('cd /home/shanta/.zenflow/worktrees/' + branch + '/Comserv && CATALYST_DEBUG=1 perl script/comserv_server.pl -p ' + port + ' -r');
        window.open('/admin/system-shell-terminal?cmd=' + cmd, '_blank');
        setTimeout(function() {
            window.open(targetUrl, '_blank');
        }, 8000);
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
            if (action === 'sort-priority') { if (typeof window.sortTodos === 'function') { window.sortTodos('priority'); return; } }
            if (action === 'sort-project')  { if (typeof window.sortTodos === 'function') { window.sortTodos('project'); return; } }
            if (action === 'sort-due')      { if (typeof window.sortTodos === 'function') { window.sortTodos('due'); return; } }
            if (action === 'clear-filters') { if (typeof window.clearAllFilters === 'function') { window.clearAllFilters(); return; } }
        }
        // Todo card: Start/Active button <button data-start-btn="1" data-record-id="N">
        var startBtn = e.target.closest('[data-start-btn]');
        if (startBtn) {
            e.preventDefault();
            var recordId = startBtn.getAttribute('data-record-id');
            if (recordId) {
                if (startBtn.textContent === '▶ Start' || startBtn.textContent.indexOf('Start') !== -1) {
                    startWorkTodoCard(startBtn, parseInt(recordId, 10));
                } else {
                    closeLogTodoCard(startBtn, parseInt(recordId, 10));
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
        var sob = e.target.closest('[data-smart-open]');
        if (sob) {
            e.preventDefault();
            smartOpenBranch(
                sob.getAttribute('data-branch'),
                sob.getAttribute('data-port'),
                sob.getAttribute('data-target-url')
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
    });

    window.addEventListener('hashchange', function() {
        var hash = window.location.hash.substring(1);
        activateHashTarget(hash);
        updateNavLinks();
    });

})();