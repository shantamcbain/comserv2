/**
 * HealthMonitor.js - Client-side monitoring and alerts for CSC Admin
 *
 * Periodically polls /admin/health/check and:
 *  - Displays a sticky in-page banner on every page an admin visits
 *  - Fires a browser system notification when status transitions to warning/critical
 *
 * Loaded via Header.tt only when is_admin is true, so it runs on every page
 * the logged-in admin opens (regardless of which URL they are on).
 */

(function() {
    'use strict';

    const CHECK_INTERVAL  = 30000; // 30 seconds
    const BANNER_ID       = 'system-health-banner';
    let   lastStatus      = 'ok';  // track transitions to avoid notification spam

    // ── URL helpers ──────────────────────────────────────────────────────────
    function auditUrl(system, level) {
        const enc    = encodeURIComponent;
        const base   = '/admin/logging/audit';
        const params = [];
        if (system) params.push('system=' + enc(system));
        if (level)  params.push('level='  + enc(level));
        return params.length ? base + '?' + params.join('&') : base;
    }

    // ── In-page banner ───────────────────────────────────────────────────────
    function showBanner(data) {
        let banner = document.getElementById(BANNER_ID);
        if (!banner) {
            banner = document.createElement('div');
            banner.id = BANNER_ID;
            document.body.prepend(banner);
        }

        const overallStatus = data.status;
        const levelClass    = overallStatus === 'critical' ? 'critical-alert' : 'warning-alert';
        const icon          = overallStatus === 'critical' ? '🔴' : '⚠️';

        // Local issues (DB ping, etc.)
        const localItems = (data.issues || []).map(msg => {
            const url = auditUrl(data.system, 'CRITICAL');
            return `<li><a href="${url}" style="color:#fff;font-weight:bold;text-decoration:underline;">[${data.system}] ${msg}</a></li>`;
        }).join('');

        // Per-server alerts from every system in the shared DB
        const serverItems = (data.server_alerts || []).map(sa => {
            const lvl = sa.level === 'critical' ? 'CRITICAL' : 'ERROR';
            const url = auditUrl(sa.system, lvl);
            const ts  = sa.latest ? ` — last: ${sa.latest}` : '';
            return `<li><a href="${url}" style="color:#fff;font-weight:bold;text-decoration:underline;">[${sa.system}] ${sa.message}${ts}</a></li>`;
        }).join('');

        const allItems    = localItems + serverItems;
        const systemCount = (data.server_alerts || []).length;
        const headline    = systemCount > 1
            ? `${systemCount} servers have recent errors`
            : `System Health ${overallStatus.toUpperCase()}`;

        banner.className = `health-banner ${levelClass}`;
        banner.innerHTML = `
            <div class="health-banner-content">
                <span class="health-icon">${icon}</span>
                <span class="health-message">
                    <strong>
                        <a href="${auditUrl('', 'ERROR')}" style="color:#fff;text-decoration:underline;">
                            ALERT: ${headline}
                        </a>
                    </strong>
                    <ul style="margin:4px 0 0 0;padding-left:18px;">${allItems}</ul>
                </span>
                <span class="health-banner-links" style="display:flex;gap:8px;align-items:center;flex-shrink:0;">
                    <a href="${auditUrl('', 'ERROR')}"
                       style="color:#fff;text-decoration:underline;font-size:0.85em;white-space:nowrap;"
                       title="View all recent errors">📋 All Errors</a>
                    <a href="/admin/logging/audit"
                       style="color:#fff;text-decoration:underline;font-size:0.85em;white-space:nowrap;"
                       title="Open log audit dashboard">🩺 Log Audit</a>
                </span>
                <button class="health-banner-close" onclick="this.parentElement.parentElement.remove()">×</button>
            </div>
        `;
    }

    function removeBanner() {
        const b = document.getElementById(BANNER_ID);
        if (b) b.remove();
    }

    // ── Browser system notification ──────────────────────────────────────────
    function fireNotification(data) {
        if (!('Notification' in window)) return;
        if (Notification.permission !== 'granted') return;

        const systemCount = (data.server_alerts || []).length;
        const title = systemCount > 1
            ? `🔴 ${systemCount} servers have errors`
            : `🔴 System Health ${data.status.toUpperCase()}`;

        const lines = [
            ...(data.issues || []).map(m => `[${data.system}] ${m}`),
            ...(data.server_alerts || []).map(sa => `[${sa.system}] ${sa.message}`),
        ];

        new Notification(title, {
            body : lines.join('\n') || 'Check the admin log audit for details.',
            icon : '/static/favicon.ico',
            tag  : 'comserv-health',   // replaces previous notification instead of stacking
            requireInteraction: true,   // stays until dismissed
        });
    }

    // ── Main poll ────────────────────────────────────────────────────────────
    async function checkHealth() {
        try {
            const response = await fetch('/admin/health/check');
            if (!response.ok) {
                if (response.status === 403) return;
                throw new Error('HTTP ' + response.status);
            }

            const data = await response.json();

            if (data.status === 'warning' || data.status === 'critical') {
                showBanner(data);

                // Only fire a browser notification when status transitions
                // (ok → warning/critical, or warning → critical) to avoid spam
                if (lastStatus !== data.status) {
                    fireNotification(data);
                }
            } else {
                removeBanner();
            }

            lastStatus = data.status;

        } catch (err) {
            console.error('[HealthMonitor] Check failed:', err);
        }
    }

    // ── Initialisation ───────────────────────────────────────────────────────
    async function init() {
        // Request browser notification permission before the first poll so
        // the user sees the OS prompt while we're still on the page.
        if ('Notification' in window && Notification.permission === 'default') {
            try {
                await Notification.requestPermission();
            } catch (e) {
                // Some browsers throw if called outside a user gesture — ignore
            }
        }

        // Run immediately, then every 30 s
        await checkHealth();
        setInterval(checkHealth, CHECK_INTERVAL);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
