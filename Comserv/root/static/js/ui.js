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

        // If AI editor already open, close it
        if (document.body.classList.contains('aew-right-open')) {
            document.body.classList.remove('aew-right-open');
            return;
        }

        // If AEW global exists, use it
        if (window.AEW && typeof window.AEW.open === 'function') {
            window.AEW.open({ mode: 'right' });
        } else {
            // Fallback: fetch the AI editor popup content
            fetch('/ai2/editing_widget_popup')
                .then(r => r.text())
                .then(html => {
                    dock.innerHTML = html;
                    document.body.classList.add('aew-right-open');
                })
                .catch(() => {
                    // Final fallback: open popup window
                    window.open('/ai2/editing_widget_popup', 'AIEditor', 'width=1400,height=900,resizable=yes,scrollbars=yes');
                });
        }
    };

})();