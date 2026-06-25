// docker-containers.js
// Dynamic container list for Docker page (theme-compliant)

let containersData = [];
let currentTarget = 'workstation';

// ---------- Toggle / persistence helpers (must be first) ----------
function toggleSection(sectionId) {
    const content = document.getElementById(sectionId);
    const chevron = document.getElementById('chevron-' + sectionId);
    if (!content) return;

    const isOpen = content.style.display === 'block';
    if (!isOpen) {
        content.style.display = 'block';
        if (chevron) {
            chevron.classList.remove('fa-chevron-right');
            chevron.classList.add('fa-chevron-down');
        }
        localStorage.setItem('section_' + sectionId, 'open');
        // Auto-load data when opening for the first time
        if (sectionId === 'container-status') {
            refreshContainers();
        }
    } else {
        content.style.display = 'none';
        if (chevron) {
            chevron.classList.remove('fa-chevron-down');
            chevron.classList.add('fa-chevron-right');
        }
        localStorage.setItem('section_' + sectionId, 'closed');
    }
}

function restoreSectionStates() {
    const saved = localStorage.getItem('section_container-status');
    const content = document.getElementById('container-status');
    const chevron = document.getElementById('chevron-container-status');

    // Default to closed unless user explicitly saved it open
    if (saved === 'open' && content) {
        content.style.display = 'block';
        if (chevron) {
            chevron.classList.remove('fa-chevron-right');
            chevron.classList.add('fa-chevron-down');
        }
        // Load data if it was left open
        refreshContainers();
    } else if (content) {
        content.style.display = 'none';
        if (chevron) {
            chevron.classList.remove('fa-chevron-down');
            chevron.classList.add('fa-chevron-right');
        }
    }
}

// ---------- Core functions ----------
function onTargetChange() {
    currentTarget = document.getElementById('docker-target-select').value;
    const content = document.getElementById('container-status');
    if (content && content.style.display === 'block') {
        refreshContainers();
    }
}

function refreshContainers() {
    const containersList = document.getElementById('containers-list');
    const content = document.getElementById('container-status');
    
    // Auto-open the section if it's closed when Refresh is clicked
    if (content && content.style.display !== 'block') {
        content.style.display = 'block';
        const chevron = document.getElementById('chevron-container-status');
        if (chevron) {
            chevron.classList.remove('fa-chevron-right');
            chevron.classList.add('fa-chevron-down');
        }
        localStorage.setItem('section_container-status', 'open');
    }

    if (!containersList) return;

    containersList.innerHTML = '<p style="color: var(--text-muted-color, #666); text-align: center;">Loading container information...</p>';

    const url = '/admin/docker-list?target=' + encodeURIComponent(currentTarget);
    fetch(url, { credentials: 'same-origin', redirect: 'manual' })
        .then(function(response) {
            if (response.type === 'opaqueredirect' || response.status === 0 || (response.status >= 300 && response.status < 400)) {
                containersList.innerHTML = '<p style="color: #dc3545; text-align: center;">Session expired — please <a href="/user/login">log in again</a>.</p>';
                return null;
            }
            if (!response.ok) throw new Error('HTTP ' + response.status);
            return response.json();
        })
        .then(data => {
            if (!data) return;
            if (!data.success) {
                containersList.innerHTML = `<p style="color: #dc3545; text-align: center;">Error: ${data.error}</p>`;
                return;
            }
            containersData = data.containers;
            displayContainers(data.containers, data.host);
        })
        .catch(error => {
            containersList.innerHTML = `<p style="color: #dc3545; text-align: center;">Error loading containers: ${error.message}</p>`;
        });
}

function displayContainers(containers, host) {
    const containersList = document.getElementById('containers-list');
    if (!containers || containers.length === 0) {
        containersList.innerHTML = '<p style="color: var(--text-muted-color, #666); text-align: center;">No containers found</p>';
        return;
    }

    let html = '';
    containers.forEach(container => {
        const state = (container.state || container.State || '').toLowerCase();
        const isRunning = state === 'running' || state === 'up';
        const statusColor = isRunning ? '#28a745' : '#dc3545';
        const statusText = isRunning ? 'RUNNING' : (container.state || container.State || 'UNKNOWN').toUpperCase();
        const name = container.name || container.Names || container.Name || 'unknown';

        html += `
            <div style="border: 1px solid var(--border-color, #ddd); border-radius: 6px; padding: 12px; background: var(--card-bg, #fff);">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;">
                    <div style="display: flex; align-items: center; gap: 8px;">
                        <span style="font-weight: bold; font-size: 14px;">${name}</span>
                        <span style="background: ${statusColor}; color: white; padding: 1px 6px; border-radius: 3px; font-size: 10px; font-weight: bold;">${statusText}</span>
                    </div>
                    <div style="display: flex; gap: 6px;">
                        ${isRunning ? `
                            <button onclick="stopContainerDirect('${name}')"
                                style="padding: 4px 8px; background-color: #dc3545; color: white; border: none; border-radius: 3px; cursor: pointer; font-size: 11px;">■ Stop</button>
                            <button onclick="restartContainerDirect('${name}')"
                                style="padding: 4px 8px; background-color: #0066cc; color: white; border: none; border-radius: 3px; cursor: pointer; font-size: 11px;">↻ Restart</button>
                            <button onclick="viewLogsDirect('${name}')"
                                style="padding: 4px 8px; background-color: #17a2b8; color: white; border: none; border-radius: 3px; cursor: pointer; font-size: 11px;">📋 Logs</button>
                            <button onclick="rebuildContainerDirect('${name}')"
                                style="padding: 4px 8px; background-color: #6f42c1; color: white; border: none; border-radius: 3px; cursor: pointer; font-size: 11px;">🔄 Rebuild</button>
                        ` : `
                            <button onclick="startContainerDirect('${name}')"
                                style="padding: 4px 8px; background-color: #28a745; color: white; border: none; border-radius: 3px; cursor: pointer; font-size: 11px;">▶ Start</button>
                        `}
                    </div>
                </div>
                <div style="font-size: 12px; color: var(--text-muted-color, #666); line-height: 1.4;">
                    <div><strong>Image:</strong> ${container.image || container.Image || 'N/A'}</div>
                    <div><strong>ID:</strong> ${(container.ID || '').substring(0,12) || 'N/A'}</div>
                    <div><strong>Ports:</strong> ${Array.isArray(container.ports) ? container.ports.join(', ') : (container.Ports || 'None')}</div>
                    <div><strong>Status:</strong> ${container.status || ''}</div>
                </div>
            </div>
        `;
    });
    containersList.innerHTML = html;
}

// ---------- Action helpers ----------
function stopContainerDirect(name) {
    if (confirm(`Stop ${name}?`)) {
        fetch('/admin/docker-stop', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ container: name, target: currentTarget })
        }).then(() => refreshContainers());
    }
}

function startContainerDirect(name) {
    fetch('/admin/docker-start', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ container: name, target: currentTarget })
    }).then(() => refreshContainers());
}

function restartContainerDirect(name) {
    if (confirm(`Restart ${name}?`)) {
        fetch('/admin/docker-restart', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ container: name, target: currentTarget })
        }).then(() => refreshContainers());
    }
}

function viewLogsDirect(name) {
    window.open(`/admin/docker-logs?container=${encodeURIComponent(name)}&target=${currentTarget}`, '_blank');
}

function rebuildContainerDirect(name) {
    if (confirm(`Rebuild ${name}?`)) {
        fetch('/admin/docker-rebuild', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ container: name, target: currentTarget })
        }).then(() => refreshContainers());
    }
}

// ---------- Boot ----------
document.addEventListener('DOMContentLoaded', function() {
    restoreSectionStates();
});