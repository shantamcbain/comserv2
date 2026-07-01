/**
 * adapters/ace.js
 * Ace editor adapter for AI2Editor
 */

(function() {
    'use strict';

    if (!window.AI2EditorCore) {
        console.error('[AI2Editor] core.js must be loaded before adapters');
        return;
    }

    class AceAdapter {
        constructor(containerId, options = {}) {
            this.containerId = containerId;
            this.options = Object.assign({
                theme: 'ace/theme/twilight',
                mode: 'ace/mode/perl',
                fontSize: '14px',
                showPrintMargin: false,
                wrap: true
            }, options);

            this.editor = null;
            this._init();
        }

        _init() {
            if (typeof ace === 'undefined') {
                console.error('[AI2Editor] Ace not loaded');
                return;
            }
            const container = document.getElementById(this.containerId);
            if (!container) {
                console.error('[AI2Editor] Container not found:', this.containerId);
                return;
            }
            this.editor = ace.edit(container);
            this.editor.setTheme(this.options.theme);
            this.editor.session.setMode(this.options.mode);
            this.editor.setOptions(this.options);
        }

        setValue(content, cursorPos = -1) {
            if (this.editor) this.editor.setValue(content || '', cursorPos);
        }

        getValue() {
            return this.editor ? this.editor.getValue() : '';
        }

        setMode(mode) {
            if (this.editor) this.editor.session.setMode(mode);
        }

        destroy() {
            if (this.editor) {
                this.editor.destroy();
                this.editor = null;
            }
        }
    }

    // Register with core
    window.AI2EditorCore.registerEditor('ace', AceAdapter);
    console.log('[AI2Editor] Ace adapter registered');
})();