// static/js/ai2editor/popup.js
// Reusable separate window popup for AI2 Editor (v2)
(function() {
    'use strict';

    window.openAI2EditorWindow = function(filePath) {
        const width = 1250;
        const height = 820;
        const left = (screen.width - width) / 2;
        const top = (screen.height - height) / 2;

        let url = '/ai2/editing_widget_popup';
        if (filePath) url += '?file=' + encodeURIComponent(filePath);

        window.open(
            url,
            'AI2Editor',
            `width=${width},height=${height},left=${left},top=${top},resizable=yes,scrollbars=yes,menubar=no,toolbar=no,status=no,noopener,noreferrer`
        );
    };

    console.log('%c[AI2] Separate window ready', 'color:#0a0');
})();