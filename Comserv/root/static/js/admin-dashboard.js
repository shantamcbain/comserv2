/**
 * Admin Dashboard JS
 * Extracted from inline <script> blocks in admin/index.tt
 * Version: 0.01
 * Date: 2026-07-08
 * Author: shanta
 *
 * Uses data-* attribute delegation pattern (no inline onclick handlers).
 */

(function() {
    'use strict';

    // ── Hardware Agent Install ─────────────────────────────────────────────
    function installHwAgent(btn) {
        var ip = btn.getAttribute('data-ip');
        btn.disabled = true;
        btn.textContent = 'Installing…';
        fetch('/admin/install_hardware_agent?ip=' + encodeURIComponent(ip), {
            method: 'POST',
            credentials: 'same-origin'
        })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            btn.textContent = data.success ? 'Done — reloading' : 'Failed — click to retry';
            btn.disabled = false;
            if (data.success) {
                setTimeout(function() { location.reload(); }, 2500);
            } else if (data.output) {
                alert(data.output.slice(0, 500));
            }
        })
        .catch(function(err) {
            btn.textContent = 'Error — retry';
            btn.disabled = false;
            alert('Install error: ' + err);
        });
    }

    // ── Collapsible Admin Sections ─────────────────────────────────────────
    function toggleSection(section) {
        var wasExpanded = section.classList.contains('expanded');
        section.classList.toggle('expanded');
        // On first expand, lazy-load any cards inside this section
        if (!wasExpanded && section.classList.contains('expanded')) {
            lazyLoadCards(section);
        }
    }

    // ── Lazy-load dashboard cards ───────────────────────────────────────────
    // Cards marked with data-card are fetched on first expand and cached in
    // sessionStorage so they don't re-run their (potentially heavy) query on
    // every page reload. See Comserv::Util::AdminDashboard + /admin/api/card/*.
    function lazyLoadCards(scope) {
        var cards = scope.querySelectorAll('.lazy-card[data-card]');
        cards.forEach(function (card) {
            var name = card.getAttribute('data-card');
            if (card.getAttribute('data-loaded') === '1') return;

            var cacheKey = 'comserv_card_' + name;
            var cached = null;
            try { cached = sessionStorage.getItem(cacheKey); } catch (e) {}

            if (cached) {
                card.innerHTML = cached;
                card.setAttribute('data-loaded', '1');
                rebindCardWidgets(card);
                return;
            }

            card.setAttribute('data-loaded', 'loading');
            fetch('/admin/api/card/' + name, { credentials: 'same-origin' })
                .then(function (r) {
                    if (!r.ok) throw new Error('HTTP ' + r.status);
                    return r.text();
                })
                .then(function (html) {
                    card.innerHTML = html;
                    card.setAttribute('data-loaded', '1');
                    try { sessionStorage.setItem(cacheKey, html); } catch (e) {}
                    rebindCardWidgets(card);
                })
                .catch(function (err) {
                    card.innerHTML = '<div class="stat-panel-error">Failed to load: ' +
                        err.message + ' — <a href="/admin/api/card/' + name +
                        '" target="_blank">open directly</a></div>';
                    card.setAttribute('data-loaded', '0');
                });
        });
    }

    // The lazy card HTML is injected after page load, so re-bind any
    // delegation-based widgets it contains (e.g. hardware-agent install buttons
    // already use event delegation, so this is a no-op safety hook).
    function rebindCardWidgets(card) { /* delegation handles these; nothing needed */ }

    // Also lazy-load any card whose section is opened via URL hash on load
    function lazyLoadOpenCards() {
        document.querySelectorAll('.admin-section.expanded .lazy-card[data-card]')
            .forEach(function (card) { lazyLoadCards(card.closest('.admin-section')); });
    }

    function expandFromHash() {
        var hash = window.location.hash;
        if (hash) {
            var target = document.querySelector(hash);
            if (target && target.classList.contains('admin-section')) {
                target.classList.add('expanded');
                lazyLoadCards(target);
                target.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        }
    }

    // ── Init ───────────────────────────────────────────────────────────────
    document.addEventListener('DOMContentLoaded', function() {
        // Delegate click events on section headers for collapsible cards
        document.addEventListener('click', function(e) {
            var header = e.target.closest('.admin-section .section-header');
            if (header) {
                var section = header.closest('.admin-section');
                if (section) toggleSection(section);
            }
        });

        // Delegate click events on hardware agent install buttons
        document.addEventListener('click', function(e) {
            var btn = e.target.closest('[data-hw-install]');
            if (btn) {
                e.preventDefault();
                e.stopPropagation();
                installHwAgent(btn);
            }
        });

        // Auto-expand from URL hash (also lazy-loads any card in that section)
        expandFromHash();

        // Lazy-load any card already expanded on initial render
        lazyLoadOpenCards();
    });

    // Also handle hash changes (back/forward nav)
    window.addEventListener('hashchange', expandFromHash);

})();