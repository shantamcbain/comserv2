/* Proxmox power-task popup.
   Reboot/start/shutdown used to alert "initiated" as soon as Proxmox
   accepted the task. The task can still fail. This polls the task log. */
(function () {
    'use strict';

    var pollTimer = null;
    var seenLines = 0;

    function el(id) { return document.getElementById(id); }

    function ensureModal() {
        if (el('px-power-modal')) return;
        var wrap = document.createElement('div');
        wrap.id = 'px-power-modal';
        wrap.style.cssText = 'display:none;position:fixed;inset:0;z-index:10000;background:rgba(0,0,0,0.45);align-items:center;justify-content:center;padding:1em;';
        wrap.innerHTML =
            '<div role="dialog" aria-labelledby="px-power-title" style="background:var(--bg-color,#fff);color:var(--text-color,#222);border:1px solid var(--border-color,#ccc);border-radius:6px;width:min(720px,100%);max-height:85vh;display:flex;flex-direction:column;box-shadow:0 8px 28px rgba(0,0,0,0.25);">' +
            '<div style="display:flex;justify-content:space-between;align-items:center;gap:1em;padding:0.8em 1em;border-bottom:1px solid var(--border-color,#ddd);">' +
            '<strong id="px-power-title">Power task</strong>' +
            '<button type="button" id="px-power-close" style="background:transparent;border:1px solid var(--border-color,#ccc);color:inherit;border-radius:4px;padding:4px 10px;cursor:pointer;">Close</button>' +
            '</div>' +
            '<div id="px-power-summary" style="padding:0.8em 1em;font-size:0.95em;line-height:1.45;"></div>' +
            '<pre id="px-power-log" style="margin:0 1em 0.6em;padding:0.7em;overflow:auto;flex:1;min-height:8em;max-height:40vh;background:var(--code-bg,#111);color:var(--code-color,#e8e8e8);border-radius:4px;white-space:pre-wrap;"></pre>' +
            '<div id="px-power-actions" style="padding:0 1em 1em;"></div>' +
            '</div>';
        document.body.appendChild(wrap);
        el('px-power-close').addEventListener('click', closeModal);
        wrap.addEventListener('click', function (e) {
            if (e.target === wrap) closeModal();
        });
    }

    function closeModal() {
        if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
        var m = el('px-power-modal');
        if (m) m.style.display = 'none';
    }

    function openModal(title) {
        ensureModal();
        seenLines = 0;
        el('px-power-title').textContent = title;
        el('px-power-summary').textContent = 'Waiting for Proxmox…';
        el('px-power-log').textContent = '';
        el('px-power-actions').textContent = '';
        el('px-power-modal').style.display = 'flex';
    }

    function appendLog(lines) {
        if (!lines || !lines.length) return;
        if (lines.length < seenLines) seenLines = 0;
        if (lines.length === seenLines) return;
        var pre = el('px-power-log');
        var chunk = lines.slice(seenLines).join('\n');
        if (chunk) {
            pre.appendChild(document.createTextNode((pre.textContent ? '\n' : '') + chunk));
            pre.scrollTop = pre.scrollHeight;
        }
        seenLines = lines.length;
    }

    function mb(n) {
        if (n === null || n === undefined || n === '') return '—';
        return n + ' MB';
    }

    function render(data, vmname) {
        var task = data.task || {};
        var running = task.running ? 'running' : (task.exitstatus || task.status || 'finished');
        var failed = !task.running && task.exitstatus && task.exitstatus !== 'OK';
        var lines = [
            'VM ' + data.vmid + (vmname ? ' (' + vmname + ')' : ''),
            'VM status: ' + (data.vm_status || 'unknown'),
            'Task: ' + (task.type || 'none') + ' — ' + running,
            'Memory config: ' + mb(data.memory_current_mb),
            'Pending: ' + mb(data.memory_pending_mb),
            'Live max: ' + mb(data.maxmem_mb),
            'Memory applied: ' + (data.memory_applied ? 'yes' : 'no')
        ];
        if (task.user) lines.push('Task user: ' + task.user);
        if (task.upid) lines.push('UPID: ' + task.upid);
        var summary = el('px-power-summary');
        summary.textContent = '';
        lines.forEach(function (line) {
            var div = document.createElement('div');
            div.textContent = line;
            summary.appendChild(div);
        });
        if (failed) {
            var err = document.createElement('div');
            err.style.color = 'var(--danger-color, #b00020)';
            err.style.fontWeight = 'bold';
            err.style.marginTop = '0.4em';
            err.textContent = 'Failed: ' + task.exitstatus;
            summary.appendChild(err);
        }
        if (data.hint) {
            var hint = document.createElement('div');
            hint.style.marginTop = '0.5em';
            hint.textContent = data.hint;
            summary.appendChild(hint);
        }
        appendLog(task.log || []);

        var actions = el('px-power-actions');
        actions.textContent = '';
        if (data.vm_status === 'stopped' && data.memory_pending_mb && !task.running) {
            var btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'vm-btn vm-btn-start';
            btn.textContent = 'Start VM (applies pending ' + data.memory_pending_mb + ' MB)';
            btn.addEventListener('click', function () {
                runPower(data.vmid, 'start', vmname);
            });
            actions.appendChild(btn);
        }
    }

    function readJson(r) {
        return r.text().then(function (text) {
            var t = (text || '').replace(/^\s+/, '');
            if (t.charAt(0) !== '{' && t.charAt(0) !== '[') {
                var err = new Error('Server returned a page, not JSON (HTTP ' + r.status + ')');
                err.notJson = true;
                throw err;
            }
            return JSON.parse(t);
        });
    }

    function poll(vmid, upid, vmname) {
        var url = '/proxmox/vm_power_progress?vmid=' + encodeURIComponent(vmid);
        if (upid) url += '&upid=' + encodeURIComponent(upid);
        fetch(url, { credentials: 'same-origin' })
            .then(readJson)
            .then(function (data) {
                if (!data || !data.success) {
                    el('px-power-summary').textContent = 'Error: ' + ((data && data.error) || 'no data');
                    return;
                }
                render(data, vmname);
                var task = data.task || {};
                if (!task.running && pollTimer && (task.exitstatus || task.status || (task.log && task.log.length))) {
                    clearInterval(pollTimer);
                    pollTimer = null;
                }
            })
            .catch(function (e) {
                if (e && e.notJson) {
                    pollStatusFallback(vmid);
                    return;
                }
                el('px-power-summary').textContent = 'Request failed: ' + e;
            });
    }

    function pollStatusFallback(vmid) {
        if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
        fetch('/proxmox/status/' + encodeURIComponent(vmid), { credentials: 'same-origin' })
            .then(readJson)
            .then(function (d) {
                var st = (d && d.status) || {};
                var maxMb = st.maxmem ? Math.round(st.maxmem / 1048576) : 0;
                var usedMb = st.mem ? Math.round(st.mem / 1048576) : 0;
                el('px-power-summary').textContent =
                    'Task log is not available from this server process (it returned a page, not JSON). ' +
                    'Live status: ' + (st.status || 'unknown') +
                    (maxMb ? ', memory ' + usedMb + ' / ' + maxMb + ' MB' : '') +
                    '. Restart the :4016 server to load the task log. The power action can still have succeeded.';
            })
            .catch(function () {
                el('px-power-summary').textContent =
                    'Progress call returned HTML, not JSON. Restart the :4016 server so /proxmox/vm_power_progress is loaded. The power action can still have succeeded.';
            });
    }

    function startPoll(vmid, upid, vmname) {
        if (pollTimer) clearInterval(pollTimer);
        poll(vmid, upid, vmname);
        pollTimer = setInterval(function () { poll(vmid, upid, vmname); }, 1500);
    }

    function runPower(vmid, action, vmname) {
        var labels = { start: 'Start', stop: 'Stop', shutdown: 'Shut down', reboot: 'Reboot', reset: 'Reset' };
        var label = labels[action] || action;
        if (!window.confirm(label + ' VM ' + (vmname || vmid) + ' (' + vmid + ')?')) return;
        openModal(label + ' VM ' + vmid);
        el('px-power-summary').textContent = 'Sending ' + label + '…';
        fetch('/proxmox/vm_power', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: 'vmid=' + encodeURIComponent(vmid) + '&action=' + encodeURIComponent(action)
        })
            .then(readJson)
            .then(function (d) {
                if (!d || !d.success) {
                    el('px-power-summary').textContent = 'Proxmox did not accept the task: ' + ((d && d.error) || 'unknown error');
                    return;
                }
                el('px-power-log').textContent = 'Task queued. Watching the Proxmox task, not just the accept response.\n';
                seenLines = 0;
                startPoll(vmid, d.task_id || '', vmname);
            })
            .catch(function (e) {
                el('px-power-summary').textContent = 'Request failed: ' + e;
            });
    }

    function showLog(vmid, vmname) {
        openModal('Last power task — VM ' + vmid);
        startPoll(vmid, '', vmname);
    }

    document.addEventListener('click', function (e) {
        var btn = e.target.closest('[data-action="vm-power"], [data-action="vm-power-log"]');
        if (!btn) return;
        e.preventDefault();
        var vmid = btn.getAttribute('data-vmid');
        var vmname = btn.getAttribute('data-vmname') || '';
        if (!vmid) return;
        if (btn.getAttribute('data-action') === 'vm-power-log') {
            showLog(vmid, vmname);
        } else {
            runPower(vmid, btn.getAttribute('data-power'), vmname);
        }
    });

    document.addEventListener('click', function (e) {
        var tab = e.target.closest('[data-pve-tab]');
        if (!tab) return;
        var main = tab.closest('.pve-main');
        if (!main) return;
        var name = tab.getAttribute('data-pve-tab');
        main.setAttribute('data-tab', name);
        var tabs = main.querySelectorAll('[data-pve-tab]');
        for (var i = 0; i < tabs.length; i++) {
            tabs[i].classList.toggle('is-on', tabs[i] === tab);
        }
    });
})();
