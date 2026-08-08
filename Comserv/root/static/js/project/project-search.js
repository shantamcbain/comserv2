/**
 * project/project-search.js
 * Live search + filter for the /project/project card tree (Comserv JS V2 module).
 * Replaces the inline <script> that previously lived at the bottom of todo/project.tt.
 *
 * Behaviour:
 *  - Every collapsible-card (top-level project AND nested sub-project) carries
 *    data-search + data-priority, so both are searchable / priority-filterable.
 *  - Search shows a card when its own text matches OR a descendant matches, and
 *    keeps the ancestor branch visible so a matching sub-project is never orphaned.
 *  - Empty branches (no match anywhere in the subtree) are hidden.
 *  - Priority + project dropdowns trigger the same recompute, so all three filters
 *    compose correctly. (Server-side GET submit still available via Apply.)
 */

(function () {
    'use strict';

    // ---- toggleCollapse (kept global: template onclick="toggleCollapse('...')" calls it) ----
    window.toggleCollapse = function (elementId) {
        var element = document.getElementById(elementId);
        if (!element) return;
        var header = element.parentNode.querySelector('.card-header');
        var icon = header ? header.querySelector('.collapse-icon') : null;

        if (element.classList.contains('show')) {
            element.classList.remove('show');
            if (header) header.setAttribute('aria-expanded', 'false');
            if (icon) {
                icon.classList.remove('fa-chevron-up');
                icon.classList.add('fa-chevron-down');
            }
        } else {
            element.classList.add('show');
            if (header) header.setAttribute('aria-expanded', 'true');
            if (icon) {
                icon.classList.remove('fa-chevron-down');
                icon.classList.add('fa-chevron-up');
            }
        }
    };

    // ---- helpers ----
    function q(sel) { return Array.prototype.slice.call(document.querySelectorAll(sel)); }

    function getCards() {
        // Only the TOP-LEVEL project cards; sub-projects live INSIDE a parent's body,
        // so we recurse into each parent to find every descendant card.
        var tops = q('.collapsible-card[id^="project-"]');
        var all = [];
        tops.forEach(function (c) { all = all.concat(collectTree(c)); });
        return all;
    }

    function collectTree(card) {
        var out = [card];
        var body = document.getElementById(card.id.replace(/^project-/, 'project-body-'));
        if (!body) return out;
        // sub-projects are nested .collapsible-card elements inside this body
        Array.prototype.slice.call(body.querySelectorAll('.collapsible-card')).forEach(function (sub) {
            out = out.concat(collectTree(sub));
        });
        return out;
    }

    // Tokenize into lowercase words; treat hyphen/space/paren as separators so
    // "page-management" -> ["page","management"] and a query "page" matches.
    function tokenize(s) {
        return (s || '').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
    }

    // Word-based match: the query must equal a whole word in the card's search
    // text, or be a prefix of one (so "doc" matches "documentation" but "td"
    // does NOT match "standard"/"updated"). Prevents digraph false positives.
    function cardMatchesQuery(card, qWords) {
        if (!qWords.length) return true;
        var words = tokenize(card.getAttribute('data-search'));
        for (var i = 0; i < qWords.length; i++) {
            var qw = qWords[i];
            var hit = false;
            for (var j = 0; j < words.length; j++) {
                if (words[j] === qw || words[j].indexOf(qw) === 0) { hit = true; break; }
            }
            if (!hit) return false; // every query word must match some card word
        }
        return true;
    }

    function matchesSearch(card, qWords) {
        if (!qWords.length) return true;
        if (cardMatchesQuery(card, qWords)) return true;
        // also matches if any descendant card matches
        var body = document.getElementById(card.id.replace(/^project-/, 'project-body-'));
        if (body) {
            var subs = Array.prototype.slice.call(body.querySelectorAll('.collapsible-card'));
            for (var i = 0; i < subs.length; i++) {
                if (matchesSearch(subs[i], qWords)) return true;
            }
        }
        return false;
    }

    function cardPriority(card) {
        var p = parseInt(card.getAttribute('data-priority') || '2', 10);
        return isNaN(p) ? 2 : p;
    }

    function matchesPriority(card, p) {
        if (!p) return true;
        // a parent passes if it OR any descendant matches the priority
        if (cardPriority(card) === p) return true;
        var body = document.getElementById(card.id.replace(/^project-/, 'project-body-'));
        if (body) {
            var subs = Array.prototype.slice.call(body.querySelectorAll('.collapsible-card'));
            for (var i = 0; i < subs.length; i++) {
                if (matchesPriority(subs[i], p)) return true;
            }
        }
        return false;
    }

    function subtreeHasMatch(card, qWords, p) {
        // visible if this card or ANY descendant satisfies BOTH active filters
        if (matchesSearch(card, qWords) && matchesPriority(card, p)) return true;
        var body = document.getElementById(card.id.replace(/^project-/, 'project-body-'));
        if (body) {
            var subs = Array.prototype.slice.call(body.querySelectorAll('.collapsible-card'));
            for (var i = 0; i < subs.length; i++) {
                if (subtreeHasMatch(subs[i], qWords, p)) return true;
            }
        }
        return false;
    }

    var api = {
        onSearch: function (value) {
            this._apply(value);
        },
        onDropdown: function () {
            this._apply();
        },
        _apply: function (searchValue) {
            var qStr;
            var prioritySel = document.getElementById('priority_filter');
            var pVal = prioritySel ? prioritySel.value : '';
            var pInt = pVal ? parseInt(pVal, 10) : 0;

            if (typeof searchValue === 'string') {
                qStr = searchValue.trim().toLowerCase();
            } else {
                var input = document.getElementById('project_search');
                qStr = input ? input.value.trim().toLowerCase() : '';
            }

            // Word-based tokens (not a raw substring) so digraphs like "td"
            // don't false-match words like "standard"/"updated".
            var qWords = tokenize(qStr);

            var tops = q('.collapsible-card[id^="project-"]');
            var visibleCount = 0;

            tops.forEach(function (card) {
                var show = subtreeHasMatch(card, qWords, pInt);
                card.style.display = show ? '' : 'none';
                if (show) visibleCount++;
            });

            var countEl = document.getElementById('project_search_count');
            if (countEl) {
                if (qWords.length || pInt) {
                    countEl.textContent = 'Showing ' + visibleCount + ' project' + (visibleCount === 1 ? '' : 's');
                } else {
                    countEl.textContent = '';
                }
            }
        },

        // Auto-expand the project selected via the ?project_id= dropdown filter
        autoExpand: function () {
            var params = new URLSearchParams(window.location.search);
            var f = params.get('project_id');
            if (!f) return;
            var body = document.getElementById('project-body-' + f)
                    || document.getElementById('subproject-body-' + f);
            if (body) {
                if (!body.classList.contains('show')) window.toggleCollapse(body.id);
                // also expand the containing top-level project
                var topCard = body.closest('.collapsible-card[id^="project-"]');
                if (topCard) {
                    var topBody = document.getElementById(topCard.id.replace(/^project-/, 'project-body-'));
                    if (topBody && !topBody.classList.contains('show')) window.toggleCollapse(topBody.id);
                }
            }
        }
    };

    window.ComservProjectSearch = api;

    function init() {
        api.autoExpand();
        // re-run the live filter once, in case the server applied a filter on load
        api._apply();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
