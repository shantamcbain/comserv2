/**
 * project/project-search.js
 * Live search + filter + RELEVANCE RANKING for the /project project card tree
 * (Comserv JS V2 module).
 *
 * Replaces the inline <script> that previously lived at the bottom of todo/project.tt.
 *
 * Behaviour:
 *  - Every collapsible-card (top-level project AND nested sub-project) carries
 *    data-search + data-priority, so both are searchable / priority-filterable.
 *  - On each keystroke / dropdown change we:
 *      1. score every card against the query (name/code weighted via whole-token
 *         match > prefix > substring),
 *      2. a card is visible if it OR any descendant matches AND passes the
 *         priority filter,
 *      3. REORDER so the best-matching branches float to the top (closest
 *         matches first) instead of just hiding non-matches in place,
 *      4. auto-expand every branch that contains a match so the match is visible
 *         without manually opening cards.
 *  - Clearing the search (and no priority filter) restores the original
 *    alphabetical DOM order and collapses branches back to default.
 *
 * PERFORMANCE: card token arrays are computed ONCE at init and cached; the
 * score is recomputed per keystroke but against the cached tokens, so typing
 * stays cheap even with a large tree.
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

    function tokenize(s) {
        return (s || '').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
    }

    // Cached state, built once at init.
    var cardTokens = new Map();   // cardId -> string[] (tokenized data-search)
    var cardPriority = new Map(); // cardId -> int
    var originalIndex = new Map(); // cardId -> int (DOM order at load, for stable tie-break + restore)
    var bodyIdFor = {};           // cardId -> body element id

    function cardId(card) {
        return card.id;
    }

    function bodyFor(card) {
        var id = cardId(card);
        if (bodyIdFor[id] !== undefined) {
            var el = document.getElementById(bodyIdFor[id]);
            if (el) return el;
        }
        // derive body id from card id: project-<n> -> project-body-<n>, etc.
        var m = id.match(/^(.*?)-\d+$/);
        var bid = m ? (m[1] + '-body-' + id.replace(/^.*?-/, '')) : (id + '-body');
        bodyIdFor[id] = bid;
        return document.getElementById(bid);
    }

    function directSubCards(card) {
        var body = bodyFor(card);
        if (!body) return [];
        return Array.prototype.slice.call(body.querySelectorAll(':scope > .collapsible-card'));
    }

    function allDescendantCards(card) {
        var body = bodyFor(card);
        if (!body) return [];
        return Array.prototype.slice.call(body.querySelectorAll('.collapsible-card'));
    }

    // ---- scoring ----
    // Returns 0..N. Matches the whole token highest (exact), then prefix, then
    // substring. Each query word contributes its best match across the card's tokens.
    function cardScore(card, qWords) {
        if (!qWords.length) return 0;
        var tokens = cardTokens.get(cardId(card)) || [];
        if (!tokens.length) return 0;
        var total = 0;
        for (var i = 0; i < qWords.length; i++) {
            var qw = qWords[i];
            var best = 0;
            for (var j = 0; j < tokens.length; j++) {
                var t = tokens[j];
                if (t === qw) { best = 3; break; }
                if (t.indexOf(qw) === 0) { if (2 > best) best = 2; }
                else if (t.indexOf(qw) !== -1) { if (1 > best) best = 1; }
            }
            total += best;
        }
        return total;
    }

    // Best score anywhere in the subtree (own card + all descendants).
    function subtreeBestScore(card, qWords) {
        var best = cardScore(card, qWords);
        var descs = allDescendantCards(card);
        for (var i = 0; i < descs.length; i++) {
            var s = cardScore(descs[i], qWords);
            if (s > best) best = s;
        }
        return best;
    }

    function matchesPriority(card, p) {
        if (!p) return true;
        if ((cardPriority.get(cardId(card)) || 2) === p) return true;
        var descs = allDescendantCards(card);
        for (var i = 0; i < descs.length; i++) {
            if ((cardPriority.get(cardId(descs[i])) || 2) === p) return true;
        }
        return false;
    }

    // Assemble a card's ranking record.
    // A card is VISIBLE if it passes the priority filter AND either there is no
    // active search (priority-only filter) or its subtree has a search match.
    // `searching` is true when qWords is non-empty.
    function rankCard(card, qWords, p, searching) {
        var score = subtreeBestScore(card, qWords);
        var searchOk = !searching || score > 0;
        var visible = searchOk && matchesPriority(card, p);
        return {
            card: card,
            score: searching ? score : 0,
            visible: visible,
            idx: originalIndex.get(cardId(card)) || 0
        };
    }

    // ---- reorder direct children of a container by their subtree score ----
    function reorderContainer(container, qWords, p) {
        if (!container) return 0;
        var children = Array.prototype.slice.call(container.children).filter(function (n) {
            return n.classList && n.classList.contains('collapsible-card');
        });
        var searching = qWords.length > 0;
        var ranked = children.map(function (c) { return rankCard(c, qWords, p, searching); });

        // sort: visible first by score desc, then original index asc; hidden last.
        ranked.sort(function (a, b) {
            if (a.visible !== b.visible) return a.visible ? -1 : 1;
            if (b.score !== a.score) return b.score - a.score;
            return a.idx - b.idx;
        });

        // re-append in sorted order (this also moves hidden ones to the end)
        ranked.forEach(function (r) {
            container.appendChild(r.card);
            r.card.style.display = r.visible ? '' : 'none';
        });

        var visibleCount = 0;
        ranked.forEach(function (r) { if (r.visible) visibleCount++; });
        return visibleCount;
    }

    // ---- auto-expand branches that contain a match ----
    function expandMatchingBranches(card, qWords) {
        var body = bodyFor(card);
        if (!body) return;
        var descs = directSubCards(card);
        for (var i = 0; i < descs.length; i++) {
            var sub = descs[i];
            var subBest = subtreeBestScore(sub, qWords);
            var subBody = bodyFor(sub);
            if (subBest > 0 && subBody && !subBody.classList.contains('show')) {
                window.toggleCollapse(subBody.id);
            }
            expandMatchingBranches(sub, qWords);
        }
    }

    // ---- collapse every branch (reset to default) ----
    function collapseAll() {
        q('.collapsible-card').forEach(function (card) {
            var body = bodyFor(card);
            if (body && body.classList.contains('show')) {
                window.toggleCollapse(body.id);
            }
        });
    }

    var api = {
        onSearch: function (value) {
            this._apply(value);
        },
        onDropdown: function () {
            this._apply();
        },
        clearAll: function () {
            var input = document.getElementById('project_search');
            if (input) input.value = '';
            var pf = document.getElementById('priority_filter');
            if (pf) pf.value = '';
            var pj = document.getElementById('project_filter');
            if (pj) pj.value = '';
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

            var qWords = tokenize(qStr);
            var searching = qWords.length > 0;
            var filtering = searching || !!pInt;

            // Top-level container holds the root project cards.
            var tree = document.getElementById('project-tree');
            var topContainer = tree || (q('.collapsible-card[id^="project-"]')[0]
                ? q('.collapsible-card[id^="project-"]')[0].parentNode : null);

            var totalTops = q('.collapsible-card[id^="project-"]').length;
            var visibleCount = 0;

            if (!filtering) {
                // Restore original alphabetical DOM order and collapse.
                this._restoreOrder(tree);
                collapseAll();
            } else {
                // 1) reorder + rank top-level cards within their container.
                visibleCount = reorderContainer(topContainer, qWords, pInt);
                // 2) reorder each top-level branch's direct sub-projects.
                var tops = q('.collapsible-card[id^="project-"]');
                tops.forEach(function (card) {
                    var body = bodyFor(card);
                    if (body) reorderContainer(body, qWords, pInt);
                    // also reorder nested sub-project containers
                    Array.prototype.slice.call(body ? body.querySelectorAll('.sub-projects-container') : []).forEach(function (sc) {
                        reorderContainer(sc, qWords, pInt);
                    });
                });
                // 3) auto-expand branches that contain a match.
                tops.forEach(function (card) {
                    var body = bodyFor(card);
                    if (body && subtreeBestScore(card, qWords) > 0 && !body.classList.contains('show')) {
                        window.toggleCollapse(body.id);
                    }
                    expandMatchingBranches(card, qWords);
                });
            }

            var countEl = document.getElementById('project_search_count');
            if (countEl) {
                if (filtering) {
                    countEl.textContent = 'Showing ' + visibleCount + ' of ' + totalTops + ' projects';
                } else {
                    countEl.textContent = '';
                }
            }
        },

        _restoreOrder: function (tree) {
            if (!tree) return;
            var children = Array.prototype.slice.call(tree.children).filter(function (n) {
                return n.classList && n.classList.contains('collapsible-card');
            });
            children.sort(function (a, b) {
                return (originalIndex.get(cardId(a)) || 0) - (originalIndex.get(cardId(b)) || 0);
            });
            children.forEach(function (c) { tree.appendChild(c); c.style.display = ''; });
            // also restore sub-project order inside each branch
            q('.sub-projects-container').forEach(function (sc) {
                var subs = Array.prototype.slice.call(sc.children).filter(function (n) {
                    return n.classList && n.classList.contains('collapsible-card');
                });
                subs.sort(function (a, b) {
                    return (originalIndex.get(cardId(a)) || 0) - (originalIndex.get(cardId(b)) || 0);
                });
                subs.forEach(function (s) { sc.appendChild(s); s.style.display = ''; });
            });
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
                var topCard = body.closest('.collapsible-card[id^="project-"]');
                if (topCard) {
                    var topBody = bodyFor(topCard);
                    if (topBody && !topBody.classList.contains('show')) window.toggleCollapse(topBody.id);
                }
            }
        }
    };

    window.ComservProjectSearch = api;

    function buildCache() {
        var all = q('.collapsible-card');
        all.forEach(function (card, i) {
            var id = cardId(card);
            cardTokens.set(id, tokenize(card.getAttribute('data-search')));
            cardPriority.set(id, parseInt(card.getAttribute('data-priority') || '2', 10) || 2);
            originalIndex.set(id, i);
        });
    }

    function init() {
        buildCache();
        api.autoExpand();
        api._apply();

        var clearBtn = document.getElementById('clearFilters');
        if (clearBtn && !clearBtn._wired) {
            clearBtn._wired = true;
            clearBtn.addEventListener('click', function () { api.clearAll(); });
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
