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
        section.classList.toggle('expanded');
    }

    function expandFromHash() {
        var hash = window.location.hash;
        if (hash) {
            var target = document.querySelector(hash);
            if (target && target.classList.contains('admin-section')) {
                target.classList.add('expanded');
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

        // Auto-expand from URL hash
        expandFromHash();
    });

    // Also handle hash changes (back/forward nav)
    window.addEventListener('hashchange', expandFromHash);

})();