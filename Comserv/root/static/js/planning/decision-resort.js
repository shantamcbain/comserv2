/**
 * planning/decision-resort.js
 * Today's Focus: sort the queue with the LOCAL decision model (DecisionRank,
 * Ollama systemone - nimble by default) on every Daily Plan load, plus a
 * "Resort" button. The model runs in a detached server process
 * (POST /planning/decision_rank); this file polls
 * GET /planning/decision_rank_status and reorders the cards in place when the
 * new cache lands. Never blocks the page: status text only, hard stop at
 * MAX_WAIT_MS with a message (the job keeps running server-side).
 *
 * Reorder mirrors Util::AI::DecisionRank::apply_order: inside each contiguous
 * group of cards sharing data-active|data-branch, rows whose confidence clears
 * the gate are ordered by model score (desc); the rest keep code-score order.
 */
(function () {
    'use strict';

    var POLL_MS     = 4000;
    var SLOW_MS     = 45000;    // say "still sorting (model warming up)"
    var MAX_WAIT_MS = 240000;   // stop polling; job keeps running server-side
    var busy = false;

    function $(id) { return document.getElementById(id); }

    function setStatus(text, kind) {
        var el = $('decision-rank-status');
        if (!el) return;
        el.textContent = text || '';
        el.setAttribute('data-kind', kind || '');
        el.style.color = kind === 'error' ? '#9b0000' : (kind === 'done' ? '#2a7a2a' : '');
    }

    function setBusy(on) {
        busy = on;
        var btn = $('decision-resort-btn');
        if (!btn) return;
        btn.disabled = !!on;
        btn.textContent = on ? '🤖 Sorting…' : '🤖 Resort';
    }

    function fmtTime(epoch) {
        if (!epoch) return '';
        var d = new Date(epoch * 1000);
        var h = d.getHours(), m = d.getMinutes();
        return (h % 12 || 12) + ':' + (m < 10 ? '0' : '') + m + (h < 12 ? ' AM' : ' PM');
    }

    function applyCache(cache) {
        var list = $('priorities-list');
        if (!list || !cache || !cache.rows) return { used: 0, moved: 0 };
        var gate = (typeof cache.gate === 'number') ? cache.gate : 0.3;
        var cards = Array.prototype.slice.call(list.querySelectorAll('[data-priority]'));
        var before = cards.map(function (c) { return c.id; });

        function idOf(card) { return (card.id || '').replace(/^ap-row-/, ''); }
        function key(card) { return (card.dataset.active || '0') + '|' + (card.dataset.branch || '0'); }

        var out = [], used = 0, i = 0;
        while (i < cards.length) {
            var k = key(cards[i]), j = i;
            while (j < cards.length && key(cards[j]) === k) j++;
            var ranked = [], plain = [];
            for (var n = i; n < j; n++) {
                var d = cache.rows[idOf(cards[n])];
                if (d && d.score !== null && d.score !== undefined && (d.confidence || 0) >= gate) {
                    ranked.push({ c: cards[n], s: d.score, n: n });
                } else {
                    plain.push({ c: cards[n], s: parseFloat(cards[n].dataset.score || 9999), n: n });
                }
            }
            ranked.sort(function (a, b) { return (b.s - a.s) || (a.n - b.n); });
            plain.sort(function (a, b) { return (a.s - b.s) || (a.n - b.n); });
            used += ranked.length;
            ranked.concat(plain).forEach(function (x) { out.push(x.c); });
            i = j;
        }
        var moved = 0;
        out.forEach(function (card, idx) {
            if (before[idx] !== card.id) moved++;
            card.dataset.queueRank = String(idx + 1);
            var badge = card.querySelector('.rank-badge');
            if (badge) badge.textContent = idx + 1;
            list.appendChild(card);
        });
        var note = $('decision-order-note');
        if (note) {
            note.textContent = '🤖 ' + (cache.model || '') + ' ' + used + '/' +
                Object.keys(cache.rows).length + ' by model (gate ' + gate + ')';
            note.title = 'Ordered by the local decision model at ' + fmtTime(cache.computed_at) + '.';
        }
        if (typeof window.sortTodos === 'function') {
            // keep the Queue sort button highlighted / consistent
            var qb = $('sort-queue');
            if (qb && qb.classList.contains('SortBtn--active')) { /* already queue */ }
        }
        return { used: used, moved: moved };
    }

    function poll(startedAt, t0) {
        fetch('/planning/decision_rank_status', { credentials: 'same-origin' })
            .then(function (r) { return r.json(); })
            .then(function (d) {
                if (!d.success) { setBusy(false); setStatus('Sort unavailable: ' + (d.error || '?'), 'error'); return; }
                var waited = Date.now() - t0;
                if (d.done) {
                    var res = applyCache(d.cache);
                    setBusy(false);
                    setStatus('Sorted by ' + (d.cache && d.cache.model || d.model) + ' at ' +
                        fmtTime(d.cache && d.cache.computed_at) + ' — ' + res.used + ' ranked, ' +
                        res.moved + ' moved', 'done');
                    return;
                }
                if (d.failed) {
                    setBusy(false);
                    setStatus('Sort failed: ' + String(d.error || '').split('\n').filter(Boolean).pop(), 'error');
                    return;
                }
                if (waited > MAX_WAIT_MS) {
                    setBusy(false);
                    setStatus('Still sorting in the background (' + Math.round(waited / 1000) +
                        's). Reload or press Resort later to see it.', 'error');
                    return;
                }
                var secs = Math.round(waited / 1000);
                setStatus((waited > SLOW_MS ? 'Still sorting — ' + (d.model || 'model') + ' warming up… '
                                            : 'Sorting with ' + (d.model || 'model') + '… ') + secs + 's', 'busy');
                setTimeout(function () { poll(startedAt, t0); }, POLL_MS);
            })
            .catch(function (e) {
                setBusy(false);
                setStatus('Sort status check failed: ' + e.message, 'error');
            });
    }

    function run(reason) {
        if (busy) return;
        var btn = $('decision-resort-btn');
        if (!btn) return;
        setBusy(true);
        setStatus(reason === 'load' ? 'Sorting…' : 'Resorting…', 'busy');
        var t0 = Date.now();
        fetch('/planning/decision_rank', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ reason: reason, model: btn.getAttribute('data-model') || '' })
        })
            .then(function (r) { return r.json(); })
            .then(function (d) {
                if (!d.success) { setBusy(false); setStatus('Sort unavailable: ' + (d.error || '?'), 'error'); return; }
                if (d.fresh) {
                    setBusy(false);
                    setStatus('Order is fresh (' + (d.model || '') + ' at ' + fmtTime(d.computed_at) + ')', 'done');
                    return;
                }
                poll(d.started_at, t0);
            })
            .catch(function (e) {
                setBusy(false);
                setStatus('Sort request failed: ' + e.message, 'error');
            });
    }

    document.addEventListener('click', function (e) {
        var b = e.target.closest('[data-action="decision-resort"]');
        if (!b) return;
        e.preventDefault();
        run('resort');
    });

    document.addEventListener('DOMContentLoaded', function () {
        var btn = $('decision-resort-btn');
        if (btn && btn.getAttribute('data-autorank') === '1' && $('priorities-list')) {
            run('load');
        }
    });

    window.decisionResort = run;
})();
