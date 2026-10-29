/* Shared Proxmox history filter. Server history and VM status both call mount(). */
(function (global) {
    'use strict';

    var FRAMES = [
        { id: 'hour', label: 'Hour' },
        { id: 'day', label: 'Day' },
        { id: 'week', label: 'Week' },
        { id: 'month', label: 'Month' },
        { id: 'year', label: 'Year' }
    ];

    function mount(bar, onChange, initial) {
        if (!bar) return;
        var current = initial || 'hour';
        var select = bar.querySelector('select[data-pve-tf]');
        if (!select) {
            var label = document.createElement('label');
            label.className = 'pve-tf-label';
            label.appendChild(document.createTextNode('Timeframe'));
            select = document.createElement('select');
            select.setAttribute('data-pve-tf', '1');
            label.appendChild(select);
            bar.appendChild(label);
        }
        if (!select.options.length) {
            FRAMES.forEach(function (frame) {
                var opt = document.createElement('option');
                opt.value = frame.id;
                opt.textContent = frame.label;
                select.appendChild(opt);
            });
        }
        select.value = current;
        select.addEventListener('change', function () {
            onChange(select.value);
        });
    }

    function chart(parent, spec) {
        var values = spec.series && spec.series.length ? spec.series : [0];
        var scale = spec.scale;
        var i;
        if (!scale) {
            scale = 0.1;
            for (i = 0; i < values.length; i++) {
                if (values[i] > scale) scale = values[i];
            }
        }
        var fig = document.createElement('figure');
        fig.className = 'pve-history-chart';
        var cap = document.createElement('figcaption');
        cap.textContent = spec.title + (spec.caption ? ' — ' + spec.caption : '');
        fig.appendChild(cap);
        var w = 320;
        var h = 140;
        var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
        svg.setAttribute('role', 'img');
        svg.setAttribute('aria-label', spec.title);
        var pts = [];
        for (i = 0; i < values.length; i++) {
            var x = (i / Math.max(values.length - 1, 1)) * (w - 4) + 2;
            var y = h - 2 - (Math.min(values[i], scale) / scale) * (h - 8);
            pts.push(x.toFixed(1) + ',' + y.toFixed(1));
        }
        var poly = document.createElementNS('http://www.w3.org/2000/svg', 'polyline');
        poly.setAttribute('stroke', 'currentColor');
        poly.setAttribute('stroke-width', '2');
        poly.setAttribute('fill', 'none');
        poly.setAttribute('points', pts.join(' '));
        svg.appendChild(poly);
        fig.appendChild(svg);
        parent.appendChild(fig);
        return fig;
    }

    global.PveHistoryFilter = { mount: mount, chart: chart, frames: FRAMES };
}(window));
