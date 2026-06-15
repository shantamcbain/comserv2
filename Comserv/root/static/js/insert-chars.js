/**
 * ComservInsertChars — typography, emoji, and site icon insertion at cursor.
 */
(function (global) {
    'use strict';

    var TYPOGRAPHY = [
        { ch: '\u2014', title: 'Em dash \u2014' },
        { ch: '\u2013', title: 'En dash \u2013' },
        { ch: '\u2026', title: 'Ellipsis \u2026' },
        { ch: '\u2022', title: 'Bullet \u2022' },
        { ch: '\u00B7', title: 'Middle dot \u00B7' },
        { ch: '\u00AB', title: '\u00AB guillemet' },
        { ch: '\u00BB', title: '\u00BB guillemet' },
        { ch: '\u2018', title: 'Left quote \u2018' },
        { ch: '\u2019', title: 'Right quote \u2019' },
        { ch: '\u201C', title: 'Left double \u201C' },
        { ch: '\u201D', title: 'Right double \u201D' },
        { ch: '\u00A9', title: 'Copyright \u00A9' },
        { ch: '\u00AE', title: 'Registered \u00AE' },
        { ch: '\u2122', title: 'Trademark \u2122' },
        { ch: '\u00B0', title: 'Degree \u00B0' },
        { ch: '\u00B1', title: 'Plus-minus \u00B1' },
        { ch: '\u2192', title: 'Arrow \u2192' },
        { ch: '\u2190', title: 'Arrow \u2190' },
        { ch: '\u2713', title: 'Check \u2713' },
        { ch: '\u2717', title: 'Cross \u2717' }
    ];

    var EMOJI_ICONS = [
        { ch: '\uD83C\uDFE0', title: 'Home' },
        { ch: '\uD83D\uDC65', title: 'People' },
        { ch: '\uD83D\uDCC5', title: 'Calendar' },
        { ch: '\uD83D\uDCCA', title: 'Chart' },
        { ch: '\uD83D\uDD17', title: 'Link' },
        { ch: '\uD83D\uDCDE', title: 'Phone' },
        { ch: '\uD83D\uDCE7', title: 'Email' },
        { ch: '\uD83D\uDED2', title: 'Shop' },
        { ch: '\uD83C\uDF0D', title: 'Globe' },
        { ch: '\uD83D\uDCA1', title: 'Tip' },
        { ch: '\u2705', title: 'OK' },
        { ch: '\u2753', title: 'Question' },
        { ch: '\uD83D\uDCDA', title: 'Docs' },
        { ch: '\uD83D\uDD0D', title: 'Search' },
        { ch: '\uD83C\uDF6F', title: 'Honey' },
        { ch: '\uD83D\uDC1D', title: 'Bee' },
        { ch: '\uD83C\uDF3F', title: 'Plant' },
        { ch: '\uD83C\uDF93', title: 'Workshop' }
    ];

    var siteIconsCache = null;
    var siteIconsLoading = false;
    var siteIconsQueue = [];

    function iconsConfigEl() {
        return document.getElementById('insert-chars-config');
    }

    function iconsUrl() {
        var el = iconsConfigEl();
        return (el && el.getAttribute('data-icons-url')) || '/static/config/site_icons.json';
    }

    function parseInlineIcons() {
        var el = document.getElementById('insert-chars-icons-data');
        if (!el || !el.textContent) return null;
        try {
            var data = JSON.parse(el.textContent);
            return Array.isArray(data) ? data : null;
        } catch (e) {
            return null;
        }
    }

    function loadSiteIcons(callback) {
        if (siteIconsCache) {
            callback(siteIconsCache);
            return;
        }
        var inline = parseInlineIcons();
        if (inline && inline.length) {
            siteIconsCache = inline;
            callback(siteIconsCache);
            return;
        }
        siteIconsQueue.push(callback);
        if (siteIconsLoading) return;
        siteIconsLoading = true;

        fetch(iconsUrl(), { credentials: 'same-origin' })
            .then(function (r) { return r.ok ? r.json() : []; })
            .then(function (data) {
                siteIconsCache = Array.isArray(data) ? data : [];
                siteIconsLoading = false;
                var q = siteIconsQueue.slice();
                siteIconsQueue = [];
                q.forEach(function (cb) { cb(siteIconsCache); });
            })
            .catch(function () {
                siteIconsCache = [
                    { class: 'icon-home', label: 'home' },
                    { class: 'icon-member', label: 'member' },
                    { class: 'icon-workshop', label: 'workshop' },
                    { class: 'icon-calendar', label: 'calendar' },
                    { class: 'icon-link', label: 'link' },
                    { class: 'icon-helpdesk', label: 'help' },
                    { class: 'icon-search', label: 'search' }
                ];
                siteIconsLoading = false;
                var q = siteIconsQueue.slice();
                siteIconsQueue = [];
                q.forEach(function (cb) { cb(siteIconsCache); });
            });
    }

    function insertIntoInput(el, text) {
        if (!el) return;
        var start = el.selectionStart != null ? el.selectionStart : el.value.length;
        var end = el.selectionEnd != null ? el.selectionEnd : start;
        var val = el.value || '';
        el.value = val.substring(0, start) + text + val.substring(end);
        var pos = start + text.length;
        if (el.setSelectionRange) el.setSelectionRange(pos, pos);
        el.focus();
        el.dispatchEvent(new Event('input', { bubbles: true }));
    }

    function insertIntoCKEditor(editor, text) {
        if (!editor || !editor.model) return;
        editor.model.change(function (writer) {
            writer.insertText(text, editor.model.document.selection.getFirstPosition());
        });
        editor.editing.view.focus();
    }

    function visualEditRoot() {
        var surface = document.getElementById('page-editor-surface');
        if (!surface) return null;
        return surface.querySelector('.page-body[data-visual-edit="1"], .page-body');
    }

    function insertIntoVisualEditor(text, isHtml) {
        var root = visualEditRoot();
        if (!root) return false;
        var doc = root.ownerDocument;
        var win = doc.defaultView;
        root.focus();
        if (isHtml && win && win.document.queryCommandSupported('insertHTML')) {
            win.document.execCommand('insertHTML', false, text);
        } else if (!isHtml && win && win.document.queryCommandSupported('insertText')) {
            win.document.execCommand('insertText', false, text);
        } else {
            var sel = win ? win.getSelection() : null;
            if (sel && sel.rangeCount) {
                var range = sel.getRangeAt(0);
                range.deleteContents();
                if (isHtml) {
                    var tpl = doc.createElement('template');
                    tpl.innerHTML = text;
                    range.insertNode(tpl.content);
                } else {
                    range.insertNode(doc.createTextNode(text));
                }
            }
        }
        root.dispatchEvent(new Event('input', { bubbles: true }));
        return true;
    }

    function insertHtmlIntoEditor(state, html) {
        if (!state || !state.textarea) return;
        if (state.isWysiwyg && insertIntoVisualEditor(html, true)) {
            state.textarea.value = visualEditRoot() ? visualEditRoot().innerHTML : state.textarea.value;
            state.textarea.dispatchEvent(new Event('input', { bubbles: true }));
            return;
        }
        insertIntoInput(state.textarea, html);
        if (state.editor && state.isWysiwyg) {
            state.editor.setData(state.textarea.value);
        }
        state.textarea.dispatchEvent(new Event('input', { bubbles: true }));
    }

    function getPageEditorState(targetId) {
        if (targetId !== 'body' || typeof global.pageEditorInsertState !== 'function') return null;
        return global.pageEditorInsertState();
    }

    function insertForTarget(targetId, text, opts) {
        opts = opts || {};
        var state = getPageEditorState(targetId);

        if (opts.isHtml && state) {
            insertHtmlIntoEditor(state, text);
            return;
        }

        if (state && state.isWysiwyg && !opts.forceTextarea) {
            if (state.editor) {
                insertIntoCKEditor(state.editor, text);
                if (state.textarea) {
                    state.textarea.value = state.editor.getData();
                    state.textarea.dispatchEvent(new Event('input', { bubbles: true }));
                }
                return;
            }
            if (insertIntoVisualEditor(text, false)) {
                if (state.textarea && visualEditRoot()) {
                    state.textarea.value = visualEditRoot().innerHTML;
                    state.textarea.dispatchEvent(new Event('input', { bubbles: true }));
                }
                return;
            }
        }
        if (state && state.textarea) {
            insertIntoInput(state.textarea, text);
            return;
        }
        insertIntoInput(document.getElementById(targetId), text);
    }

    function positionPanel(panel, toggle) {
        var rect = toggle.getBoundingClientRect();
        panel.style.position = 'fixed';
        panel.style.top = (rect.bottom + 4) + 'px';
        panel.style.left = Math.max(8, rect.left) + 'px';
        panel.style.zIndex = '10050';
        panel.style.minWidth = '300px';
        panel.style.maxHeight = Math.max(200, Math.min(480, window.innerHeight - rect.bottom - 16)) + 'px';
        requestAnimationFrame(function () {
            var pr = panel.getBoundingClientRect();
            if (pr.right > window.innerWidth - 8) {
                panel.style.left = Math.max(8, window.innerWidth - pr.width - 8) + 'px';
            }
        });
    }

    function buildPanel(wrap, targetId, options) {
        var allowHtml = options.allowHtml !== false && targetId === 'body';
        var panel = document.createElement('div');
        panel.className = 'insert-chars-panel';
        panel.setAttribute('role', 'menu');
        var iconsLoaded = false;

        function addCharGroup(label, items) {
            if (!items || !items.length) return;
            var group = document.createElement('div');
            group.className = 'insert-chars-group';
            var lbl = document.createElement('span');
            lbl.className = 'insert-chars-group-label';
            lbl.textContent = label;
            group.appendChild(lbl);
            var grid = document.createElement('div');
            grid.className = 'insert-chars-grid';
            items.forEach(function (item) {
                var btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'insert-chars-item';
                btn.title = item.title || '';
                btn.textContent = item.ch;
                btn.addEventListener('click', function (e) {
                    e.preventDefault();
                    insertForTarget(targetId, item.ch);
                    closePanel();
                });
                grid.appendChild(btn);
            });
            group.appendChild(grid);
            panel.appendChild(group);
        }

        function addSiteIconGroup(items) {
            if (!items || !items.length) return;
            var group = document.createElement('div');
            group.className = 'insert-chars-group';
            var lbl = document.createElement('span');
            lbl.className = 'insert-chars-group-label';
            lbl.textContent = 'Site icons (' + items.length + ')';
            group.appendChild(lbl);
            var grid = document.createElement('div');
            grid.className = 'insert-chars-grid insert-chars-grid-icons';
            items.forEach(function (item) {
                var btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'insert-chars-item insert-chars-item-site-icon';
                btn.title = item.class;
                var iconEl = document.createElement('i');
                iconEl.className = 'icon ' + item.class;
                btn.appendChild(iconEl);
                var nameEl = document.createElement('span');
                nameEl.className = 'insert-chars-icon-name';
                nameEl.textContent = item.label || item.class.replace(/^icon-/, '');
                btn.appendChild(nameEl);
                btn.addEventListener('click', function (e) {
                    e.preventDefault();
                    insertForTarget(targetId, '<i class="' + item.class + '"></i>', { isHtml: true });
                    closePanel();
                });
                grid.appendChild(btn);
            });
            group.appendChild(grid);
            panel.appendChild(group);
        }

        addCharGroup('Typography', TYPOGRAPHY);
        if (!allowHtml) {
            addCharGroup('Symbols (OK for title & SEO)', EMOJI_ICONS);
        }

        var toggle = wrap.querySelector('.insert-chars-toggle');
        if (!toggle) return;

        function closePanel() {
            panel.classList.remove('is-open');
            toggle.setAttribute('aria-expanded', 'false');
        }

        function ensureSiteIcons() {
            if (!allowHtml || iconsLoaded) return;
            iconsLoaded = true;
            var loading = document.createElement('div');
            loading.className = 'insert-chars-loading';
            loading.textContent = 'Loading site icons\u2026';
            panel.appendChild(loading);
            loadSiteIcons(function (icons) {
                if (loading.parentNode) loading.parentNode.removeChild(loading);
                addSiteIconGroup(icons);
            });
        }

        function openPanel() {
            document.querySelectorAll('.insert-chars-panel.is-open').forEach(function (p) {
                p.classList.remove('is-open');
            });
            if (!panel.parentNode) document.body.appendChild(panel);
            panel.classList.add('is-open');
            toggle.setAttribute('aria-expanded', 'true');
            positionPanel(panel, toggle);
            ensureSiteIcons();
        }

        toggle.addEventListener('click', function (e) {
            e.preventDefault();
            e.stopPropagation();
            if (panel.classList.contains('is-open')) closePanel();
            else openPanel();
        });

        document.addEventListener('click', function (e) {
            if (wrap.contains(e.target) || panel.contains(e.target)) return;
            closePanel();
        });
        window.addEventListener('resize', function () {
            if (panel.classList.contains('is-open')) positionPanel(panel, toggle);
        });
        window.addEventListener('scroll', function () {
            if (panel.classList.contains('is-open')) positionPanel(panel, toggle);
        }, true);
    }

    function attachWrap(wrap) {
        if (!wrap || wrap.dataset.insertCharsBound) return;
        var targetId = wrap.getAttribute('data-insert-target');
        if (!targetId) return;
        wrap.dataset.insertCharsBound = '1';
        var allowHtml = wrap.getAttribute('data-allow-html') !== '0';
        buildPanel(wrap, targetId, { allowHtml: allowHtml });
    }

    function initAll(root) {
        (root || document).querySelectorAll('.insert-chars-wrap[data-insert-target]').forEach(attachWrap);
    }

    global.ComservInsertChars = {
        typography: TYPOGRAPHY,
        loadSiteIcons: loadSiteIcons,
        insert: insertForTarget,
        init: initAll
    };

    function boot() {
        loadSiteIcons(function () {});
        initAll();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})(typeof window !== 'undefined' ? window : this);