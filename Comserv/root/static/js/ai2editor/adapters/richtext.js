/**
 * adapters/richtext.js
 * Visual (WYSIWYG) mode for the AI Editor.
 *
 * Ace stays the source of truth so Save, chat, Approve, and auto-refresh
 * keep using ace.edit('ace-editor'). This module only shows a contenteditable
 * view of HTML / .tt files and writes edits back into Ace.
 *
 * TT tags, <script>, and <style> are frozen chips so a visual round-trip
 * cannot execute them or eat the directives.
 */
(function () {
    'use strict';

    var NS = 'AI2Wysiwyg';
    var mode = 'ace';
    var syncing = false;
    var userEdited = false;
    var flushTimer = null;
    var lastFlushed = null;
    var parts = null;
    var frozen = [];
    var surface = null;
    var frame = null;
    var aceBound = false;

    function log() {
        var args = Array.prototype.slice.call(arguments);
        args.unshift('[' + NS + ']');
        console.log.apply(console, args);
    }

    function aceEditor() {
        if (typeof ace === 'undefined' || !ace.edit) return null;
        var el = document.getElementById('ace-editor');
        if (!el) return null;
        try {
            return ace.edit('ace-editor');
        } catch (e) {
            return null;
        }
    }

    function currentPath() {
        if (window.AI2_FILE_TO_LOAD) return window.AI2_FILE_TO_LOAD;
        try {
            return new URLSearchParams(window.location.search).get('file') || '';
        } catch (e) {
            return '';
        }
    }

    function setStatus(msg, isError) {
        var el = document.getElementById('file-status');
        if (!el) return;
        el.textContent = msg;
        el.style.color = isError ? '#f66' : '#888';
    }

    function canVisualEdit(path, text) {
        var p = (path || '').toLowerCase();
        if (/\.(pm|pl|js|css|json|ya?ml|sql|md|sh)$/.test(p)) return false;
        if (/\.(html?|tt|inc)$/.test(p)) return true;
        return /<[a-z][\s\S]{0,40}>/i.test(text || '');
    }

    function splitBody(text) {
        var src = text == null ? '' : String(text);
        var m = src.match(/^([\s\S]*?<body\b[^>]*>)([\s\S]*)(<\/body>[\s\S]*)$/i);
        if (!m) return { prefix: '', body: src, suffix: '', wrapped: false };
        return { prefix: m[1], body: m[2], suffix: m[3], wrapped: true };
    }

    function chip(raw, label) {
        var i = frozen.length;
        frozen.push(raw);
        return '<span class="ai2-frozen" contenteditable="false" data-frozen="' + i + '">' + label + '</span>';
    }

    // Freeze TT / script / style that sit in text. Leave [% %] inside HTML
    // attributes alone — replacing those with a span would break the tag.
    function freeze(html) {
        frozen = [];
        var src = String(html || '');
        var out = '';
        var i = 0;
        var inTag = false;
        var quote = '';
        while (i < src.length) {
            if (!inTag && src.slice(i, i + 2) === '[%') {
                var end = src.indexOf('%]', i + 2);
                if (end !== -1) {
                    out += chip(src.slice(i, end + 2), 'TT');
                    i = end + 2;
                    continue;
                }
            }
            if (!inTag) {
                var probe = src.slice(i, i + 8).toLowerCase();
                var close = '';
                var label = '';
                if (probe.indexOf('<script') === 0) { close = '</script>'; label = 'script'; }
                else if (probe.indexOf('<style') === 0) { close = '</style>'; label = 'style'; }
                if (close) {
                    var endTag = src.toLowerCase().indexOf(close, i + close.length);
                    if (endTag !== -1) {
                        out += chip(src.slice(i, endTag + close.length), label);
                        i = endTag + close.length;
                        continue;
                    }
                }
            }
            var ch = src.charAt(i);
            if (!inTag && ch === '<') {
                inTag = true;
                quote = '';
            } else if (inTag) {
                if (quote) {
                    if (ch === quote) quote = '';
                } else if (ch === '"' || ch === "'") {
                    quote = ch;
                } else if (ch === '>') {
                    inTag = false;
                }
            }
            out += ch;
            i++;
        }
        return out;
    }

    function serialize() {
        if (!surface || !parts) return null;
        var clone = surface.cloneNode(true);
        clone.querySelectorAll('.ai2-frozen').forEach(function (el) {
            var i = parseInt(el.getAttribute('data-frozen'), 10);
            var raw = frozen[i] != null ? frozen[i] : '';
            el.parentNode.replaceChild(clone.ownerDocument.createTextNode(raw), el);
        });
        return parts.prefix + clone.innerHTML + parts.suffix;
    }

    function frameHtml() {
        return '<!DOCTYPE html><html><head><meta charset="utf-8">' +
            '<link rel="stylesheet" href="/static/css/base.css">' +
            '<style>' +
            'html,body{background:#fff;color:#222;}' +
            'body{font-family:Verdana,sans-serif;font-size:15px;line-height:1.45;margin:16px 20px;min-height:100%;outline:none;}' +
            '.ai2-frozen{display:inline-block;margin:0 2px;padding:0 5px;border:1px dashed #e6a817;' +
            'border-radius:3px;background:#fff3cd;color:#6a4b00;font:11px/1.4 ui-monospace,monospace;' +
            'user-select:none;vertical-align:baseline;}' +
            '</style></head><body contenteditable="true" spellcheck="true" lang="en"></body></html>';
    }

    function ensureFrame() {
        frame = document.getElementById('ai2-wysiwyg-frame');
        if (!frame) return false;
        var doc = frame.contentDocument;
        if (!doc) return false;
        if (surface && doc.body === surface) return true;
        doc.open();
        doc.write(frameHtml());
        doc.close();
        surface = doc.body;
        surface.setAttribute('data-gramm', 'true');
        surface.setAttribute('data-gramm_editor', 'true');
        surface.setAttribute('data-enable-grammarly', 'true');
        surface.addEventListener('input', onInput);
        surface.addEventListener('blur', flushToAce);
        surface.addEventListener('click', function (e) {
            var a = e.target && e.target.closest ? e.target.closest('a') : null;
            if (a) e.preventDefault();
        });
        try { doc.execCommand('styleWithCSS', false, false); } catch (e) { /* ignore */ }
        return true;
    }

    function renderFromAce() {
        if (mode !== 'richtext') return;
        if (!ensureFrame()) return;
        var ed = aceEditor();
        var text = ed ? (ed.getValue() || '') : '';
        parts = splitBody(text);
        userEdited = false;
        lastFlushed = text;
        surface.innerHTML = freeze(parts.body);
        var note = document.getElementById('ai2-wysiwyg-note');
        if (note) {
            note.textContent = parts.wrapped
                ? 'Editing the page body. Head, TT tags, scripts, and styles stay locked.'
                : 'Visual edit. TT tags, scripts, and styles stay locked. Save writes HTML back to the file.';
        }
    }

    function flushToAce() {
        if (mode !== 'richtext' || !userEdited) return;
        var ed = aceEditor();
        if (!ed) return;
        var next;
        try { next = serialize(); } catch (e) {
            log('serialize failed', e);
            return;
        }
        if (next == null || next === lastFlushed) return;
        syncing = true;
        try {
            ed.setValue(next, -1);
            ed.clearSelection();
            lastFlushed = next;
        } finally {
            syncing = false;
        }
    }

    function onInput() {
        userEdited = true;
        clearTimeout(flushTimer);
        flushTimer = setTimeout(flushToAce, 120);
    }

    function bindAce() {
        if (aceBound) return;
        var ed = aceEditor();
        if (!ed || !ed.session) return;
        aceBound = true;
        ed.session.on('change', function () {
            if (syncing || mode !== 'richtext') return;
            var now = ed.getValue();
            if (now === lastFlushed) return;
            renderFromAce();
        });
    }

    function showAce() {
        flushToAce();
        mode = 'ace';
        var host = document.getElementById('ai2-wysiwyg');
        var aceEl = document.getElementById('ace-editor');
        if (host) host.hidden = true;
        if (aceEl) aceEl.style.display = '';
        if (window.AI2EditorCore && typeof window.AI2EditorCore.resizeEditor === 'function') {
            window.AI2EditorCore.resizeEditor();
        }
        setStatus('Source');
    }

    function showVisual() {
        var ed = aceEditor();
        var text = ed ? (ed.getValue() || '') : '';
        var path = currentPath();
        if (!canVisualEdit(path, text)) {
            var sel = document.getElementById('editor-select');
            if (sel) sel.value = 'ace';
            setStatus('Visual edit is for HTML and template files — this file stays in Ace', true);
            return;
        }
        if (!ed) {
            setStatus('Editor not ready yet', true);
            var sel2 = document.getElementById('editor-select');
            if (sel2) sel2.value = 'ace';
            return;
        }
        bindAce();
        mode = 'richtext';
        var host = document.getElementById('ai2-wysiwyg');
        var aceEl = document.getElementById('ace-editor');
        if (aceEl) aceEl.style.display = 'none';
        if (host) host.hidden = false;
        renderFromAce();
        setStatus('Visual');
        try { frame.contentWindow.focus(); } catch (e) { /* ignore */ }
        log('visual mode', path || '(no file)');
    }

    function applyFormat(cmd) {
        if (mode !== 'richtext' || !surface) return;
        var doc = surface.ownerDocument;
        try { frame.contentWindow.focus(); } catch (e) { /* ignore */ }
        surface.focus();
        if (cmd === 'h2' || cmd === 'h3' || cmd === 'p') {
            doc.execCommand('formatBlock', false, '<' + cmd + '>');
        } else if (cmd === 'createLink') {
            var url = window.prompt('Link URL:', 'https://');
            if (!url) return;
            doc.execCommand('createLink', false, url);
        } else {
            doc.execCommand(cmd, false, null);
        }
        userEdited = true;
        flushToAce();
    }

    function onSelectChange() {
        var sel = document.getElementById('editor-select');
        if (!sel) return;
        if (sel.value === 'richtext') showVisual();
        else showAce();
    }

    function init() {
        var host = document.getElementById('ai2-wysiwyg');
        var sel = document.getElementById('editor-select');
        if (!host || !sel || sel.dataset.ai2Wysiwyg) return;
        sel.dataset.ai2Wysiwyg = '1';
        sel.addEventListener('change', onSelectChange);
        host.querySelectorAll('[data-cmd]').forEach(function (btn) {
            btn.addEventListener('mousedown', function (e) { e.preventDefault(); });
            btn.addEventListener('click', function (e) {
                e.preventDefault();
                applyFormat(btn.getAttribute('data-cmd'));
            });
        });
        var saveBtn = document.getElementById('save-btn');
        if (saveBtn) {
            saveBtn.addEventListener('click', function () { flushToAce(); }, true);
        }
        if (window.AI2EditorCore && typeof window.AI2EditorCore.registerEditor === 'function') {
            window.AI2EditorCore.registerEditor('richtext', RichTextAdapter);
        }
        log('ready');
    }

    function RichTextAdapter() {}
    RichTextAdapter.prototype.getValue = function () {
        flushToAce();
        var ed = aceEditor();
        return ed ? ed.getValue() : '';
    };
    RichTextAdapter.prototype.setValue = function () {
        if (window.AI2Wysiwyg) window.AI2Wysiwyg.refreshFromAce();
    };

    if (typeof window !== 'undefined') {
        window.AI2Wysiwyg = {
            flushToAce: flushToAce,
            refreshFromAce: function () {
                bindAce();
                if (mode === 'richtext') renderFromAce();
            },
            mode: function () { return mode; }
        };
    }

    if (typeof document !== 'undefined') {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else {
            init();
        }
    }

    if (typeof module !== 'undefined' && module.exports) {
        module.exports = { freeze: freeze, splitBody: splitBody, canVisualEdit: canVisualEdit };
    }
})();
