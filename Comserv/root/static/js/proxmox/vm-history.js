/* VM status history. Uses the same filter as the server history page. */
(function () {
    'use strict';

    var root = document.getElementById('pve-vm-history');
    if (!root || !window.PveHistoryFilter) return;

    var statusEl = root.querySelector('.pve-graphs-status');
    var listEl = root.querySelector('.pve-graph-list');
    var url = root.getAttribute('data-url');
    var timeframe = 'hour';

    function num(row, key) {
        var n = row && row[key];
        return typeof n === 'number' ? n : parseFloat(n) || 0;
    }

    function series(rows, pick) {
        var out = [];
        var i;
        for (i = 0; i < rows.length; i++) out.push(pick(rows[i]));
        return out;
    }

    function last(values) {
        return values && values.length ? values[values.length - 1] : 0;
    }

    function render(data) {
        listEl.textContent = '';
        var rows = (data && data.vm) || [];
        if (!rows.length) {
            statusEl.textContent = 'No history stored for this guest in the ' + timeframe + ' window.';
            return;
        }
        var cpu = series(rows, function (row) { return 100 * num(row, 'cpu'); });
        var mem = series(rows, function (row) {
            var max = num(row, 'maxmem');
            return max ? 100 * num(row, 'mem') / max : 0;
        });
        var net = series(rows, function (row) {
            return (num(row, 'netin') + num(row, 'netout')) / 1048576;
        });
        var disk = series(rows, function (row) {
            return (num(row, 'diskread') + num(row, 'diskwrite')) / 1048576;
        });
        PveHistoryFilter.chart(listEl, { title: 'CPU', series: cpu, scale: 100, caption: last(cpu).toFixed(1) + '%' });
        PveHistoryFilter.chart(listEl, { title: 'Memory', series: mem, scale: 100, caption: last(mem).toFixed(1) + '%' });
        PveHistoryFilter.chart(listEl, { title: 'Network', series: net, caption: last(net).toFixed(1) + ' MB/s' });
        PveHistoryFilter.chart(listEl, { title: 'Disk', series: disk, caption: last(disk).toFixed(1) + ' MB/s' });
        statusEl.textContent = 'Guest history, ' + timeframe + '. Same filter as the server page.';
    }

    function load() {
        statusEl.textContent = 'Loading ' + timeframe + ' history…';
        var join = url.indexOf('?') === -1 ? '?' : '&';
        fetch(url + join + 'timeframe=' + encodeURIComponent(timeframe), {
            credentials: 'same-origin',
            headers: { 'Accept': 'application/json' }
        }).then(function (res) {
            return res.json();
        }).then(render).catch(function () {
            statusEl.textContent = 'Could not load guest history.';
        });
    }

    PveHistoryFilter.mount(root.querySelector('.pve-graphs-bar'), function (next) {
        timeframe = next;
        load();
    }, timeframe);
    load();
}());
