/**
 * ui.js
 * Universal UI helpers for the entire Comserv application.
 * Includes reusable accordion/toggle functionality.
 */

(function() {
    'use strict';

    /**
     * Toggle visibility of a collapsible section.
     * Works with any element that has an id.
     *
     * @param {string} sectionId - The id of the content div to toggle
     */
    window.toggleSection = function(sectionId) {
        const content = document.getElementById(sectionId);
        if (!content) return;

        if (content.style.display === 'none' || content.style.display === '') {
            content.style.display = 'block';
        } else {
            content.style.display = 'none';
        }
    };

    /**
     * Toggle the AI Editor right dock panel.
     * Loads AI content into #aew-right-dock if not already present.
     */
    window.toggleAIEditorRightPanel = function() {
        const dock = document.getElementById('aew-right-dock');
        if (!dock) return;

        if (document.body.classList.contains('aew-right-open')) {
            document.body.classList.remove('aew-right-open');
            return;
        }

        document.body.classList.add('aew-right-open');
        if (window.AEW && typeof window.AEW.open === 'function') {
            window.AEW.open({ mode: 'right' });
        }
    };

    // =====================================================
    // Reusable panel / sidebar / editor mounting helpers
    // (used by AI2 Editor widget and other modules)
    // =====================================================

    /**
     * Mount a sidebar panel into a container.
     * @param {string} containerId
     * @param {string} panelId
     */
    window.mountSidebarPanel = function(containerId, panelId) {
        const container = document.getElementById(containerId);
        const panel = document.getElementById(panelId);
        if (!container || !panel) return;
        container.innerHTML = '';
        container.appendChild(panel);
        panel.style.display = 'block';
    };

    /**
     * Show/hide a group of panels.
     * @param {string} containerId
     * @param {string} activePanelId
     */
    window.togglePanelGroup = function(containerId, activePanelId) {
        const container = document.getElementById(containerId);
        if (!container) return;
        Array.from(container.children).forEach(el => {
            el.style.display = (el.id === activePanelId) ? 'block' : 'none';
        });
    };

    /**
     * Mount an editor container (used by AI2Editor).
     * @param {string} containerId
     * @param {string} editorType
     */
    window.mountEditor = function(containerId, editorType = 'ace') {
        const container = document.getElementById(containerId);
        if (!container) return;
        container.dataset.editorType = editorType;
        // Actual editor creation is handled by AI2EditorCore
    };

})();