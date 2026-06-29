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

    // Optional: expose a more advanced version later if needed
    // window.toggleSectionWithChevron = function(sectionId, chevronId) { ... };

})();