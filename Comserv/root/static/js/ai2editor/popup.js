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

    // Expose initPopupEditor so core.js's initIslandPopup can call it
    window.AI2EditorPopup = {
        initPopupEditor: function() {
            // Read file-to-load from meta tag if present
            var meta = document.querySelector('meta[name="ai2-file-to-load"]');
            if (!meta) return;

            var filePath = meta.getAttribute('content');
            if (!filePath) return;

            console.log('[AI2] Loading file from meta tag:', filePath);

            // Wait for AI2EditorCore to be ready
            var tries = 0;
            function tryLoad() {
                if (!window.AI2EditorCore || !AI2EditorCore.loadFileContent) {
                    if (tries < 20) {
                        tries++;
                        setTimeout(tryLoad, 300);
                    }
                    return;
                }

                AI2EditorCore.loadFileContent(filePath).then(function(data) {
                    if (data && data.content !== undefined) {
                        // Update tab label
                        var tabLabel = document.querySelector('.editor-tabs span');
                        if (tabLabel) {
                            tabLabel.textContent = filePath.split('/').pop();
                        }

                        // Set editor content using core's createEditor
                        var editor = AI2EditorCore.createEditor('ace', 'ace-editor');
                        if (editor) {
                            editor.setValue(data.content, -1);
                            var statusEl = document.getElementById('file-status');
                            if (statusEl) statusEl.textContent = 'Loaded';
                        }
                    }
                }).catch(function(err) {
                    console.error('[AI2] Failed to load file from popup:', err);
                });
            }

            tryLoad();
        }
    };

    console.log('%c[AI2] Separate window ready', 'color:#0a0');
})();