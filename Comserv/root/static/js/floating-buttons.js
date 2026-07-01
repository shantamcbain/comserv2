/**
 * floating-buttons.js
 * Centralized floating buttons for the entire Comserv application.
 * Includes:
 *   - Back to Top button
 *   - AI2 Code Editor button (✏️)
 *
 * Buttons are automatically hidden on popup / no-wrapper pages.
 */

(function() {
    'use strict';

    const NS = 'FloatingButtons';

    /**
     * Detect if current page is a popup / detached widget.
     * We skip floating buttons on these pages.
     */
    function isPopupPage() {
        const uri = window.location.pathname;
        // Known popup routes
        if (uri.includes('/ai2/editing_widget_popup')) return true;
        if (uri.includes('/ai/editing_widget_popup')) return true;
        if (uri.includes('/editing_widget_popup')) return true;
        // Any page that uses no_wrapper (bare fragment)
        if (document.body && document.body.children.length < 5) return true;
        return false;
    }

    /**
     * Create and inject the Back to Top button.
     */
    function createBackToTopButton() {
        if (document.getElementById('back-to-top')) return; // already exists

        const btn = document.createElement('button');
        btn.id = 'back-to-top';
        btn.title = 'Back to Top';
        btn.setAttribute('aria-label', 'Back to Top');
        btn.innerHTML = '<i class="fas fa-arrow-up" aria-hidden="true"></i>';
        btn.style.cssText = 'position:fixed;bottom:20px;right:20px;z-index:9999;display:none;';
        document.body.appendChild(btn);

        // Show on scroll
        window.addEventListener('scroll', () => {
            btn.style.display = (window.scrollY > 300) ? 'block' : 'none';
        });

        btn.addEventListener('click', () => {
            window.scrollTo({ top: 0, behavior: 'smooth' });
        });

        console.log(`[${NS}] Back to Top button created`);
    }

    /**
     * Create and inject the AI2 Code Editor floating button.
     */
    function createAI2EditorButton() {
        if (document.getElementById('ai2-code-btn')) return; // already exists

        const container = document.createElement('div');
        container.id = 'ai2-code-btn';
        container.style.cssText = 'position:fixed;bottom:80px;left:20px;z-index:9999;';

        const btn = document.createElement('button');
        btn.id = 'ai2-open-editor-btn';
        btn.style.cssText = 'background:#313335;color:#bbb;border:1px solid #555;padding:10px 8px;cursor:pointer;transition:all .15s ease;border-radius:50%;width:48px;height:48px;font-size:1.4em;box-shadow:0 2px 8px rgba(0,0,0,0.3);';
        btn.textContent = '✏️';

        btn.addEventListener('click', () => {
            window.open('/ai2/editing_widget_popup', 'AIEditor',
                'width=1400,height=900,resizable=yes,scrollbars=yes');
        });

        container.appendChild(btn);
        document.body.appendChild(container);

        console.log(`[${NS}] AI2 Editor floating button created`);
    }

    /**
     * Initialize all floating buttons (only on non-popup pages).
     */
    function initFloatingButtons() {
        if (isPopupPage()) {
            console.log(`[${NS}] Popup page detected — skipping floating buttons`);
            return;
        }

        createBackToTopButton();
        createAI2EditorButton();

        console.log(`[${NS}] All floating buttons initialized`);
    }

    // Boot
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initFloatingButtons);
    } else {
        initFloatingButtons();
    }

})();