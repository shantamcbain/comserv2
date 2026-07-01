/**
 * floating-buttons.js
 * Centralized floating Back-to-Top + AI2 Editor button handlers
 * Loaded via js_load.tt (defer)
 */
(function() {
    'use strict';

    function initBackToTop() {
        const btn = document.getElementById('back-to-top');
        if (!btn) return;

        // Show/hide on scroll
        window.addEventListener('scroll', () => {
            if (window.scrollY > 300) {
                btn.classList.add('visible');
            } else {
                btn.classList.remove('visible');
            }
        });

        // Click handler
        btn.addEventListener('click', () => {
            window.scrollTo({ top: 0, behavior: 'smooth' });
        });
    }

    function initAI2EditorButton() {
        // The AI2 floating button is handled by ai-editing-widget-float.js when present.
        // This is a placeholder for any additional wiring if needed.
        // Future: dynamic insertion of the button if show_code_editor_widget is true.
    }

    // Boot
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', () => {
            initBackToTop();
            initAI2EditorButton();
        });
    } else {
        initBackToTop();
        initAI2EditorButton();
    }
})();