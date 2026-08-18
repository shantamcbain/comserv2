/**
 * scan-progress.js — shared "operation in progress" overlay for any page.
 *
 * Generic busy indicator. Any form that triggers a slow server action can opt
 * in by adding the attribute:
 *
 *     <form ... data-busy-on-submit>
 *
 * On submit the helper shows a fixed full-screen overlay with a CSS spinner and
 * "Working…" text, disables the submit button, then lets the native submission
 * proceed (the server's redirect brings the user back when the work is done).
 *
 * Also exposed as window.ComservScanProgress.{show,hide} for programmatic use
 * (e.g. AJAX flows that aren't a plain form post).
 *
 * Styling lives in /static/css/scan-progress.css (theme-var driven). No inline
 * <script>; loaded globally via js_load.tt / Header.tt.
 */

(function () {
    'use strict';

    const OVERLAY_ID = 'comserv-scan-overlay';

    function ensureOverlay() {
        let overlay = document.getElementById(OVERLAY_ID);
        if (overlay) return overlay;

        overlay = document.createElement('div');
        overlay.id = OVERLAY_ID;
        overlay.className = 'comserv-scan-overlay';
        overlay.setAttribute('role', 'status');
        overlay.setAttribute('aria-live', 'polite');
        overlay.innerHTML = `
            <div class="comserv-scan-box">
                <div class="comserv-scan-spinner" aria-hidden="true"></div>
                <div class="comserv-scan-text">
                    <strong class="comserv-scan-title">Working&hellip;</strong><br>
                    <span class="comserv-scan-sub">Please wait &mdash; this may take a minute.</span>
                </div>
            </div>`;
        document.body.appendChild(overlay);
        return overlay;
    }

    const ComservScanProgress = {
        /**
         * Show the overlay. Optionally override the title/sub text and the
         * button to disable.
         * @param {object} [opts]
         * @param {string} [opts.title]
         * @param {string} [opts.sub]
         * @param {HTMLElement} [opts.button]  button to disable + relabel
         * @param {string} [opts.buttonLabel]
         */
        show(opts) {
            opts = opts || {};
            const overlay = ensureOverlay();
            if (opts.title) {
                const t = overlay.querySelector('.comserv-scan-title');
                if (t) t.innerHTML = opts.title;
            }
            if (opts.sub) {
                const s = overlay.querySelector('.comserv-scan-sub');
                if (s) s.innerHTML = opts.sub;
            }
            overlay.style.display = 'flex';

            if (opts.button) {
                const btn = opts.button;
                btn.disabled = true;
                if (opts.buttonLabel) {
                    btn.dataset.originalLabel = btn.innerHTML;
                    btn.innerHTML = opts.buttonLabel;
                }
            }
        },

        /** Hide the overlay and restore any disabled button. */
        hide() {
            const overlay = document.getElementById(OVERLAY_ID);
            if (overlay) overlay.style.display = 'none';

            document.querySelectorAll('[data-original-label]').forEach(btn => {
                btn.disabled = false;
                btn.innerHTML = btn.dataset.originalLabel;
                delete btn.dataset.originalLabel;
            });
        }
    };

    window.ComservScanProgress = ComservScanProgress;

    // Auto-bind to any form flagged with data-busy-on-submit.
    function bindForms() {
        document.querySelectorAll('form[data-busy-on-submit]').forEach(form => {
            if (form.__scanBound) return;
            form.__scanBound = true;
            form.addEventListener('submit', function () {
                const btn = form.querySelector('button[type="submit"]');
                ComservScanProgress.show({
                    button: btn,
                    buttonLabel: '&#128270; Working&hellip;'
                });
                // Native submission continues; redirect returns when done.
            });
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', bindForms);
    } else {
        bindForms();
    }
})();
