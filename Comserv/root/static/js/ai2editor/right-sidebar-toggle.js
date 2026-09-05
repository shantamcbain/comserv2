// static/js/ai2editor/right-sidebar-toggle.js
// PyCharm-like right tool strip: Chat + Diff.
// Chat toggles #ai-chat-sidebar (via AI2EditorChat when available).
// Diff toggles #editor-right-rail visibility. Also wires rail resize.
(function () {
    'use strict';

    function chatApi() {
        return window.AI2EditorChat || window.AI2Chat || null;
    }

    function setChatIconActive(open) {
        var icon = document.querySelector('#right-sidebar-icons .sidebar-icon[data-right-panel="chat"]');
        if (!icon) return;
        if (open) icon.classList.add('active');
        else icon.classList.remove('active');
    }

    function setDiffIconActive(open) {
        var icon = document.querySelector('#right-sidebar-icons .sidebar-icon[data-right-panel="diff"]');
        if (!icon) return;
        if (open) icon.classList.add('active');
        else icon.classList.remove('active');
    }

    function isRailVisible() {
        var rail = document.getElementById('editor-right-rail');
        if (!rail) return false;
        return rail.style.display !== 'none' && rail.getAttribute('data-right-closed') !== '1';
    }

    function setRailVisible(show) {
        var rail = document.getElementById('editor-right-rail');
        if (!rail) return;
        if (show) {
            rail.style.display = 'flex';
            rail.removeAttribute('data-right-closed');
        } else {
            rail.style.display = 'none';
            rail.setAttribute('data-right-closed', '1');
        }
        setDiffIconActive(show);
        if (window.AI2EditorCore && typeof window.AI2EditorCore.resizeEditor === 'function') {
            window.AI2EditorCore.resizeEditor();
        }
    }

    function toggleChat() {
        var api = chatApi();
        var sidebar = document.getElementById('ai-chat-sidebar');
        if (api && typeof api.setClosed === 'function') {
            var closed = typeof api.isClosed === 'function' ? api.isClosed() : false;
            // If detached, treat strip click as re-attach+open when closed/detached hide.
            if (typeof api.isDetached === 'function' && api.isDetached()) {
                if (typeof api.reattach === 'function') api.reattach();
                api.setClosed(false);
                setChatIconActive(true);
                return;
            }
            api.setClosed(!closed);
            setChatIconActive(closed); // was closed -> now open
            return;
        }
        // Fallback without chat API: toggle display directly.
        if (!sidebar) return;
        var hidden = sidebar.style.display === 'none';
        sidebar.style.display = hidden ? 'flex' : 'none';
        var reopen = document.getElementById('ai-chat-reopen');
        if (reopen) reopen.style.display = hidden ? 'none' : 'block';
        setChatIconActive(hidden);
        if (window.AI2EditorCore && typeof window.AI2EditorCore.resizeEditor === 'function') {
            window.AI2EditorCore.resizeEditor();
        }
    }

    function toggleDiff() {
        setRailVisible(!isRailVisible());
    }

    function syncFromChat() {
        var api = chatApi();
        var open = true;
        if (api && typeof api.isClosed === 'function') {
            open = !api.isClosed() && !(typeof api.isDetached === 'function' && api.isDetached());
        } else {
            var sidebar = document.getElementById('ai-chat-sidebar');
            open = !!(sidebar && sidebar.style.display !== 'none');
        }
        setChatIconActive(open);
    }

    function wireRailResize() {
        var rail = document.getElementById('editor-right-rail');
        if (!rail) return;
        if (rail.querySelector('.rail-resize-handle')) return;

        var handle = document.createElement('div');
        handle.className = 'rail-resize-handle';
        handle.title = 'Drag to resize diff rail';
        handle.style.cssText = 'position:absolute;left:-3px;top:0;bottom:0;width:6px;' +
            'cursor:col-resize;z-index:20;background:transparent;';
        rail.appendChild(handle);

        var dragging = false;
        handle.addEventListener('mousedown', function (e) {
            dragging = true;
            e.preventDefault();
            document.body.style.userSelect = 'none';
        });
        document.addEventListener('mousemove', function (e) {
            if (!dragging) return;
            var rect = rail.getBoundingClientRect();
            // Dragging the left edge: width = right - mouseX
            var w = Math.max(200, Math.min(rect.right - e.clientX, window.innerWidth * 0.7));
            rail.style.flex = '0 0 ' + w + 'px';
            rail.style.width = w + 'px';
            rail.style.minWidth = Math.min(200, w) + 'px';
        });
        document.addEventListener('mouseup', function () {
            if (!dragging) return;
            dragging = false;
            document.body.style.userSelect = '';
            if (window.AI2EditorCore && typeof window.AI2EditorCore.resizeEditor === 'function') {
                window.AI2EditorCore.resizeEditor();
            }
            document.dispatchEvent(new CustomEvent('ai2:rail-resize'));
        });
    }

    function wire() {
        var icons = document.querySelectorAll('#right-sidebar-icons .sidebar-icon[data-right-panel]');
        for (var i = 0; i < icons.length; i++) {
            (function (ic) {
                var name = ic.getAttribute('data-right-panel');
                ic.addEventListener('click', function () {
                    if (name === 'chat') toggleChat();
                    else if (name === 'diff') toggleDiff();
                });
            })(icons[i]);
        }
        wireRailResize();
        // Default: chat open, Diff tool tab closed (open on demand).
        syncFromChat();
        setRailVisible(false);

        document.addEventListener('ai2:chat-view', function () { syncFromChat(); });
    }

    function openDiff() { setRailVisible(true); }
    function closeDiff() { setRailVisible(false); }

    window.AI2RightSidebar = {
        openDiff: openDiff,
        closeDiff: closeDiff,
        toggleDiff: toggleDiff,
        isDiffOpen: isRailVisible,
        setRailVisible: setRailVisible
    };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', wire);
    } else {
        wire();
    }

    console.log('%c[AI2] right-sidebar-toggle ready', 'color:#0a0');
})();
