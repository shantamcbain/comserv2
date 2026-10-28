/* Fleet activity graphs for /proxmox. Theme colors come from CSS, not hardcoded here. */
(function () {
    'use strict';

    var root = document.getElementById('pve-fleet-graphs') || document.getElementById('pve-server-dashboard');
    if (!root) return;

    var statusEl = root.querySelector('.pve-graphs-status');
    var listEl = root.querySelector('.pve-graph-list');
    var url = root.getAttribute('data-url');
    var onlyServer = root.getAttribute('data-server-id') || '';
    var timeframe = 'hour';

    function text(value) {
        return String(value == null ? '' : value);
    }

    function el(tag, className, content) {
        var node = document.createElement(tag);
        if (className) node.className = className;
        if (content != null) node.textContent = content;
        return node;
    }

    function peakOf(series) {
        var peak = 0;
        var i;
        if (!series) return 0;
        for (i = 0; i < series.length; i++) {
            if (series[i] > peak) peak = series[i];
        }
        return peak;
    }

    function median(series) {
        if (!series || !series.length) return 0;
        var sorted = series.slice().sort(function (a, b) { return a - b; });
        var mid = Math.floor(sorted.length / 2);
        return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
    }

    function spikePeak(series, absolute, floor) {
        var peak = peakOf(series);
        var med = median(series);
        if (peak >= absolute) return peak;
        if (peak >= floor && peak >= med * 3) return peak;
        return 0;
    }

    function spark(series, unit, absolute, floor) {
        var fig = el('figure', 'pve-spark');
        var values = series && series.length ? series : [0];
        var peak = peakOf(values);
        var spiked = spikePeak(values, absolute, floor);
        if (spiked) fig.classList.add('is-spike');
        var w = 220;
        var h = 48;
        var max = Math.max(peak, absolute > 0 ? 1 : 0.1);
        var pts = [];
        var i;
        for (i = 0; i < values.length; i++) {
            var x = (i / Math.max(values.length - 1, 1)) * w;
            var y = h - (values[i] / max) * (h - 2) - 1;
            pts.push(x.toFixed(1) + ',' + y.toFixed(1));
        }
        var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
        svg.setAttribute('aria-hidden', 'true');
        var poly = document.createElementNS('http://www.w3.org/2000/svg', 'polyline');
        poly.setAttribute('fill', 'none');
        poly.setAttribute('stroke', 'currentColor');
        poly.setAttribute('stroke-width', '1.5');
        poly.setAttribute('points', pts.join(' '));
        svg.appendChild(poly);
        fig.appendChild(svg);
        fig.appendChild(el('figcaption', '', unit + ' peak ' + peak.toFixed(1)));
        return { fig: fig, spiked: spiked, peak: peak };
    }

    function addCharts(parent, charts) {
        var row = el('div', 'pve-graph-row');
        var any = false;
        charts.forEach(function (chart) {
            var drawn = spark(chart.series, chart.label, chart.abs, chart.floor);
            row.appendChild(drawn.fig);
            if (drawn.spiked) any = true;
        });
        parent.appendChild(row);
        return any;
    }

    function seriesFor(srv, spec) {
        var metrics = srv.metrics || [];
        function find(key) {
            var i;
            for (i = 0; i < metrics.length; i++) {
                if (metrics[i].key === key) return metrics[i].values || [];
            }
            return null;
        }
        if (spec.used && spec.total) {
            var used = find(spec.used);
            var total = find(spec.total);
            if (!used || !total) return null;
            var n = Math.min(used.length, total.length);
            var out = [];
            var i;
            for (i = 0; i < n; i++) {
                out.push(total[i] ? (100 * used[i] / total[i]) : 0);
            }
            return out;
        }
        if (spec.sum) {
            var parts = spec.sum.map(find);
            if (parts.some(function (p) { return !p; })) return null;
            var len = parts[0].length;
            var summed = [];
            var j;
            for (j = 0; j < len; j++) {
                summed.push(parts.reduce(function (acc, p) { return acc + (p[j] || 0); }, 0));
            }
            return summed;
        }
        return find(spec.key);
    }

    function lastOf(series) {
        if (!series || !series.length) return 0;
        return series[series.length - 1];
    }

    function metricLast(srv, key) {
        return lastOf(seriesFor(srv, { key: key }));
    }

    function fmtUptime(sec) {
        sec = Math.floor(sec || 0);
        if (!sec) return '—';
        var d = Math.floor(sec / 86400);
        var h = Math.floor((sec % 86400) / 3600);
        var m = Math.floor((sec % 3600) / 60);
        if (d) return d + 'd ' + h + 'h';
        if (h) return h + 'h ' + m + 'm';
        return m + 'm';
    }

    function snapshotText(srv, spec) {
        var st = srv.status || {};
        if (spec.id === 'cpu') {
            var pct = st.cpu_pct != null ? st.cpu_pct : metricLast(srv, 'cpu');
            var n = st.maxcpu || Math.round(metricLast(srv, 'maxcpu')) || 0;
            return pct.toFixed(1) + '% of ' + (n || '?') + ' CPUs';
        }
        if (spec.id === 'mem') {
            var used = st.memused != null ? st.memused : metricLast(srv, 'memused');
            var total = st.memtotal != null ? st.memtotal : metricLast(srv, 'memtotal');
            return used.toFixed(1) + ' GB of ' + total.toFixed(1) + ' GB';
        }
        if (spec.id === 'disk') {
            var u = st.rootused != null ? st.rootused : metricLast(srv, 'rootused');
            var t = st.roottotal != null ? st.roottotal : metricLast(srv, 'roottotal');
            return u.toFixed(1) + ' GB of ' + t.toFixed(1) + ' GB';
        }
        if (spec.id === 'io') {
            var wait = (srv.status && srv.status.iowait != null) ? srv.status.iowait : metricLast(srv, 'iowait');
            return wait.toFixed(1) + '%';
        }
        if (spec.id === 'swap') {
            var su = (srv.status && srv.status.swapused != null) ? srv.status.swapused : metricLast(srv, 'swapused');
            var stot = (srv.status && srv.status.swaptotal != null) ? srv.status.swaptotal : metricLast(srv, 'swaptotal');
            if (!stot) return su.toFixed(1) + ' GB';
            return (100 * su / stot).toFixed(1) + '% (' + su.toFixed(1) + ' GB of ' + stot.toFixed(1) + ' GB)';
        }
        if (spec.id === 'uptime') return fmtUptime(st.uptime);
        if (spec.id === 'load') {
            var load = st.load != null ? st.load : metricLast(srv, 'loadavg');
            var cores = st.maxcpu || Math.round(metricLast(srv, 'maxcpu')) || 0;
            return load.toFixed(1) + (cores ? ' of ' + cores + ' CPUs' : '');
        }
        var values = seriesFor(srv, spec);
        var unit = spec.unit ? ' ' + spec.unit : '';
        return lastOf(values).toFixed(1) + unit;
    }

    var LINE_COLORS = ['#1a73e8', '#e37400', '#188038', '#d93025', '#9334e6', '#12b5cb'];

    function pad2(n) {
        return n < 10 ? '0' + n : String(n);
    }

    function fmtAxisTime(epoch, tf) {
        if (!epoch) return '';
        var d = new Date(epoch * 1000);
        var clock = pad2(d.getHours()) + ':' + pad2(d.getMinutes());
        if (tf === 'hour' || tf === 'day') return clock;
        return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + clock;
    }

    function svgText(parent, x, y, content, anchor) {
        var node = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        node.setAttribute('x', String(x));
        node.setAttribute('y', String(y));
        node.setAttribute('fill', 'currentColor');
        node.setAttribute('font-size', '12');
        if (anchor) node.setAttribute('text-anchor', anchor);
        node.textContent = content;
        parent.appendChild(node);
        return node;
    }

    function drawLines(card, lines, scale, spec) {
        var times = (spec && spec.times) || [];
        var unit = (spec && spec.unit) || '';
        var yTitle = (spec && spec.yTitle) || 'Value';
        var xTitle = 'Time (' + timeframe + ')';
        var w = 1000;
        var h = 280;
        var top = 16;
        var bottom = 46;
        var left = 72;
        var right = 16;
        var plotW = w - left - right;
        var plotH = h - top - bottom;
        var baseY = top + plotH;
        var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
        svg.setAttribute('role', 'img');
        svg.setAttribute('aria-label', yTitle + ' over ' + timeframe);
        svg.style.color = 'var(--text-color, #222)';
        var grid;
        for (grid = 0; grid <= 4; grid++) {
            var gy = top + (plotH * grid / 4);
            var value = scale - (scale * grid / 4);
            var rule = document.createElementNS('http://www.w3.org/2000/svg', 'line');
            rule.setAttribute('x1', String(left));
            rule.setAttribute('x2', String(w - right));
            rule.setAttribute('y1', gy.toFixed(1));
            rule.setAttribute('y2', gy.toFixed(1));
            rule.setAttribute('stroke', 'currentColor');
            rule.setAttribute('stroke-opacity', '0.25');
            svg.appendChild(rule);
            svgText(svg, left - 8, gy + 4, value.toFixed(1), 'end');
        }
        var yLabel = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        yLabel.setAttribute('x', '16');
        yLabel.setAttribute('y', String(top + plotH / 2));
        yLabel.setAttribute('fill', 'currentColor');
        yLabel.setAttribute('font-size', '13');
        yLabel.setAttribute('text-anchor', 'middle');
        yLabel.setAttribute('transform', 'rotate(-90 16 ' + (top + plotH / 2) + ')');
        yLabel.textContent = yTitle + (unit ? ' (' + unit.trim() + ')' : '');
        svg.appendChild(yLabel);
        lines.forEach(function (line, index) {
            var color = LINE_COLORS[index % LINE_COLORS.length];
            var pts = [];
            var i;
            var lastX = left;
            for (i = 0; i < line.values.length; i++) {
                var x = left + (i / Math.max(line.values.length - 1, 1)) * plotW;
                var y = baseY - (Math.min(line.values[i], scale) / scale) * plotH;
                lastX = x;
                pts.push(x.toFixed(1) + ',' + y.toFixed(1));
            }
            var area = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
            area.setAttribute('points', pts.join(' ') + ' ' + lastX.toFixed(1) + ',' + baseY.toFixed(1) + ' ' + left + ',' + baseY.toFixed(1));
            area.setAttribute('fill', color);
            area.setAttribute('fill-opacity', '0.22');
            svg.appendChild(area);
            var poly = document.createElementNS('http://www.w3.org/2000/svg', 'polyline');
            poly.setAttribute('fill', 'none');
            poly.setAttribute('stroke', color);
            poly.setAttribute('stroke-width', '3');
            poly.setAttribute('points', pts.join(' '));
            svg.appendChild(poly);
        });
        var xMarks = [0, 0.5, 1];
        xMarks.forEach(function (frac) {
            var idx = Math.round((times.length - 1) * frac);
            var label = times.length ? fmtAxisTime(times[Math.max(idx, 0)], timeframe) : '';
            var x = left + frac * plotW;
            svgText(svg, x, baseY + 18, label || (frac === 0 ? 'start' : frac === 1 ? 'now' : ''), frac === 0 ? 'start' : frac === 1 ? 'end' : 'middle');
        });
        svgText(svg, left + plotW / 2, h - 6, xTitle, 'middle');
        card.appendChild(svg);
    }

    function renderFleet(servers) {
        var signed = servers.filter(function (srv) { return srv.ok && srv.metrics && srv.metrics.length; });
        var missed = servers.filter(function (srv) { return !srv.ok; });
        var specs = [
            { title: 'CPU usage', key: 'cpu', scale: 100, unit: '%' },
            { title: 'Server load', key: 'loadavg', scaleTo: 'maxcpu' },
            { title: 'Memory usage', used: 'memused', total: 'memtotal', scale: 100, unit: '%' },
            { title: 'IO delay', key: 'iowait', scale: 100, unit: '%' },
            { title: 'Network traffic', sum: ['netin', 'netout'], unit: ' MB/s' },
            { title: 'Storage', used: 'rootused', total: 'roottotal', scale: 100, unit: '%' },
            { title: 'Swap', used: 'swapused', total: 'swaptotal', scale: 100, unit: '%' },
            { title: 'CPU temperature', key: 'temperature', unit: ' °C', optional: true }
        ];
        var shown = 0;
        specs.forEach(function (spec) {
            var lines = [];
            signed.forEach(function (srv) {
                var values = seriesFor(srv, spec);
                if (values && values.length) lines.push({ name: srv.name || srv.id, values: values });
            });
            if (!lines.length) return;
            shown += 1;
            var card = el('article', 'pve-dc-card');
            card.appendChild(el('header', '', spec.title));
            var scale = 0.1;
            lines.forEach(function (line) {
                var peak = peakOf(line.values);
                if (peak > scale) scale = peak;
            });
            scale = scale * 1.25;
            var times = (signed[0] && signed[0].time) || [];
            drawLines(card, lines, scale, {
                times: times,
                unit: spec.unit || '',
                yTitle: spec.title
            });
            var legend = el('ul', 'pve-dc-legend');
            lines.forEach(function (line, index) {
                var color = LINE_COLORS[index % LINE_COLORS.length];
                var item = el('li', '');
                item.style.color = color;
                var swatch = el('span', 'pve-swatch', '');
                swatch.style.background = color;
                item.appendChild(swatch);
                var latest = line.values[line.values.length - 1];
                item.appendChild(document.createTextNode(line.name + ' ' + latest.toFixed(1) + (spec.unit || '')));
                legend.appendChild(item);
            });
            card.appendChild(legend);
            listEl.appendChild(card);
        });
        var note = shown
            ? 'One line per signed-in server. Filter is the Proxmox history window.'
            : 'No signed-in server returned history.';
        if (missed.length) {
            note += ' Not signed in: ' + missed.map(function (srv) { return srv.name || srv.id; }).join(', ') + '.';
        }
        statusEl.textContent = note;
    }

    function render(data) {
        listEl.textContent = '';
        var servers = (data && data.servers) || [];
        if (onlyServer) {
            servers = servers.filter(function (srv) { return srv.id === onlyServer; });
        }
        if (!servers.length) {
            statusEl.textContent = onlyServer
                ? 'No activity data for this server.'
                : 'No Proxmox servers are configured.';
            return;
        }
        if (!onlyServer) {
            listEl.className = 'pve-dc-cards';
            renderFleet(servers);
            return;
        }
        listEl.className = 'pve-graph-list';
        servers.forEach(function (srv) {
            var block = el('article', 'pve-graph-server');
            var title = el('h3', '', text(srv.name || srv.id));
            if (srv.host) title.appendChild(el('span', '', ' · ' + srv.host));
            block.appendChild(title);
            if (!srv.ok) {
                block.appendChild(el('p', 'pve-graphs-status', srv.error || 'Could not sign in'));
                listEl.appendChild(block);
                return;
            }
            var specs = [
                { title: 'CPU', series: seriesFor(srv, { key: 'cpu' }), scale: 100, unit: '%' },
                { title: 'Server load', series: seriesFor(srv, { key: 'loadavg' }), scale: metricLast(srv, 'maxcpu') || 1 },
                { title: 'Memory', series: seriesFor(srv, { used: 'memused', total: 'memtotal' }), scale: 100, unit: '%' },
                { title: 'IO delay', series: seriesFor(srv, { key: 'iowait' }), scale: 100, unit: '%' },
                { title: 'Network', series: seriesFor(srv, { sum: ['netin', 'netout'] }), unit: ' MB/s' },
                { title: 'Storage', series: seriesFor(srv, { used: 'rootused', total: 'roottotal' }), scale: 100, unit: '%' }
            ];
            specs.forEach(function (spec) {
                if (!spec.series || !spec.series.length || !window.PveHistoryFilter) return;
                var latest = spec.series[spec.series.length - 1];
                PveHistoryFilter.chart(block, {
                    title: spec.title,
                    series: spec.series,
                    scale: spec.scale,
                    caption: latest.toFixed(1) + (spec.unit || '')
                });
            });
            (srv.vms || []).forEach(function (vm) {
                var guest = el('div', 'pve-graph-vm');
                guest.appendChild(el('h4', '', text(vm.vmid) + ' ' + text(vm.name)));
                PveHistoryFilter.chart(guest, { title: 'CPU', series: vm.cpu || [], scale: 100, caption: 'guest' });
                PveHistoryFilter.chart(guest, { title: 'Memory', series: vm.mem || [], scale: 100, caption: 'guest' });
                PveHistoryFilter.chart(guest, { title: 'Network', series: vm.net || [], caption: 'MB/s' });
                PveHistoryFilter.chart(guest, { title: 'Disk', series: vm.disk || [], caption: 'MB/s' });
                block.appendChild(guest);
            });
            listEl.appendChild(block);
        });
        statusEl.textContent = 'Server history, ' + timeframe + '.';
    }

    function load() {
        statusEl.textContent = onlyServer ? 'Loading ' + timeframe + ' history…' : 'Signing in to every configured server…';
        var join = url.indexOf('?') === -1 ? '?' : '&';
        fetch(url + join + 'timeframe=' + encodeURIComponent(timeframe), {
            credentials: 'same-origin',
            headers: { 'Accept': 'application/json' }
        }).then(function (res) {
            return res.text().then(function (body) {
                var trimmed = body.replace(/^\s+/, '');
                if (trimmed.charAt(0) !== '{' && trimmed.charAt(0) !== '[') {
                    throw new Error('The activity feed is not loaded on this process yet. Restart :4016, then reload this page.');
                }
                return JSON.parse(body);
            });
        }).then(render).catch(function (err) {
            statusEl.textContent = err && err.message ? err.message : 'Could not load activity.';
        });
    }

    if (window.PveHistoryFilter) {
        PveHistoryFilter.mount(root.querySelector('.pve-graphs-bar'), function (next) {
            timeframe = next;
            load();
        }, timeframe);
    }

    load();
    setInterval(load, 60000);
})();
