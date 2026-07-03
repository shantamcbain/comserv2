// static/js/ai2editor/popup.js
// Reusable separate window popup for AI2 Editor (v2)
(function() {
    'use strict';

    window.openAI2EditorWindow = function() {
        const width = 1250;
        const height = 820;
        const left = (screen.width - width) / 2;
        const top = (screen.height - height) / 2;

        window.open(
            '/ai2/editing_widget_popup',
            'AI2Editor',
            `width=${width},height=${height},left=${left},top=${top},resizable=yes,scrollbars=yes,menubar=no,toolbar=no,status=no,noopener,noreferrer`
        );
    };

    console.log('%c[AI2] Separate window ready', 'color:#0a0');
})();