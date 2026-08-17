// static/js/ai2editor/sidebar-toggle.js
// Wires the AI2 editor left sidebar icons to their corresponding panels.
// Single-open behaviour: clicking an icon opens its panel (and the panel
// container); clicking the already-open icon (or another icon) switches/closes.
// Fires a 'ai2:panel-open' CustomEvent so other modules (e.g. git-review.js)
// can lazily populate when their panel becomes visible.
(function () {
    'use strict';

    function getPanel(name) { return document.getElementById('panel-' + name); }
    function getIcon(name) {
        return document.querySelector('.sidebar-icon[data-panel="' + name + '"]');
    }
    function hideAll() {
        var panels = document.querySelectorAll('.sidebar-panel');
        for (var i = 0; i < panels.length; i++) panels[i].style.display = 'none';
        var icons = document.querySelectorAll('.sidebar-icon');
        for (var j = 0; j < icons.length; j++) icons[j].classList.remove('active');
    }

    function togglePanel(name) {
        var container = document.getElementById('sidebar-panels');
        var panel = getPanel(name);
        var icon = getIcon(name);
        if (!panel) return;

        var wasOpen = (panel.style.display !== 'none') &&
                      container && (container.style.display !== 'none');

        hideAll();

        if (wasOpen) {
            if (container) container.style.display = 'none';
            // The editor reclaims the space automatically (flex layout).
            document.dispatchEvent(new CustomEvent('ai2:panel-close'));
            return;
        }

        panel.style.display = 'block';
        if (container) container.style.display = 'block';
        if (icon) icon.classList.add('active');
        try {
            document.dispatchEvent(new CustomEvent('ai2:panel-open', { detail: { panel: name } }));
        } catch (e) { /* CustomEvent unsupported — non-fatal */ }
    }

    // NOTE: the left panel is a flex child of .main, so opening/closing it
    // reclaims editor space automatically — no manual margin pushing needed.

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
            var w = Math.max(160, Math.min(e.clientX - baseX, 600));
            container.style.width = w + 'px';
        });
        document.addEventListener('mouseup', function () {
            if (!dragging) return;
            dragging = false;
            document.body.style.userSelect = '';
            // Re-layout the editor now the panel has a new width (flex handles
            // the editor reclaim automatically; just tell Ace to resize).
            if (window.AI2EditorCore && typeof window.AI2EditorCore.resizeEditor === 'function') {
                window.AI2EditorCore.resizeEditor();
            }
            document.dispatchEvent(new CustomEvent('ai2:panel-resize'));
        });
    }

    function wire() {
        var icons = document.querySelectorAll('.sidebar-icon');
        for (var i = 0; i < icons.length; i++) {
            (function (ic) {
                var name = ic.getAttribute('data-panel');
                if (!name) return;
                ic.addEventListener('click', function () { togglePanel(name); });
            })(icons[i]);
        }
        wireResize();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', wire);
    } else {
        wire();
    }

    console.log('%c[AI2] sidebar-toggle ready', 'color:#0a0');
})();
