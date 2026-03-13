/**
 * HealthMonitor.js - Client-side monitoring and alerts for CSC Admin
 * 
 * Periodically polls the server health API and displays a prominent warning
 * banner if deterioration or critical failure is detected.
 */

(function() {
    'use strict';

    const CHECK_INTERVAL = 30000; // 30 seconds
    const BANNER_ID = 'system-health-banner';
    let checkTimer = null;

    /**
     * Display a warning banner at the top of the page
     * @param {string} status - 'warning' or 'critical'
     * @param {string[]} issues - List of issues detected
     * @param {string} system - System identifier
     */
    function showBanner(status, issues, system) {
        let banner = document.getElementById(BANNER_ID);
        
        if (!banner) {
            banner = document.createElement('div');
            banner.id = BANNER_ID;
            document.body.prepend(banner);
        }

        const levelClass = status === 'critical' ? 'critical-alert' : 'warning-alert';
        const icon = status === 'critical' ? '🔴' : '⚠️';
        
        banner.className = `health-banner ${levelClass}`;
        banner.innerHTML = `
            <div class="health-banner-content">
                <span class="health-icon">${icon}</span>
                <span class="health-message">
                    <strong>ALERT: [${system}] System Health ${status.toUpperCase()}</strong>
                    <ul>
                        ${issues.map(issue => `<li>${issue}</li>`).join('')}
                    </ul>
                </span>
                <button class="health-banner-close" onclick="this.parentElement.parentElement.remove()">×</button>
            </div>
        `;
    }

    /**
     * Poll the health status API
     */
    async function checkHealth() {
        try {
            const response = await fetch('/admin/health/check');
            if (!response.ok) {
                // Ignore 403 (unauthorized) or other status errors
                if (response.status === 403) return; 
                throw new Error(`HTTP ${response.status}`);
            }

            const data = await response.json();
            
            if (data.status === 'warning' || data.status === 'critical') {
                showBanner(data.status, data.issues, data.system);
                
                // Trigger Web Notification if allowed
                if (Notification.permission === 'granted') {
                    new Notification(`System Alert: ${data.system}`, {
                        body: data.issues.join('\n'),
                        icon: '/static/favicon.ico'
                    });
                }
            } else {
                // If OK, remove any existing banner
                const existingBanner = document.getElementById(BANNER_ID);
                if (existingBanner) existingBanner.remove();
            }
        } catch (error) {
            console.error('[HealthMonitor] Check failed:', error);
        }
    }

    /**
     * Initialize the monitor
     */
    function init() {
        // Request notification permission on first load if admin
        if (Notification.permission === 'default') {
            Notification.requestPermission();
        }

        // Start polling
        checkHealth();
        checkTimer = setInterval(checkHealth, CHECK_INTERVAL);
    }

    // Run when DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
