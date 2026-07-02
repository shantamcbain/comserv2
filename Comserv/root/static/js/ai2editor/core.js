/**
 * core.js
 * AI2 Editor Core - EditorAdapter abstraction + reusable file operations
 * Logging prefix: [AI2Editor]
 *
 * This module provides a swappable editor interface so the underlying
 * editor (Ace, Monaco, etc.) can be changed without touching popup.js.
 */

(function() {
    'use strict';

    const NS = 'AI2Editor';

    /**
     * EditorAdapter
     * Abstract wrapper around the concrete editor implementation.
     * Current implementation uses Ace.
     */
    class EditorAdapter {
        constructor(containerId, options = {}) {
            this.containerId = containerId;
            this.options = Object.assign({
                theme: 'ace/theme/twilight',
                mode: 'ace/mode/perl',
                fontSize: '14px',
                showPrintMargin: false,
                wrap: true,
                enableBasicAutocompletion: true,
                enableLiveAutocompletion: true
            }, options);

            this.editor = null;
            this._init();
        }

        _init() {
            if (typeof ace === 'undefined') {
                console.error(`[${NS}] Ace editor not loaded`);
                return;
            }

            const container = document.getElementById(this.containerId);
            if (!container) {
                console.error(`[${NS}] Container not found: ${this.containerId}`);
                return;
            }

            this.editor = ace.edit(container);
            this.editor.setTheme(this.options.theme);
            this.editor.session.setMode(this.options.mode);
            this.editor.setOptions(this.options);

            console.log(`[${NS}] EditorAdapter initialized with Ace`);
        }

        setValue(content, cursorPos = -1) {
            if (!this.editor) return;
            this.editor.setValue(content || '', cursorPos);
        }

        getValue() {
            return this.editor ? this.editor.getValue() : '';
        }

        setMode(mode) {
            if (this.editor) {
                this.editor.session.setMode(mode);
            }
        }

        setTheme(theme) {
            if (this.editor) {
                this.editor.setTheme(theme);
            }
        }

        focus() {
            if (this.editor) {
                this.editor.focus();
            }
        }

        on(event, handler) {
            if (this.editor) {
                this.editor.session.on(event, handler);
            }
        }

        destroy() {
            if (this.editor) {
                this.editor.destroy();
                this.editor = null;
            }
        }
    }

    /**
     * File operations – reuse existing /ai2/load_file and /ai2/file_checksum
     */
    async function loadFileContent(path) {
        try {
            const res = await fetch(`/ai2/load_file?path=${encodeURIComponent(path)}`);
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            const data = await res.json();
            console.log(`[${NS}] File loaded: ${path}`);
            return data;
        } catch (err) {
            console.error(`[${NS}] loadFileContent error:`, err);
            throw err;
        }
    }

    async function getFileMtime(path) {
        try {
            const res = await fetch(`/ai2/file_checksum?path=${encodeURIComponent(path)}`);
            if (!res.ok) return null;
            const data = await res.json();
            return data.mtime || null;
        } catch (err) {
            console.error(`[${NS}] getFileMtime error:`, err);
            return null;
        }
    }

    // Editor registry (for swappable editors)
    const editors = {
        ace: EditorAdapter,
        // richtext: RichTextAdapter,   // TODO: add later
    };

    function registerEditor(name, AdapterClass) {
        editors[name] = AdapterClass;
    }

    function getAvailableEditors() {
        return Object.keys(editors);
    }

    function createEditor(name, containerId, options = {}) {
        const Adapter = editors[name];
        if (!Adapter) {
            console.error(`[${NS}] Unknown editor: ${name}`);
            return null;
        }
        return new Adapter(containerId, options);
    }

    // Expose public API
    window.AI2EditorCore = {
        EditorAdapter,
        loadFileContent,
        getFileMtime,
        registerEditor,
        getAvailableEditors,
        createEditor,
        NS
    };

    function initCore() {
        if (document.documentElement.dataset.ai2editorCore) return;
        document.documentElement.dataset.ai2editorCore = '1';
        console.log(`[${NS}] core initialized (idempotent)`);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initCore);
    } else {
        initCore();
    }
    document.addEventListener('htmx:afterSwap', initCore);

    console.log(`[${NS}] core.js loaded`);

})();