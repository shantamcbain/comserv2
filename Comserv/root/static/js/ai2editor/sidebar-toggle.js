// static/js/ai2editor/sidebar-toggle.js
// Wires the AI2 editor left sidebar icons to their corresponding panels.
// Single-open behaviour: clicking an icon opens its panel (and the panel
// container); clicking the already-open icon (or another icon) switches/closes.
// Fires a 'ai2:panel-open' CustomEvent so other modules (e.g. git-review.js)
// can lazily populate when their panel becomes visible.
//
// Per-panel preferred widths: opening a panel applies its default (or last
// user-resized) width. Drag max is 900px so the Git dashboard has room.
(function () {
    'use strict';

    var MIN_W = 160;
    var MAX_W = 900;

    // Preferred defaults when a panel is first opened in the session.
    var _defaultWidths = {
        projects: 260,
        git: 520,
        terminal: 320,
        review: 360,
        hermes: 440,
        settings: 280
    };

    // Last user-resized width per panel (session-only).
    var _panelWidths = {};
    var _openPanel = null;

    function getPanel(name) { return document.getElementById('panel-' + name); }
    function getIcon(name) {
        return document.querySelector('#sidebar-icons .sidebar-icon[data-panel="' + name + '"]');
    }
    function hideAll() {
        var panels = document.querySelectorAll('.sidebar-panel');
        for (var i = 0; i < panels.length; i++) panels[i].style.display = 'none';
        var icons = document.querySelectorAll('#sidebar-icons .sidebar-icon');
        for (var j = 0; j < icons.length; j++) icons[j].classList.remove('active');
    }

    function applyWidthFor(name) {
        var container = document.getElementById('sidebar-panels');
        if (!container || !name) return;
        var w = _panelWidths[name] || _defaultWidths[name] || 220;
        container.style.width = w + 'px';
    }

    function styleOpenPanel(name, panel, container) {
        if (!panel) return;
        if (name === 'git') {
            panel.style.display = 'flex';
            panel.style.flexDirection = 'column';
            panel.style.height = '100%';
            panel.style.overflow = 'hidden';
            if (container) {
                container.style.overflow = 'hidden';
                container.style.display = 'flex';
                container.style.flexDirection = 'column';
            }
        } else {
            panel.style.display = 'block';
            panel.style.flexDirection = '';
            panel.style.height = '';
            panel.style.overflow = '';
            if (container) {
                container.style.overflow = 'auto';
                container.style.display = 'block';
                container.style.flexDirection = '';
            }
        }
    }

    function openPanel(name) {
        var container = document.getElementById('sidebar-panels');
        var panel = getPanel(name);
        var icon = getIcon(name);
        if (!panel) return;

        if (_openPanel === name && container && container.style.display !== 'none'
            && panel.style.display !== 'none') {
            return;
        }

        hideAll();
        applyWidthFor(name);
        _openPanel = name;
        styleOpenPanel(name, panel, container);
        if (container && container.style.display === 'none') {
            // styleOpenPanel already set display for git; ensure visible for others
            if (name !== 'git') container.style.display = 'block';
        }
        if (icon) icon.classList.add('active');
        try {
            document.dispatchEvent(new CustomEvent('ai2:panel-open', { detail: { panel: name } }));
        } catch (e) { /* CustomEvent unsupported — non-fatal */ }
        if (window.AI2EditorCore && typeof window.AI2EditorCore.resizeEditor === 'function') {
            window.AI2EditorCore.resizeEditor();
        }
    }

    function closePanel(name) {
        var container = document.getElementById('sidebar-panels');
        if (name && _openPanel && _openPanel !== name) {
            // Closing a panel that is not the open one — no-op.
            var panel = getPanel(name);
            if (!panel || panel.style.display === 'none') return;
        }
        hideAll();
        if (container) {
            container.style.display = 'none';
            container.style.overflow = 'auto';
            container.style.flexDirection = '';
        }
        _openPanel = null;
        document.dispatchEvent(new CustomEvent('ai2:panel-close'));
        if (window.AI2EditorCore && typeof window.AI2EditorCore.resizeEditor === 'function') {
            window.AI2EditorCore.resizeEditor();
        }
    }

    function togglePanel(name) {
        var container = document.getElementById('sidebar-panels');
        var panel = getPanel(name);
        if (!panel) return;

        var wasOpen = (_openPanel === name) &&
                      container && (container.style.display !== 'none') &&
                      (panel.style.display !== 'none');

        if (wasOpen) {
            closePanel(name);
            return;
        }
        openPanel(name);
    }

    // Make the left sidebar panel container resizable from its right edge.
    function wireResize() {
        var container = document.getElementById('sidebar-panels');
        if (!container) return;
        if (container.querySelector('.sidebar-resize-handle')) return;

        var handle = document.createElement('div');
        handle.className = 'sidebar-resize-handle';
        handle.style.cssText = 'position:absolute;top:0;right:-3px;width:6px;height:100%;' +
            'cursor:col-resize;z-index:20;background:transparent;';
        handle.title = 'Drag to resize panel';
        container.appendChild(handle);

        var dragging = false;
        handle.addEventListener('mousedown', function (e) {
            dragging = true;
            e.preventDefault();
            document.body.style.userSelect = 'none';
            if (container) container.style.transition = 'none';
        });
        document.addEventListener('mousemove', function (e) {
            if (!dragging) return;
            var sidebar = document.getElementById('sidebar-icons');
            var baseX = sidebar ? sidebar.getBoundingClientRect().right : 56;
            var w = Math.max(MIN_W, Math.min(e.clientX - baseX, MAX_W));
            container.style.width = w + 'px';
        });
        document.addEventListener('mouseup', function () {
            if (!dragging) return;
            dragging = false;
            document.body.style.userSelect = '';
            // Persist width for the currently open panel.
            if (_openPanel) {
                var w = parseInt(container.style.width, 10);
                if (w && !isNaN(w)) _panelWidths[_openPanel] = w;
            }
            if (window.AI2EditorCore && typeof window.AI2EditorCore.resizeEditor === 'function') {
                window.AI2EditorCore.resizeEditor();
            }
            document.dispatchEvent(new CustomEvent('ai2:panel-resize'));
        });
    }

    function wire() {
        var icons = document.querySelectorAll('#sidebar-icons .sidebar-icon');
        for (var i = 0; i < icons.length; i++) {
            (function (ic) {
                var name = ic.getAttribute('data-panel');
                if (!name) return;
                ic.addEventListener('click', function () { togglePanel(name); });
            })(icons[i]);
        }
        wireResize();
    }

    // Public API for git-panel.js (detach closes / attach reopens).
    window.AI2Sidebar = {
        togglePanel: togglePanel,
        openPanel: openPanel,
        closePanel: closePanel,
        getOpenPanel: function () { return _openPanel; }
    };

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', wire);
    } else {
        wire();
    }

    console.log('%c[AI2] sidebar-toggle ready', 'color:#0a0');
})();
