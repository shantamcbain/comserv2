/**
 * logging-dedupe.js — live system_log row-count ticker for /admin/logging.
 *
 * Polls /admin/logging/dedupe_status while a dedupe run is in progress and
 * updates the "system_log table size: N rows" badge in real time, so the
 * user can watch the count step down as duplicate rows are deleted.
 *
 * Loaded via js_load.tt under a /admin/logging conditional (defer).
 * No inline script in the template; binds via data attributes / element ids.
 */

(function () {
    'use strict';

    var POLL_MS = 2000;          // poll every 2s while running
    var MAX_POLLS = 900;         // ~30 min hard cap (safety; PID guard is the real stop)

    function el(id) { return document.getElementById(id); }

    // Locate the live count badge + status slot rendered by the template.
    function getNodes() {
        return {
            rows:  el('system_log_rows_count'),
            wrap:  el('system_log_dedupe_status'),
            run:   el('system_log_dedupe_running')
        };
    }

    function fmt(n) {
        n = n + 0;
        return n.toLocaleString('en-US');
    }

    function setRows(nodes, n) {
        if (nodes.rows) nodes.rows.textContent = fmt(n);
        // Keep the legacy server-rendered paragraph badge in sync too.
        var legacy = document.querySelector('.system-log-rows-value');
        if (legacy) legacy.textContent = fmt(n);
    }

    function setRunning(nodes, running, n) {
        if (!nodes.wrap) return;
        if (running) {
            nodes.wrap.innerHTML =
                '<span class="badge badge-warning">dedupe in progress' +
                (n != null ? ' — ' + fmt(n) + ' rows' : '') + '</span>';
        } else {
            nodes.wrap.innerHTML = '';
        }
    }

    function poll() {
        var nodes = getNodes();
        if (!nodes.rows && !nodes.run) return;   // page has no dedupe UI

        var count = 0, running = false;

        function tick() {
            if (count >= MAX_POLLS) { setRunning(nodes, false); return; }
            count++;
            fetch('/admin/logging/dedupe_status', { credentials: 'same-origin' })
                .then(function (r) { return r.ok ? r.json() : null; })
                .then(function (data) {
                    if (!data) { schedule(); return; }
                    running = !!(data.dedupe_running);
                    if (typeof data.system_log_rows === 'number') {
                        setRows(nodes, data.system_log_rows);
                    }
                    setRunning(nodes, running, data.system_log_rows);
                    if (running) { schedule(); }
                    else { setRunning(nodes, false); }   // final clear
                })
                .catch(function () { schedule(); });
        }

        function schedule() { setTimeout(tick, POLL_MS); }

        tick();
    }

    // Kick off: if the server says a run is already in progress, poll now.
    // Otherwise the button handler (below) starts polling when clicked.
    function init() {
        var nodes = getNodes();
        if (!nodes.rows && !nodes.run) return;

        if (nodes.run && nodes.run.getAttribute('data-running') === '1') {
            poll();
        }

        // When the dedupe form is submitted, start polling immediately
        // (the PID file / run state may lag a moment behind the redirect).
        var form = document.querySelector('form[data-dedupe-trigger]');
        if (form) {
            form.addEventListener('submit', function () {
                // small delay to let the redirect + background launch settle
                setTimeout(poll, 800);
            });
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
