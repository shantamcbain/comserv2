/**
 * planning/daily-plan-gantt.js
 * Gantt chart for /planning/daily page
 * Reads project data from <script id="gantt-data" type="application/json">
 * Extracted from inline <script> in DailyPlan.tt — modular load via js_load.tt
 */
(function() {
    'use strict';

    var dataScript = document.getElementById('gantt-data');
    if (!dataScript) return;

    var projects;
    try { projects = JSON.parse(dataScript.textContent); }
    catch(e) { console.warn('[Gantt] Invalid project data:', e); return; }

    if (!projects || !projects.length) return;

    var now = new Date();
    var windowStart = new Date(now);
    windowStart.setMonth(windowStart.getMonth() - 3);
    var windowEnd = new Date(now);
    windowEnd.setMonth(windowEnd.getMonth() + 9);
    var totalMs = windowEnd - windowStart;

    var statusColor = {
        'In-Process': '#17a2b8',
        'active':     '#17a2b8',
        'Completed':  '#28a745',
        'completed':  '#28a745',
        'On Hold':    '#dc3545',
        'paused':     '#dc3545'
    };

    function toDate(s) { return s ? new Date(s) : null; }
    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }
    function pct(d) { return clamp(((d - windowStart) / totalMs) * 100, 0, 100); }

    // Build month-label header
    var header = '<div style="display:flex;font-size:0.7em;color:var(--text-muted-color);margin-bottom:4px;padding-left:200px;">';
    var m = new Date(windowStart);
    m.setDate(1);
    while (m <= windowEnd) {
        var leftPct = pct(m);
        header += '<div style="position:absolute;left:calc(200px + ' + leftPct + '%);transform:translateX(-50%);white-space:nowrap;">'
                 + m.toLocaleString('default',{month:'short'}) + ' ' + m.getFullYear() + '</div>';
        m.setMonth(m.getMonth() + 1);
    }
    header += '</div>';

    var todayPct = pct(now);
    var rows = '';
    var grouped = {};

    projects.forEach(function(p) {
        var s = p.sitename || 'Other';
        if (!grouped[s]) grouped[s] = [];
        grouped[s].push(p);
    });

    Object.keys(grouped).sort().forEach(function(site) {
        if (projects.length > 1 && Object.keys(grouped).length > 1) {
            rows += '<div style="font-size:0.78em;font-weight:bold;padding:6px 0 2px;color:var(--text-muted-color);">🌐 ' + site + '</div>';
        }
        grouped[site].forEach(function(p) {
            var sd = toDate(p.start_date);
            var ed = toDate(p.end_date);
            var barColor = statusColor[p.status] || '#6c757d';

            var barLeft  = sd ? pct(sd) : pct(now) - 1;
            var barRight = ed ? pct(ed) : pct(now) + 2;
            if (!sd && !ed) { barLeft = todayPct - 0.5; barRight = todayPct + 2; }
            if (barRight <= barLeft) barRight = barLeft + 2;
            var barWidth = barRight - barLeft;

            var dateLabel = (p.start_date || '?') + ' → ' + (p.end_date || 'ongoing');

            rows += '<div style="display:flex;align-items:center;margin-bottom:5px;height:24px;">'
                  + '<div style="width:200px;flex-shrink:0;font-size:0.8em;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;padding-right:8px;">'
                  + '<a href="/project/details?project_id=' + p.id + '" style="color:var(--text-color);text-decoration:none;" title="' + p.name + '">' + p.name + '</a>'
                  + '</div>'
                  + '<div style="flex:1;position:relative;height:18px;background:var(--bg-secondary);border-radius:3px;">'
                  + '<div style="position:absolute;left:' + todayPct + '%;top:0;bottom:0;width:2px;background:var(--primary-color);opacity:0.5;"></div>'
                  + '<div style="position:absolute;left:' + barLeft + '%;width:' + barWidth + '%;height:100%;background:' + barColor + ';border-radius:3px;opacity:0.85;" title="' + p.name + ': ' + dateLabel + '"></div>'
                  + '</div>'
                  + '</div>';
        });
    });

    var container = document.getElementById('gantt-chart');
    if (container) {
        container.style.position = 'relative';
        container.innerHTML = header + rows;
    }
})();