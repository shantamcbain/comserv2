/**
 * hardware-monitor.js — V2-compliant client logic for /admin/hardware_monitor.
 *
 * Replaces the inline <script> blocks that previously lived in index.tt.
 * Chart data is read from the <script type="application/json" id="hw-chart-data">
 * block (embedded as JSON, not executable JS). Auto-refresh is wired to the
 * #hw-refresh-sel <select>. No inline script in the template; loaded via
 * js_load.tt under a /admin/hardware_monitor conditional with `defer`.
 */

(function () {
    'use strict';

    // ── Auto-refresh (select-driven) ───────────────────────────────────────
    function initAutoRefresh() {
        var sel = document.getElementById('hw-refresh-sel');
        var cd  = document.getElementById('hw-refresh-countdown');
        if (!sel) return;

        var timer = null, countdown = 0;
        function start(secs) {
            if (timer) { clearInterval(timer); timer = null; }
            if (!secs) { if (cd) cd.textContent = ''; return; }
            countdown = secs;
            if (cd) cd.textContent = 'Refresh in ' + countdown + 's';
            timer = setInterval(function () {
                countdown--;
                if (countdown <= 0) { location.reload(); }
                else if (cd) { cd.textContent = 'Refresh in ' + countdown + 's'; }
            }, 1000);
        }
        sel.addEventListener('change', function () { start(parseInt(sel.value, 10) || 0); });
        start(parseInt(sel.value, 10) || 0);
    }

    // ── Charts ───────────────────────────────────────────────────────────────
    function renderCharts() {
        var dataEl = document.getElementById('hw-chart-data');
        var container = document.getElementById('charts-container');
        if (!dataEl || !container) return;

        var rawData;
        try {
            rawData = JSON.parse(dataEl.textContent);
        } catch (e) {
            container.innerHTML = '<p class="muted" style="color:#c00">Chart data parse error: ' + e.message + '</p>';
            return;
        }
        if (!Array.isArray(rawData)) rawData = [];

        container.innerHTML = '';

        var COLORS = ['#2196f3','#f44336','#4caf50','#ff9800','#9c27b0','#00bcd4','#795548','#607d8b'];
        var HOST_COLORS = {
            'workstation':        '#2196f3',
            'comserv':            '#4caf50',
            'proxmox720':         '#ff9800',
            'proxmoxt210':        '#9c27b0',
            'comservproduction1': '#f44336',
            'production':         '#f44336'
        };

        function hostColor(label) {
            var short = label.replace(/\.computersystemconsulting\.ca$/, '').replace(/\..*$/, '');
            var prefix = short.split(/\s*\u2013\s*/)[0].trim();
            if (HOST_COLORS[prefix]) return HOST_COLORS[prefix];
            var fallback = 0;
            for (var i = 0; i < prefix.length; i++) fallback += prefix.charCodeAt(i);
            return COLORS[fallback % COLORS.length];
        }
        function tsToMs(ts) { return new Date(ts.replace(' ', 'T')).getTime(); }

        function makeDatasets(hostMap) {
            return Object.keys(hostMap).sort().map(function (host) {
                var color = hostColor(host);
                return {
                    label: host,
                    data: hostMap[host].map(function (pt) { return { x: tsToMs(pt[0]), y: pt[1] }; }),
                    borderColor: color,
                    backgroundColor: color + '22',
                    tension: 0.3, fill: false, pointRadius: 2, pointHoverRadius: 5, spanGaps: true
                };
            });
        }

        function makeChart(canvas, hostMap, unit, onClickCb) {
            if (typeof Chart === 'undefined') {
                container.innerHTML = '<p class="muted">Chart library failed to load.</p>';
                return;
            }
            new Chart(canvas, {
                type: 'line',
                data: { datasets: makeDatasets(hostMap) },
                options: {
                    responsive: true, maintainAspectRatio: false,
                    interaction: { mode: 'index', intersect: false },
                    plugins: {
                        legend: {
                            position: 'bottom',
                            labels: { boxWidth: 12, font: { size: 11 } },
                            onClick: function (e, item, legend) {
                                var meta = legend.chart.getDatasetMeta(item.datasetIndex);
                                meta.hidden = !meta.hidden;
                                legend.chart.update();
                            }
                        },
                        tooltip: { callbacks: { label: function (item) {
                            return item.dataset.label + ': ' + item.parsed.y + (unit ? ' ' + unit : '');
                        } } }
                    },
                    scales: {
                        x: {
                            type: 'time',
                            time: { tooltipFormat: 'MMM d HH:mm', displayFormats: { minute: 'HH:mm', hour: 'HH:mm', day: 'MMM d' } },
                            ticks: { maxTicksLimit: 8, maxRotation: 30, font: { size: 10 } }
                        },
                        y: { beginAtZero: false, ticks: { font: { size: 10 } } }
                    }
                }
            });
        }

        function addChart(title, hostMap, unit, onClickCb) {
            var box = document.createElement('div');
            box.className = 'hw-chart-box';
            var h4 = document.createElement('h4');
            h4.innerHTML = title + '<span>drag bottom edge to resize</span>';
            if (onClickCb) box.style.cursor = 'pointer';
            box.appendChild(h4);
            var wrap = document.createElement('div');
            wrap.className = 'hw-chart-wrap';
            var canvas = document.createElement('canvas');
            wrap.appendChild(canvas);
            box.appendChild(wrap);
            container.appendChild(box);
            makeChart(canvas, hostMap, unit, onClickCb);
        }

        function addSplitCard(title, topHostMap, topUnit, topLabel, botHostMap, botUnit, botLabel) {
            var box = document.createElement('div');
            box.className = 'hw-chart-box';
            box.style.height = '420px';
            var h4 = document.createElement('h4');
            h4.innerHTML = title + '<span>drag bottom edge to resize</span>';
            box.appendChild(h4);
            [[topLabel, topHostMap, topUnit], [botLabel, botHostMap, botUnit]].forEach(function (cfg) {
                var lbl = document.createElement('div');
                lbl.style.cssText = 'font-size:.78em;color:var(--text-muted-color,#666);margin:4px 0 2px;';
                lbl.textContent = cfg[0];
                box.appendChild(lbl);
                var wrap = document.createElement('div');
                wrap.className = 'hw-chart-wrap';
                wrap.style.flex = '1';
                var canvas = document.createElement('canvas');
                wrap.appendChild(canvas);
                box.appendChild(wrap);
                makeChart(canvas, cfg[1], cfg[2]);
            });
            container.appendChild(box);
        }

        var byMetric = {};
        rawData.forEach(function (entry) { byMetric[entry.metric] = entry.hosts; });

        var rendered = 0, powerDone = false;
        rawData.forEach(function (entry) {
            var metric = entry.metric, hostMap = entry.hosts;
            if (!hostMap || !Object.keys(hostMap).length) return;

            if (metric === 'ipmi_power_consumption') {
                if (powerDone) return;
                powerDone = true;
                var wHosts = byMetric['ipmi_power_consumption'] || {};
                var aHosts = {};
                ['ipmi_ps1_current','ipmi_ps2_current'].forEach(function (mn, i) {
                    var hm = byMetric[mn];
                    if (!hm) return;
                    Object.keys(hm).forEach(function (host) { aHosts[host + ' PS' + (i + 1)] = hm[host]; });
                });
                if (Object.keys(aHosts).length) {
                    addSplitCard('Power / PSU Current', wHosts, 'W', 'System Power (W)', aHosts, 'A', 'PSU Current (A)');
                } else {
                    addChart(metric, wHosts, 'W');
                }
                rendered++; return;
            }
            if (metric === 'ipmi_ps1_current' || metric === 'ipmi_ps2_current') return;
            if (metric.match(/_temp$/)) return;
            if (metric.match(/^disk_/)) return;

            addChart(metric, hostMap, '');
            rendered++;
        });

        var diskCombined = {};
        rawData.forEach(function (entry) {
            if (!entry.metric.match(/^disk_used_pct/) || !entry.hosts) return;
            var mountPart = entry.metric.replace(/^disk_used_pct/, '') || '_';
            var mountLabel = mountPart.replace(/^_/, '/').replace(/_/g, '/') || '/';
            Object.keys(entry.hosts).forEach(function (host) {
                var shortHost = host.replace(/\.computersystemconsulting\.ca$/, '').replace(/\..*$/, '');
                diskCombined[shortHost + ' \u2014 ' + mountLabel] = entry.hosts[host];
            });
        });
        if (Object.keys(diskCombined).length) {
            var diskClickHandler = function (evt, items) {
                if (!items || !items.length) return;
                var dsIdx = items[0].datasetIndex;
                var label = Object.keys(diskCombined).sort()[dsIdx] || '';
                var parts = label.split(' \u2014 ');
                var host = parts[0] ? parts[0].trim() : 'workstation';
                var mount = parts[1] ? parts[1].trim() : '/';
                window.location.href = '/admin/hardware_monitor/disk_diagnose'
                    + '?hostname=' + encodeURIComponent(host)
                    + '&path=' + encodeURIComponent(mount);
            };
            addChart('Disk Usage %', diskCombined, '%', diskClickHandler);
            rendered++;
        }

        var combinedTemps = {};
        rawData.forEach(function (entry) {
            if (!entry.metric.match(/_temp$/) || !entry.hosts) return;
            var shortMetric = entry.metric.replace(/_temp$/, '').replace(/_/g, ' ');
            Object.keys(entry.hosts).forEach(function (host) {
                var shortHost = host.replace(/\.computersystemconsulting\.ca$/, '').replace(/\..*$/, '');
                combinedTemps[shortHost + ' \u2013 ' + shortMetric] = entry.hosts[host];
            });
        });
        if (Object.keys(combinedTemps).length) {
            addChart('Temperatures (\u00b0C)', combinedTemps, '\u00b0C');
            rendered++;
        }

        if (!rendered) {
            container.innerHTML = '<p class="muted">No numeric graph data in the selected window.</p>';
        }
    }

    function init() {
        initAutoRefresh();
        renderCharts();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
