/**
 * planning/daily-plan.js
 * JavaScript for /planning/daily page
 * Extracted from _today_work_tab.tt as part of JS migration
 */

(function() {
    'use strict';

    window.quickClose = function(recordId) {
        if (!confirm('Mark todo #' + recordId + ' as Done and create a log entry?')) return;
        fetch('/todo/quick_close', {
            method: 'POST',
            headers: {'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest'},
            body: JSON.stringify({record_id: recordId})
        }).then(function(r){ return r.json(); }).then(function(d){
            if (d.ok) {
                var row = document.getElementById('ap-row-' + recordId);
                if (row) { row.style.opacity = '0.4'; row.style.textDecoration = 'line-through'; }
                setTimeout(function(){
                    if (row) row.remove();
                    _updateFocusQueueCounts();
                    if (typeof d.cross_blocker_count === 'number') {
                        _updateCrossBlockerBanner(d.cross_blocker_count);
                    }
                    if (d.deps_resolved > 0) {
                        var note = document.getElementById('focus-success-note');
                        if (!note) {
                            note = document.createElement('div');
                            note.id = 'focus-success-note';
                            note.style.cssText = 'background:color-mix(in srgb,#28a745 12%,var(--bg-color));border:1px solid #28a745;border-radius:4px;padding:6px 10px;margin-bottom:8px;font-size:0.88em;color:#28a745;';
                            var list = document.getElementById('priorities-list');
                            if (list && list.parentNode) list.parentNode.insertBefore(note, list);
                        }
                        note.textContent = '✓ Unblocked ' + d.deps_resolved + ' project(s) — nice work!';
                        note.style.display = '';
                    }
                }, 1200);
            } else {
                alert('Could not close: ' + (d.error || 'unknown error'));
            }
        }).catch(function(e){ alert('Error: ' + e); });
    };

    window.rescheduleTodos = function(btn) {
        btn.disabled = true;
        btn.textContent = '⏳ Rescheduling…';
        fetch('/todo/reschedule', {
            method: 'POST',
            headers: {'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest'},
            body: JSON.stringify({})
        }).then(function(r){ return r.json(); }).then(function(d){
            if (d.ok) {
                var msg = 'Rescheduled ' + d.count + ' todo' + (d.count !== 1 ? 's' : '') + ' from ' + (d.today || 'today') + ' forward into the calendar.';
                if (d.error_count) msg += '\n' + d.error_count + ' update(s) failed.';
                if (d.errors && d.errors.length) msg += '\nFirst error: ' + d.errors[0].substr(0, 200);
                msg += '\n\nReloading page…';
                alert(msg);
                location.reload();
            } else {
                btn.disabled = false;
                btn.textContent = '♻ Reschedule';
                alert('Error: ' + (d.error || 'unknown'));
            }
        }).catch(function(e){
            btn.disabled = false;
            btn.textContent = '♻ Reschedule';
            alert('Error: ' + e);
        });
    };

    window.triageStale = function() {
        if (!confirm('Reduce priority of all todos inactive for 180+ days by 2 levels?')) return;
        fetch('/todo/triage_stale', {
            method: 'POST',
            headers: {'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest'},
            body: JSON.stringify({})
        }).then(function(r){ return r.json(); }).then(function(d){
            if (d.ok) { alert('Triaged ' + d.count + ' stale todos. Reloading…'); location.reload(); }
            else { alert('Error: ' + (d.error || 'unknown')); }
        }).catch(function(e){ alert('Error: ' + e); });
    };

    window.refreshAudit = function(evt) {
        evt.stopPropagation();
        var btn = document.getElementById('btn-refresh-audit');
        if (btn) { btn.disabled = true; btn.textContent = '⏳ Scanning…'; }
        fetch('/planning/refresh_audit', {
            method: 'POST',
            headers: {'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest'},
            body: JSON.stringify({})
        }).then(function(r){ return r.json(); }).then(function(d){
            if (btn) { btn.disabled = false; btn.textContent = '↻ Refresh'; }
            if (d.success) {
                var msg = d.todo_created ? d.todo_created + ' new error todo(s) created.' : 'No new errors found.';
                alert('Audit scan complete. ' + msg);
                location.reload();
            } else {
                alert('Refresh failed: ' + (d.error || 'unknown error'));
            }
        }).catch(function(e){
            if (btn) { btn.disabled = false; btn.textContent = '↻ Refresh'; }
            alert('Error: ' + e);
        });
    };

    window.refreshPage = function(evt) {
        evt.stopPropagation();
        location.reload();
    };

    function _updateFocusQueueCounts() {
        var list = document.getElementById('priorities-list');
        var totalEl = document.getElementById('ap-total-count');
        var visibleEl = document.getElementById('ap-visible-count');
        if (!list || !totalEl || !visibleEl) return;
        var cards = list.querySelectorAll('div[id^="ap-row-"]');
        var visible = 0;
        cards.forEach(function(card) {
            if (card.style.display !== 'none') visible++;
        });
        visibleEl.textContent = visible;
        var total = parseInt(totalEl.textContent, 10);
        if (!isNaN(total) && total > 0) {
            totalEl.textContent = Math.max(0, total - 1);
        }
    }

    function _updateCrossBlockerBanner(count) {
        var banner = document.getElementById('cross-blocker-banner');
        if (!banner) return;
        if (!count) {
            banner.style.display = 'none';
            return;
        }
        banner.style.display = '';
        var label = banner.querySelector('span:nth-child(2)');
        if (label) {
            label.textContent = count + ' Cross-Project Blocker' + (count !== 1 ? 's' : '')
                + ' — Resolve first to unblock other projects';
        }
    }

    function applyAllFilters() {
        var allRoleCbs    = document.querySelectorAll('.role-cb');
        var checkedRoles  = new Set(Array.from(document.querySelectorAll('.role-cb:checked')).map(function(cb){ return cb.value; }));
        var allRoleVals   = new Set(Array.from(allRoleCbs).map(function(cb){ return cb.value; }));
        var allSiteCbs    = document.querySelectorAll('.site-cb');
        var checkedSites  = new Set(Array.from(document.querySelectorAll('.site-cb:checked')).map(function(cb){ return cb.value; }));
        var siteFiltered  = allSiteCbs.length > 0 && checkedSites.size < allSiteCbs.length;
        var allProjCbs    = document.querySelectorAll('.project-cb');
        var checkedProjs  = new Set(Array.from(document.querySelectorAll('.project-cb:checked')).map(function(cb){ return String(cb.value); }));
        var projFiltered  = allProjCbs.length > 0 && checkedProjs.size < allProjCbs.length;

        var cards = document.querySelectorAll('#priorities-list > div[id^="ap-row-"]');
        var visible = 0;
        cards.forEach(function(card) {
            var cardRoles = (card.dataset.roleCats || 'general').split(',');
            var showRole = cardRoles.some(function(cr) {
                if (cr === 'general') return true;
                if (!allRoleVals.has(cr)) return true;
                return checkedRoles.has(cr);
            });
            var showSite    = !siteFiltered || checkedSites.has(card.dataset.site || '');
            var showProject = !projFiltered  || checkedProjs.has(String(card.dataset.projectId || ''));
            var show = showRole && showSite && showProject;
            card.style.display = show ? '' : 'none';
            if (show) visible++;
        });
        var countEl = document.getElementById('ap-visible-count');
        if (countEl) countEl.textContent = visible;
        _updateDropdownSummaries();

        var checkedSiteVals = Array.from(document.querySelectorAll('.site-cb:checked'))
                                   .map(function(cb){ return cb.value; })
                                   .filter(function(v){ return v !== ''; });
        var sessionSite = (checkedSiteVals.length === 1) ? checkedSiteVals[0] : '';
        fetch('/planning/set_filter', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ site: sessionSite })
        }).catch(function(){});
    }

    function onProjectParentChange(cb) {
        var parentId = cb.value;
        var checked  = cb.checked;
        document.querySelectorAll('.project-cb[data-parent-id="' + parentId + '"]').forEach(function(child) {
            child.checked = checked;
        });
        applyAllFilters();
        updateProjectSummary();
    }

    function updateProjectSummary() {
        var sumEl = document.getElementById('project-summary');
        if (!sumEl) return;
        var all     = document.querySelectorAll('.project-cb');
        var checked = document.querySelectorAll('.project-cb:checked');
        if (all.length === checked.length) {
            sumEl.textContent = 'Focus: All \u25be';
        } else {
            var names = Array.from(document.querySelectorAll('.project-cb:checked')).map(function(cb) {
                return cb.closest('label').textContent.replace(/[\u2192\u21b3]/g,'').trim().replace(/\s*\(.*\)\s*$/,'').trim();
            });
            var label = names.length <= 2 ? names.join(', ') : names.length + ' projects';
            sumEl.textContent = 'Focus: ' + label + ' \u25be';
        }
    }

    function _updateDropdownSummaries() {
        var roleSummary = document.getElementById('role-summary');
        if (roleSummary) {
            var all = document.querySelectorAll('.role-cb');
            var checked = document.querySelectorAll('.role-cb:checked');
            roleSummary.textContent = (all.length === checked.length)
                ? 'Role: All \u25be'
                : 'Role: ' + Array.from(checked).map(function(cb){ return cb.value; }).join(', ') + ' \u25be';
        }
        var siteSummary = document.getElementById('site-summary');
        if (siteSummary) {
            var allS = document.querySelectorAll('.site-cb');
            var checkedS = document.querySelectorAll('.site-cb:checked');
            siteSummary.textContent = (allS.length === checkedS.length)
                ? 'Site: All \u25be'
                : 'Site: ' + Array.from(checkedS).map(function(cb){ return cb.value; }).join(', ') + ' \u25be';
        }
        updateProjectSummary();
    }

    window.clearAllFilters = function() {
        document.querySelectorAll('.role-cb,.site-cb,.project-cb').forEach(function(cb){ cb.checked = true; });
        applyAllFilters();
    };

    function initFilters() {
        applyAllFilters();
        document.addEventListener('click', function(e) {
            if (!e.target.closest('.ap-dropdown')) {
                document.querySelectorAll('.ap-dropdown[open]').forEach(function(d){ d.removeAttribute('open'); });
            }
        });
    }

    window.sortTodos = function(by) {
        var list = document.getElementById('priorities-list');
        if (!list) return;
        var cards = Array.from(list.querySelectorAll('[data-priority]'));
        cards.sort(function(a, b) {
            if (by === 'priority') {
                var pa = parseInt(a.dataset.priority || 99);
                var pb = parseInt(b.dataset.priority || 99);
                if (pa !== pb) return pa - pb;
                return parseInt(a.dataset.score || 9999) - parseInt(b.dataset.score || 9999);
            } else if (by === 'project') {
                var na = (a.dataset.project || '').toLowerCase();
                var nb = (b.dataset.project || '').toLowerCase();
                return na < nb ? -1 : na > nb ? 1 : 0;
            } else if (by === 'due') {
                var da = a.dataset.due || '9999-12-31';
                var db = b.dataset.due || '9999-12-31';
                return da < db ? -1 : da > db ? 1 : 0;
            }
            return 0;
        });
        cards.forEach(function(card, i) {
            var badge = card.querySelector('.rank-badge');
            if (badge) badge.textContent = i + 1;
            list.appendChild(card);
        });
        ['priority', 'project', 'due'].forEach(function(s) {
            var btn = document.getElementById('sort-' + s);
            if (!btn) return;
            var active = (s === by);
            btn.style.background     = active ? 'var(--primary-color)' : 'transparent';
            btn.style.color          = active ? '#fff' : 'var(--text-color)';
            btn.style.borderColor    = active ? 'var(--primary-color)' : 'var(--border-color)';
        });
    };

    // Expose filter functions if needed elsewhere
    window.applyAllFilters = applyAllFilters;
    window.onProjectParentChange = onProjectParentChange;
    window.updateProjectSummary = updateProjectSummary;

    document.addEventListener('DOMContentLoaded', initFilters);

    // === Daily Log Start/End buttons ===
    window.dailyLogAction = function(action) {
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
    };

    window.toggleLogPanel = function() {
        var panel = document.getElementById('log-panel');
        if (!panel) return;
        panel.style.display = (panel.style.display === 'none' || panel.style.display === '') ? 'block' : 'none';
    };

    // === Deploy button handler (centralized, no inline JS) ===
    function attachDeployHandler() {
        var btn = document.getElementById('dl-deploy-btn');
        if (!btn) return;
        btn.addEventListener('click', function(e) {
            e.preventDefault();
            window.open('/admin/docker/deploy_form', 'docker-deploy', 'width=800,height=700,scrollbars=yes,resizable=yes');
        });
        document.addEventListener('keydown', function(ev) {
            if (!window._deployModal) return;
            var key = ev.key.toUpperCase();
            var map = {'1':'production1','2':'production2','3':'local-5000','4':'local-4000','B':'local-test'};
            if (map[key]) {
                ev.preventDefault();
                triggerDeploy(map[key]);
                if (window._deployModal && window._deployModal.parentNode) window._deployModal.parentNode.removeChild(window._deployModal);
                window._deployModal = null;
            }
            if (key === 'ESCAPE' || key === 'ESC') {
                if (window._deployModal && window._deployModal.parentNode) window._deployModal.parentNode.removeChild(window._deployModal);
                window._deployModal = null;
            }
        });
    }

    function openDeployModal() {
        var modal = document.createElement('div');
        modal.className = 'deploy-modal-overlay';
        modal.innerHTML =
            '<div class="deploy-modal">' +
            '<h3 class="deploy-modal-title">Choose Deployment Target</h3>' +
            '<div class="deploy-option" data-target="production1"><strong>[1] FULL DEPLOY → production1</strong><br><span class="deploy-desc">Rebuilds, pushes to Docker Hub, restarts production1 container</span></div>' +
            '<div class="deploy-option" data-target="production2"><strong>[2] FULL DEPLOY → production2</strong><br><span class="deploy-desc">Rebuilds, pushes to Docker Hub, restarts production2 container</span></div>' +
            '<div class="deploy-option" data-target="local-5000"><strong>[3] Deploy to Local 5000 (production-like)</strong><br><span class="deploy-desc">Deploys the production image to the local port 5000 server</span></div>' +
            '<div class="deploy-option" data-target="local-4000"><strong>[4] Deploy to Local 4000 (staging)</strong><br><span class="deploy-desc">Deploys to the new local 4000 staging server for testing before local 5000</span></div>' +
            '<div class="deploy-option" data-target="local-test"><strong>[B] Build &amp; test locally only (no deploy)</strong><br><span class="deploy-desc">Builds and tests the image locally without pushing or deploying</span></div>' +
            '<div class="deploy-modal-actions"><button type="button" class="btn btn-secondary deploy-cancel">Cancel</button></div>' +
            '</div>';
        document.body.appendChild(modal);
        window._deployModal = modal;

        modal.querySelectorAll('.deploy-option').forEach(function(el){
            el.addEventListener('click', function(){
                var t = el.getAttribute('data-target');
                modal.parentNode.removeChild(modal);
                window._deployModal = null;
                triggerDeploy(t);
            });
        });
        modal.querySelector('.deploy-cancel').addEventListener('click', function(){
            modal.parentNode.removeChild(modal);
            window._deployModal = null;
        });
    }

    function triggerDeploy(target) {
        console.log('[Deploy] Selected target:', target);

        fetch('/planning/deploy', {
            method:'POST', credentials:'include',
            headers:{'Content-Type':'application/json','X-Requested-With':'XMLHttpRequest'},
            body: JSON.stringify({target: target})
        }).then(function(r){return r.json();}).then(function(d){
            if (d.success) { console.log('[Deploy] Success:', d.message||d); alert('Deploy initiated: '+(d.message||target)); }
            else { console.error('[Deploy] Error:', d.error||d); alert('Deploy failed: '+(d.error||'Unknown error')); }
        }).catch(function(e){ console.error('[Deploy] Network error:', e); alert('Deploy request failed: '+e); });
    }

    // Attach immediately (script uses defer so DOM is ready)
    attachDeployHandler();

    // Safety net: if button is added later (e.g. via partials), re-attach on click anywhere
    document.addEventListener('click', function(ev){
        if (ev.target && ev.target.id === 'dl-deploy-btn' && !ev.target._deployHooked) {
            ev.target._deployHooked = true;
            ev.preventDefault();
            window.open('/admin/docker/deploy_form', 'docker-deploy', 'width=800,height=700,scrollbars=yes,resizable=yes');
        }
    }, true);

})();