/**
 * floating-button.js
 * Handles the floating AI2 Code Editor button (✏️) on normal pages.
 * No inline JS in templates.
 */

(function() {
    'use strict';

    function initFloatingButton() {
        const btn = document.getElementById('ai2-open-editor-btn');
        if (!btn) return;

        btn.addEventListener('click', function() {
            window.open('/ai2/editing_widget_popup', 'AIEditor',
                'width=1400,height=900,resizable=yes,scrollbars=yes');
        });

        console.log('[AI2Editor] Floating button handler attached');
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initFloatingButton);
    } else {
        initFloatingButton();
    }
})();