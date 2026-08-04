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
            return;
        }

        panel.style.display = 'block';
        if (container) container.style.display = 'block';
        if (icon) icon.classList.add('active');
        try {
            document.dispatchEvent(new CustomEvent('ai2:panel-open', { detail: { panel: name } }));
        } catch (e) { /* CustomEvent unsupported — non-fatal */ }
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
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', wire);
    } else {
        wire();
    }

    console.log('%c[AI2] sidebar-toggle ready', 'color:#0a0');
})();
