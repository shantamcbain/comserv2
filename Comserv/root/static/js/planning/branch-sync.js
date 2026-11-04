/*
 * branch-sync.js — Branch Servers card (/planning/daily, /planning/daily-legacy,
 * /Documentation/DailyPlan): live "vs main" state with its own Refresh button.
 *
 * The card used to render only static branch/port info, so seeing whether a branch
 * had moved relative to main meant leaving the page and coming back. Now:
 *   - on load it fills every [data-branch-sync="<port>"] cell once, and
 *   - [data-branch-sync-refresh] re-reads /planning/branch_sync in place.
 * Read-only: no merge, no checkout, no write of any kind.
 */
(function () {
    'use strict';

    function ready(fn) {
        if (document.readyState !== 'loading') { fn(); }
        else { document.addEventListener('DOMContentLoaded', fn); }
    }

    ready(function () {
        var btn = document.querySelector('[data-branch-sync-refresh]');
        var cells = document.querySelectorAll('[data-branch-sync]');
        if (!cells.length) { return; }          // this page has no Branch Servers table
        var url = (btn && btn.getAttribute('data-branch-sync-url')) || '/planning/branch_sync';
        var note = document.querySelector('[data-branch-sync-note]');

        var MUTED = 'var(--text-muted-color,#777)';
        var WARN  = '#fd7e14';
        var BAD   = '#dc3545';
        var OK    = 'var(--success-color,#28a745)';

        function describe(r) {
            if (r.missing) { return { text: 'not checked out here', color: BAD }; }
            if (r.merge_in_progress) { return { text: 'merge in progress', color: BAD }; }
            var bits = [];
            var color = MUTED;
            if (r.behind > 0) { bits.push(r.behind + ' behind main'); color = WARN; }
            if (r.ahead > 0) { bits.push(r.ahead + ' ahead'); }
            if (!bits.length) { bits.push('in sync with main'); color = OK; }
            if (r.dirty > 0) { bits.push(r.dirty + ' uncommitted'); color = WARN; }
            return { text: bits.join(' · '), color: color };
        }

        function render(data) {
            var rows = (data && data.branches) || [];
            rows.forEach(function (r) {
                var targets = document.querySelectorAll('[data-branch-sync="' + r.port + '"]');
                var d = describe(r);
                Array.prototype.forEach.call(targets, function (td) {
                    td.textContent = d.text;
                    td.style.color = d.color;
                    td.title = (r.branch ? 'branch ' + r.branch : r.label || '') +
                               (r.behind || r.ahead ? ' — ' + (r.behind || 0) + ' behind / ' + (r.ahead || 0) + ' ahead of main' : '');
                });
            });
            if (note) {
                note.textContent = 'updated ' + new Date().toLocaleTimeString();
                note.style.color = MUTED;
            }
        }

        function refresh() {
            if (btn) { btn.disabled = true; }
            if (note) { note.textContent = 'refreshing…'; note.style.color = MUTED; }
            fetch(url, { credentials: 'same-origin', headers: { 'Accept': 'application/json' } })
                .then(function (res) {
                    // A login redirect or HTML error page is not JSON — say so instead
                    // of throwing "unexpected character at line 1".
                    var ct = res.headers.get('content-type') || '';
                    if (ct.indexOf('json') < 0) { throw new Error('not JSON (session expired?)'); }
                    return res.json();
                })
                .then(function (data) {
                    if (!data || data.success === 0) { throw new Error((data && data.error) || 'refresh failed'); }
                    render(data);
                })
                .catch(function (err) {
                    if (note) { note.textContent = 'refresh failed: ' + err.message; note.style.color = BAD; }
                })
                .then(function () { if (btn) { btn.disabled = false; } });
        }

        if (btn) {
            // On /Documentation/DailyPlan the card's header IS a <summary>: a plain
            // click there would toggle the whole card shut while refreshing it.
            btn.addEventListener('click', function (e) {
                e.preventDefault();
                e.stopPropagation();
                refresh();
            });
        }
        refresh();   // fill on load; the button re-runs the same path
    });
})();
