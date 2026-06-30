/**
 * adapters/richtext.js
 * Rich-text (contenteditable) adapter stub for AI2Editor
 * TODO: Implement full rich-text editor when needed
 */

(function() {
    'use strict';

    if (!window.AI2EditorCore) {
        console.error('[AI2Editor] core.js must be loaded before adapters');
        return;
    }

    class RichTextAdapter {
        constructor(containerId, options = {}) {
            this.containerId = containerId;
            this.options = options;
            this.editor = null;
            this._init();
        }

        _init() {
            const container = document.getElementById(this.containerId);
            if (!container) return;

            container.contentEditable = true;
            container.style.whiteSpace = 'pre-wrap';
            this.editor = container;
            console.log('[AI2Editor] RichTextAdapter initialized (stub)');
        }

        setValue(content) {
            if (this.editor) this.editor.innerHTML = content || '';
        }

        getValue() {
            return this.editor ? this.editor.innerHTML : '';
        }

        destroy() {
            if (this.editor) {
                this.editor.contentEditable = false;
                this.editor = null;
            }
        }
    }

    window.AI2EditorCore.registerEditor('richtext', RichTextAdapter);
    console.log('[AI2Editor] RichText adapter registered (stub)');
})();