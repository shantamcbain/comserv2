/**
 * docker-containers.js
 * Clean, minimal JS for the new docker_containers.tt
 * Handles container listing, refresh, host switching, and collapsible sections.
 */

(function() {
    'use strict';

    // === Collapsible Sections (works with theme CSS) ===
    window.toggleSection = function(sectionId) {
        const content = document.getElementById(sectionId);
        const chevron = document.getElementById('chevron-' + sectionId);
        
        if (!content) return;

        if (content.style.display === 'none' || content.style.display === '') {
            content.style.display = 'block';
            if (chevron) chevron.classList.add('expanded');
            
            // Auto-refresh containers when opening the status section
            if (sectionId === 'container-status') {
                refreshContainers();
            }
        } else {
            content.style.display = 'none';
            if (chevron) chevron.classList.remove('expanded');
        }
    };

    // === Target / Host Selection ===
    window.onTargetChange = function() {
        const select = document.getElementById('docker-target-select');
        const infoDisplay = document.getElementById('target-info-display');
        
        if (!select || !infoDisplay) return;

        const host = select.value;
        const labels = {
            'workstation': 'Workstation (Local)',
            'production1': 'Production 1 (192.168.1.126)',
            'production2': 'Production 2 (192.168.1.127)'
        };
        
        infoDisplay.textContent = labels[host] || host;
        
        // Refresh containers when host changes
        const statusDiv = document.getElementById('container-status');
        if (statusDiv && statusDiv.style.display !== 'none') {
            refreshContainers();
        }
    };

    // === Main Container Refresh Function ===
    window.refreshContainers = function() {
        const container = document.getElementById('containers-list');
        if (!container) return;

        const select = document.getElementById('docker-target-select');
        const host = select ? select.value : 'workstation';

        container.innerHTML = `
            <div style="padding: 20px; text-align: center; color: #666;">
                <i class="fas fa-spinner fa-spin"></i> Loading containers from ${host}...
            </div>
        `;

        fetch(`/admin/docker/list?host=${encodeURIComponent(host)}`, {
            credentials: 'same-origin'
        })
        .then(response => {
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }
            return response.json();
        })
        .then(data => {
            if (!data.success) {
                throw new Error(data.error || 'Unknown error');
            }
            renderContainers(container, data.containers || [], host);
        })
        .catch(err => {
            container.innerHTML = `
                <div style="padding: 15px; background: #fff3cd; border: 1px solid #ffc107; border-radius: 4px; color: #856404;">
                    <strong>Error loading containers:</strong> ${err.message}
                    <br><small>Host: ${host}</small>
                </div>
            `;
        });
    };

    // === Render Container List as Responsive Cards ===
    function renderContainers(containerEl, containers, host) {
        if (!containers.length) {
            containerEl.innerHTML = `
                <div style="padding: 20px; text-align: center; color: #666;">
                    No containers found on <strong>${host}</strong>.
                </div>
            `;
            return;
        }

        let html = `
            <div style="margin-bottom: 12px; font-weight: 600; color: var(--text-color);">
                ${containers.length} container(s) on ${host}
            </div>
            <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 16px;">
        `;

        containers.forEach(c => {
            const statusClass = c.state === 'running' ? 'text-success' : 
                               (c.state === 'exited' ? 'text-danger' : 'text-muted');
            
            html += `
                <div class="card" style="border: 1px solid var(--border-color, #ddd); border-radius: 8px; padding: 12px; background: var(--card-bg, #fff); display: flex; flex-direction: column; min-height: 220px;">
                    <div style="flex: 1;">
                        <div style="margin-bottom: 8px;">
                            <strong style="font-size: 1.05rem;">${c.name || c.id}</strong>
                        </div>
                        <ul style="list-style: none; padding: 0; margin: 0; font-size: 0.9rem; line-height: 1.5;">
                            <li><strong>Image:</strong> <code style="font-size:0.8em">${c.image}</code></li>
                            ${c.image_id ? `<li><strong>Image ID:</strong> <code style="font-size:0.75em">${c.image_id}</code></li>` : ''}
                            <li><strong>Status:</strong> <span class="${statusClass}">${c.status}</span></li>
                            ${c.health ? `<li><strong>Health:</strong> <span class="${c.health === 'healthy' ? 'text-success' : 'text-danger'}">${c.health}</span></li>` : ''}
                            <li><strong>Ports:</strong> ${c.ports || '-'}</li>
                            ${c.created_at ? `<li><strong>Created:</strong> ${c.created_at}</li>` : ''}
                            ${c.started_at ? `<li><strong>Started:</strong> ${c.started_at}</li>` : ''}
                            ${c.restart_count > 0 ? `<li><strong>Restarts:</strong> ${c.restart_count}</li>` : ''}
                            ${c.build_info ? `<li><strong>Build:</strong> ${c.build_info}</li>` : ''}
                            ${c.is_backup ? `<li><span style="color:#dc3545; font-weight:bold;">BACKUP CONTAINER</span></li>` : ''}
                        </ul>
                    </div>
                    <div style="margin-top: 12px; display: flex; gap: 6px; flex-wrap: wrap;">
                        ${c.state === 'running' ? `
                            <button class="btn btn-sm btn-warning" onclick="stopContainer('${c.name}')">Stop</button>
                            <button class="btn btn-sm btn-danger" onclick="restartContainer('${c.name}')">Restart</button>
                        ` : `
                            <button class="btn btn-sm btn-success" onclick="startContainer('${c.name}')">Start</button>
                        `}
                        <button class="btn btn-sm btn-info" onclick="viewLogs('${c.name}')">Logs</button>
                    </div>
                </div>
            `;
        });

        html += `</div>`;
        containerEl.innerHTML = html;
    }

    // === Placeholder Action Functions (can be expanded later) ===
    window.stopContainer = function(name) {
        if (!confirm(`Stop container ${name}?`)) return;
        // TODO: implement POST /admin/docker/stop/{name}
        alert('Stop action not yet wired in this minimal version.');
    };

    window.startContainer = function(name) {
        // TODO: implement POST /admin/docker/start/{name}
        alert('Start action not yet wired in this minimal version.');
    };

    window.restartContainer = function(name) {
        // TODO: implement POST /admin/docker/restart/{name}
        alert('Restart action not yet wired in this minimal version.');
    };

    window.viewLogs = function(name) {
        // TODO: open logs modal or navigate
        alert(`Logs for ${name} not yet implemented in minimal version.`);
    };

    // === Auto-initialize on page load ===
    document.addEventListener('DOMContentLoaded', function() {
        // Set initial target info
        const select = document.getElementById('docker-target-select');
        if (select) {
            const infoDisplay = document.getElementById('target-info-display');
            if (infoDisplay) {
                const host = select.value;
                const labels = {
                    'workstation': 'Workstation (Local)',
                    'production1': 'Production 1 (192.168.1.126)',
                    'production2': 'Production 2 (192.168.1.127)'
                };
                infoDisplay.textContent = labels[host] || host;
            }
        }

        // Optional: auto-open the container status card on load
        // Uncomment the next two lines if you want it expanded by default
        // const statusDiv = document.getElementById('container-status');
        // if (statusDiv) statusDiv.style.display = 'block';
    });

})();