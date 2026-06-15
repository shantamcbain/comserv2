/**
 * ComservPageContainers — drag containers; drop uses mouse position; Left/Right/Inside dialog.
 */
(function (global) {
    'use strict';

    var BLOCK_SELECTORS = '.bm-section,.bm-hero,.bm-card,.bm-feature,.bm-callout,.bm-tagline,.bm-grid,.bm-feature-grid,.bm-security,.pe-box,.pe-cols-2,.bm-page';
    var DRAGGABLE_BLOCKS = '.bm-section,.bm-hero,.bm-card,.bm-feature,.bm-callout,.bm-tagline,.bm-security,.pe-box,.bm-page';
    var DRAG_MIME = 'application/x-comserv-container';
    var DRAG_HTML_MIME = 'application/x-comserv-container-html';

    var cache = null;
    var dragState = null;
    var selectedContainer = null;
    var surfaceDropBound = false;
    var dropHandled = false;

    function editorSurface() {
        return document.getElementById('page-editor-surface')
            || (global.pageEditorGetSurface && global.pageEditorGetSurface());
    }

    function containersUrl() {
        var el = document.getElementById('page-containers-config');
        return (el && el.getAttribute('data-url')) || '/static/config/page_containers.json';
    }

    function loadContainers(cb) {
        if (cache) { cb(cache); return; }
        fetch(containersUrl(), { credentials: 'same-origin' })
            .then(function (r) { return r.ok ? r.json() : []; })
            .then(function (data) { cache = Array.isArray(data) ? data : []; cb(cache); })
            .catch(function () { cb([]); });
    }

    function pageBody() {
        var surface = editorSurface();
        return surface ? surface.querySelector('.page-body[data-visual-edit="1"], .page-body') : null;
    }

    function parseHtmlNodes(doc, html) {
        var tpl = doc.createElement('template');
        tpl.innerHTML = html;
        return Array.prototype.slice.call(tpl.content.childNodes);
    }

    function blockLabel(el) {
        if (!el) return 'this block';
        var h = el.querySelector('h1,h2,h3,h4,h5');
        if (h && h.textContent.trim()) return h.textContent.trim().substring(0, 48);
        if (el.classList.contains('bm-card')) return 'Card';
        if (el.classList.contains('bm-feature')) return 'Feature box';
        if (el.classList.contains('bm-section')) return 'Section';
        if (el.classList.contains('bm-hero')) return 'Hero';
        return 'Block';
    }

    function ensurePlacementDialog() {
        var dlg = document.getElementById('pe-placement-dialog');
        if (dlg) return dlg;

        dlg = document.createElement('div');
        dlg.id = 'pe-placement-dialog';
        dlg.className = 'pe-placement-dialog';
        dlg.hidden = true;
        dlg.innerHTML =
            '<div class="pe-placement-dialog-backdrop"></div>' +
            '<div class="pe-placement-dialog-box" role="dialog">' +
            '  <p class="pe-placement-dialog-title">Where should this go?</p>' +
            '  <p class="pe-placement-dialog-target"></p>' +
            '  <div class="pe-placement-dialog-actions">' +
            '    <button type="button" class="pe-place-btn" data-place="left">Left of block</button>' +
            '    <button type="button" class="pe-place-btn" data-place="right">Right of block</button>' +
            '    <button type="button" class="pe-place-btn" data-place="inside">Inside block</button>' +
            '    <button type="button" class="pe-place-btn pe-place-cancel" data-place="cancel">Cancel</button>' +
            '  </div></div>';

        var wrap = document.querySelector('.page-html-editor-wrap') || document.body;
        wrap.appendChild(dlg);
        return dlg;
    }

    function askPlacement(targetEl, isMove) {
        return new Promise(function (resolve) {
            var dlg = ensurePlacementDialog();
            dlg.querySelector('.pe-placement-dialog-target').textContent =
                'Dropped on: “' + blockLabel(targetEl) + '”';
            dlg.querySelector('.pe-placement-dialog-title').textContent =
                isMove ? 'Move block here?' : 'Place new container here?';

            function done(choice) {
                dlg.hidden = true;
                dlg.querySelectorAll('.pe-place-btn').forEach(function (b) {
                    b.removeEventListener('click', onPick);
                });
                dlg.querySelector('.pe-placement-dialog-backdrop').removeEventListener('click', onCancel);
                resolve(choice);
            }
            function onPick(e) { e.preventDefault(); done(e.currentTarget.getAttribute('data-place')); }
            function onCancel() { done('cancel'); }

            dlg.querySelectorAll('.pe-place-btn').forEach(function (b) { b.addEventListener('click', onPick); });
            dlg.querySelector('.pe-placement-dialog-backdrop').addEventListener('click', onCancel);
            dlg.hidden = false;
        });
    }

    function applyPlacement(target, placement, payload) {
        if (!target || !placement || placement === 'cancel') return false;
        var doc = document;

        if (payload.mode === 'move' && payload.node) {
            var node = payload.node;
            if (node === target || node.contains(target) || target.contains(node)) return false;
            if (placement === 'inside') target.appendChild(node);
            else if (placement === 'left') target.parentNode.insertBefore(node, target);
            else target.parentNode.insertBefore(node, target.nextSibling);
            return true;
        }

        if (payload.mode === 'new' && payload.html) {
            var nodes = parseHtmlNodes(doc, payload.html);
            if (!nodes.length) return false;
            if (placement === 'inside') nodes.forEach(function (n) { target.appendChild(n); });
            else if (placement === 'left') nodes.forEach(function (n) { target.parentNode.insertBefore(n, target); });
            else {
                var ref = target.nextSibling;
                nodes.forEach(function (n) {
                    if (ref) target.parentNode.insertBefore(n, ref);
                    else target.parentNode.appendChild(n);
                });
            }
            return true;
        }
        return false;
    }

    function appendToPage(html) {
        var root = pageBody();
        if (!root || !html) return false;
        root.insertAdjacentHTML('beforeend', html);
        return true;
    }

    function caretRangeAtPoint(x, y) {
        if (document.caretRangeFromPoint) return document.caretRangeFromPoint(x, y);
        if (document.caretPositionFromPoint) {
            var pos = document.caretPositionFromPoint(x, y);
            if (!pos) return null;
            var range = document.createRange();
            range.setStart(pos.offsetNode, pos.offset);
            range.collapse(true);
            return range;
        }
        return null;
    }

    function directChildOfRoot(el, root) {
        var node = el;
        while (node && node !== root && node.parentNode !== root) node = node.parentNode;
        return (node && node.parentNode === root) ? node : null;
    }

    function insertHtmlAtPoint(clientX, clientY, html) {
        var root = pageBody();
        if (!root || !html) return false;

        var el = document.elementFromPoint(clientX, clientY);
        if (!el || !root.contains(el)) return appendToPage(html);

        var child = directChildOfRoot(el, root);
        if (child) {
            var rect = child.getBoundingClientRect();
            var after = clientY > rect.top + rect.height / 2;
            var nodes = parseHtmlNodes(document, html);
            nodes.forEach(function (n) {
                if (after) {
                    if (child.nextSibling) root.insertBefore(n, child.nextSibling);
                    else root.appendChild(n);
                } else {
                    root.insertBefore(n, child);
                }
            });
            return true;
        }

        var range = caretRangeAtPoint(clientX, clientY);
        if (range && root.contains(range.startContainer)) {
            var nodes = parseHtmlNodes(document, html);
            nodes.forEach(function (n) { range.insertNode(n); });
            return true;
        }

        return appendToPage(html);
    }

    function findBlockUnderPoint(x, y, ignoreNode) {
        var surface = editorSurface();
        if (!surface) return null;

        var stack = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [document.elementFromPoint(x, y)];
        for (var i = 0; i < stack.length; i++) {
            var el = stack[i];
            if (!el || !surface.contains(el)) continue;
            if (el.classList && el.classList.contains('pe-drag-bar')) continue;
            if (ignoreNode && (el === ignoreNode || ignoreNode.contains(el) || el.contains(ignoreNode))) continue;
            var block = el.closest ? el.closest(BLOCK_SELECTORS) : null;
            if (block && surface.contains(block)) {
                if (ignoreNode && (block === ignoreNode || ignoreNode.contains(block))) continue;
                return block;
            }
        }
        return null;
    }

    function findNearestBlock(x, y) {
        var root = pageBody();
        if (!root) return null;
        var blocks = root.querySelectorAll(BLOCK_SELECTORS);
        var best = null;
        var bestScore = Infinity;
        Array.prototype.forEach.call(blocks, function (b) {
            var r = b.getBoundingClientRect();
            var dx = x < r.left ? r.left - x : (x > r.right ? x - r.right : 0);
            var dy = y < r.top ? r.top - y : (y > r.bottom ? y - r.bottom : 0);
            var score = dx * dx + dy * dy;
            if (score < bestScore) { bestScore = score; best = b; }
        });
        return best;
    }

    function clearDropMarkers() {
        var surface = editorSurface();
        if (!surface) return;
        surface.querySelectorAll('.pe-drop-on,.pe-drop-active').forEach(function (n) {
            n.classList.remove('pe-drop-on', 'pe-drop-active');
        });
    }

    function syncEditor() {
        if (typeof global.pageEditorSync === 'function') global.pageEditorSync();
    }

    function hasOurDragMime(e) {
        if (!e || !e.dataTransfer || !e.dataTransfer.types) return false;
        var types = e.dataTransfer.types;
        if (typeof types.contains === 'function') return types.contains(DRAG_MIME);
        return Array.prototype.indexOf.call(types, DRAG_MIME) >= 0;
    }

    function resolveDragPayload(e) {
        if (dragState) return dragState;
        if (!hasOurDragMime(e)) return null;

        var token = '';
        try { token = e.dataTransfer.getData(DRAG_MIME) || ''; } catch (err) { token = ''; }

        if (token === 'move') {
            return dragState;
        }

        var html = '';
        try { html = e.dataTransfer.getData(DRAG_HTML_MIME) || ''; } catch (err2) { html = ''; }

        if (!html && token && cache) {
            var item = cache.filter(function (c) { return c.id === token; })[0];
            if (item) html = item.html;
        }

        if (!html) return null;
        return { mode: 'new', html: html, id: token };
    }

    function handleDrop(clientX, clientY, payload) {
        if (!payload) return;

        var ignore = payload.mode === 'move' ? payload.node : null;
        var target = findBlockUnderPoint(clientX, clientY, ignore);

        function finish() {
            dragState = null;
            clearDropMarkers();
            decorateContainers();
            syncEditor();
        }

        if (target) {
            askPlacement(target, payload.mode === 'move').then(function (choice) {
                if (choice && choice !== 'cancel') applyPlacement(target, choice, payload);
                finish();
            });
            return;
        }

        if (payload.mode === 'new' && payload.html) {
            insertHtmlAtPoint(clientX, clientY, payload.html);
        } else if (payload.mode === 'move' && payload.node) {
            var nearest = findNearestBlock(clientX, clientY);
            if (nearest) {
                var rect = nearest.getBoundingClientRect();
                var placement = clientY > rect.top + rect.height / 2 ? 'right' : 'left';
                applyPlacement(nearest, placement, payload);
            }
        }
        finish();
    }

    function markDragData(e, state) {
        e.dataTransfer.setData(DRAG_MIME, state.mode === 'move' ? 'move' : (state.id || 'new'));
        if (state.html) e.dataTransfer.setData(DRAG_HTML_MIME, state.html);
        e.dataTransfer.setData('text/plain', '');
        e.dataTransfer.setData('text/html', '');
        e.dataTransfer.effectAllowed = state.mode === 'move' ? 'move' : 'copy';
    }

    function startNewDrag(item, e) {
        dragState = { mode: 'new', html: item.html, id: item.id };
        if (e) {
            markDragData(e, dragState);
            if (e.dataTransfer.setDragImage) {
                var ghost = document.createElement('div');
                ghost.textContent = item.label;
                ghost.style.cssText = 'position:fixed;left:-9999px;padding:4px 8px;background:#fff;border:1px solid #ccc;';
                document.body.appendChild(ghost);
                e.dataTransfer.setDragImage(ghost, 0, 0);
                setTimeout(function () { document.body.removeChild(ghost); }, 0);
            }
        }
    }

    function startMoveDrag(node, e) {
        dragState = { mode: 'move', node: node };
        if (e) markDragData(e, dragState);
    }

    function isActiveContainerDrag(e) {
        return !!(dragState || hasOurDragMime(e));
    }

    function onDragOver(e) {
        if (!isActiveContainerDrag(e)) return;
        e.preventDefault();
        e.stopPropagation();
        if (e.dataTransfer) {
            e.dataTransfer.dropEffect = (dragState && dragState.mode === 'move') ? 'move' : 'copy';
        }
        clearDropMarkers();
        var ignore = dragState && dragState.mode === 'move' ? dragState.node : null;
        var target = findBlockUnderPoint(e.clientX, e.clientY, ignore);
        if (target) target.classList.add('pe-drop-on');
        else {
            var root = pageBody();
            if (root) root.classList.add('pe-drop-active');
        }
    }

    function onDrop(e) {
        if (dropHandled) return;
        var payload = resolveDragPayload(e);
        if (!payload) return;
        dropHandled = true;
        setTimeout(function () { dropHandled = false; }, 0);
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        handleDrop(e.clientX, e.clientY, payload);
    }

    function blockNativeDrop(e) {
        if (!isActiveContainerDrag(e)) return;
        e.preventDefault();
        e.stopPropagation();
    }

    function bindSurfaceDropHandlers() {
        if (surfaceDropBound) return;
        var surface = editorSurface();
        if (!surface) return;
        surfaceDropBound = true;

        surface.addEventListener('dragover', onDragOver, true);
        surface.addEventListener('drop', onDrop, true);
        surface.addEventListener('dragenter', blockNativeDrop, true);

        document.addEventListener('dragover', function (e) {
            var s = editorSurface();
            if (!s || !s.contains(e.target)) return;
            onDragOver(e);
        }, true);

        document.addEventListener('drop', function (e) {
            var s = editorSurface();
            if (!s || !s.contains(e.target)) return;
            onDrop(e);
        }, true);
    }

    function bindBodyDropHandlers() {
        var root = pageBody();
        if (!root) return;
        if (root.dataset.containerDropBound === '1') return;
        root.dataset.containerDropBound = '1';

        root.addEventListener('dragover', onDragOver, true);
        root.addEventListener('drop', onDrop, true);
        root.addEventListener('dragenter', blockNativeDrop, true);
    }

    function rebindDrop() {
        bindSurfaceDropHandlers();
        bindBodyDropHandlers();
    }

    function decorateContainers() {
        var surface = editorSurface();
        if (!surface) return;

        surface.querySelectorAll('.pe-drag-bar').forEach(function (bar) {
            bar.parentNode.removeChild(bar);
        });

        surface.querySelectorAll(DRAGGABLE_BLOCKS).forEach(function (node) {
            if (node.classList.contains('bm-grid') || node.classList.contains('bm-feature-grid')) return;

            var bar = document.createElement('div');
            bar.className = 'pe-drag-bar';
            bar.setAttribute('contenteditable', 'false');
            bar.setAttribute('draggable', 'true');
            bar.textContent = '\u2630 Drag block';
            node.classList.add('pe-container-target');

            bar.addEventListener('dragstart', function (e) {
                e.stopPropagation();
                startMoveDrag(node, e);
                node.classList.add('pe-is-dragging');
            });
            bar.addEventListener('dragend', function () {
                dragState = null;
                node.classList.remove('pe-is-dragging');
                clearDropMarkers();
            });

            node.insertBefore(bar, node.firstChild);
        });
    }

    function bindPaletteDrag(el, item) {
        el.addEventListener('dragstart', function (e) {
            e.stopPropagation();
            startNewDrag(item, e);
            el.classList.add('is-dragging');
        });
        el.addEventListener('dragend', function () {
            el.classList.remove('is-dragging');
            dragState = null;
        });
    }

    function buildFormatBar(containers) {
        var dragBtn = document.getElementById('page-fmt-container-drag');
        var picker = document.getElementById('page-fmt-container-picker');
        var menu = document.getElementById('page-fmt-container-menu');
        var wrap = document.getElementById('page-fmt-container-wrap');
        if (!dragBtn || !menu || !containers.length) return;

        function setSelected(item) {
            selectedContainer = item;
            var label = dragBtn.querySelector('.page-fmt-container-label');
            if (label) label.textContent = item.label;
        }

        menu.innerHTML = '';
        containers.forEach(function (item) {
            var btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'page-fmt-container-menu-item';
            btn.textContent = item.label;
            btn.addEventListener('click', function (e) {
                e.preventDefault();
                setSelected(item);
                menu.hidden = true;
            });
            menu.appendChild(btn);
        });

        var def = containers.filter(function (c) { return c.id === 'card'; })[0]
            || containers.filter(function (c) { return c.id === 'section'; })[0]
            || containers[0];
        setSelected(def);

        dragBtn.addEventListener('dragstart', function (e) {
            if (!selectedContainer) return;
            e.stopPropagation();
            startNewDrag(selectedContainer, e);
            dragBtn.classList.add('is-dragging');
        });
        dragBtn.addEventListener('dragend', function () {
            dragBtn.classList.remove('is-dragging');
            dragState = null;
        });

        if (picker) {
            picker.addEventListener('click', function (e) {
                e.preventDefault();
                menu.hidden = !menu.hidden;
            });
        }
        document.addEventListener('click', function (e) {
            if (!wrap || menu.hidden || wrap.contains(e.target)) return;
            menu.hidden = true;
        });
    }

    function buildPanel(wrap, containers) {
        var panel = wrap.querySelector('.page-container-panel');
        if (!panel) return;
        var body = panel.querySelector('.page-container-categories');
        if (!body) return;
        body.innerHTML = '';

        var byCat = {};
        containers.forEach(function (c) {
            var cat = c.category || 'Other';
            if (!byCat[cat]) byCat[cat] = [];
            byCat[cat].push(c);
        });

        Object.keys(byCat).sort().forEach(function (cat) {
            var section = document.createElement('div');
            section.className = 'page-container-category';
            var lbl = document.createElement('div');
            lbl.className = 'page-container-category-label';
            lbl.textContent = cat;
            section.appendChild(lbl);

            var list = document.createElement('div');
            list.className = 'page-container-list';
            byCat[cat].forEach(function (item) {
                var chip = document.createElement('div');
                chip.className = 'page-container-chip';
                chip.draggable = true;
                chip.innerHTML = '<span class="page-container-chip-label">' + item.label + '</span>';
                var ins = document.createElement('button');
                ins.type = 'button';
                ins.className = 'page-container-insert-btn';
                ins.textContent = 'Add to end';
                ins.addEventListener('mousedown', function (e) { e.stopPropagation(); });
                ins.addEventListener('click', function (e) {
                    e.preventDefault();
                    e.stopPropagation();
                    appendToPage(item.html);
                    decorateContainers();
                    syncEditor();
                });
                chip.appendChild(ins);
                bindPaletteDrag(chip, item);
                list.appendChild(chip);
            });
            section.appendChild(list);
            body.appendChild(section);
        });
    }

    function init(wrap) {
        wrap = wrap || document.querySelector('.page-html-editor-wrap');
        if (!wrap || wrap.dataset.containersBound) return;
        wrap.dataset.containersBound = '1';
        ensurePlacementDialog();
        rebindDrop();

        var toggle = wrap.querySelector('.page-container-toggle');
        var panel = wrap.querySelector('.page-container-panel');
        if (toggle && panel) {
            toggle.addEventListener('click', function (e) {
                e.preventDefault();
                panel.classList.toggle('is-open');
            });
        }

        loadContainers(function (list) {
            buildPanel(wrap, list);
            buildFormatBar(list);
        });
    }

    global.ComservPageContainers = {
        init: init,
        decorate: function () {
            decorateContainers();
            rebindDrop();
        },
        rebindDrop: rebindDrop
    };
})(typeof window !== 'undefined' ? window : this);