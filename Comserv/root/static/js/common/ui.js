/**
 * common/ui.js
 * Shared UI helpers used across the application.
 * Loaded via js_load.tt (defer)
 */
(function() {
    'use strict';

    window.ComservUI = window.ComservUI || {};

    /**
     * Toggle visibility of a section by ID.
     */
    window.ComservUI.toggleSection = function(id) {
        const el = document.getElementById(id);
        if (!el) return;
        el.style.display = (el.style.display === 'none' || el.style.display === '') ? 'block' : 'none';
    };

    /**
     * Mount a sidebar panel (placeholder for future reusable panels).
     */
    window.ComservUI.mountSidebarPanel = function(containerId, content) {
        const container = document.getElementById(containerId);
        if (!container) return;
        container.innerHTML = content;
    };

    /**
     * Placeholder for editor mounting (AI2 editor adapters will override/extend).
     */
    window.ComservUI.mountEditor = function(containerId, options) {
        console.log('[ComservUI] mountEditor called for', containerId, options);
        // Real implementation lives in ai2editor/ adapters
    };

    console.log('[ComservUI] common/ui.js loaded');
})();