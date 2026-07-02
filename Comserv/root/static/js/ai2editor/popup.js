/**
 * popup.js
 * AI2 Editor Popup Widget – widget-specific logic
 * Logging prefix: [AI2Editor]
 *
 * Depends on:
 *   - core.js (EditorAdapter + file helpers)
 *   - ui.js (global toggleSection if available)
 */

(function() {
    'use strict';

    const NS = 'AI2Editor';

    let editorAdapter = null;
    let currentFilePath = null;
    let lastMtime = null;
    let autoRefreshTimer = null;

    /**
     * Initialize the popup editor
     */
    function initPopupEditor() {
        const containerId = 'ace-editor';
        const refreshBtn = document.getElementById('refresh-btn');
        const statusEl = document.getElementById('file-status');
        const mtimeEl = document.getElementById('last-modified');

        // Default file from template or fallback
        currentFilePath = window.INITIAL_FILE_PATH || 'root/ai2/editor/editing_widget_popup.tt';

        // Create editor adapter
        editorAdapter = new window.AI2EditorCore.EditorAdapter(containerId, {
            fontSize: '14px'
        });

        if (!editorAdapter.editor) {
            console.error(`[${NS}] Failed to initialize editor adapter`);
            return;
        }

        // Load initial file
        loadAndDisplayFile(currentFilePath, statusEl, mtimeEl);

        // Refresh button
        if (refreshBtn) {
            refreshBtn.addEventListener('click', () => {
                if (currentFilePath) {
                    loadAndDisplayFile(currentFilePath, statusEl, mtimeEl);
                }
            });
        }

        // Editor switcher
        const editorSelect = document.getElementById('editor-select');
        if (editorSelect) {
            editorSelect.addEventListener('change', () => {
                const newEditor = editorSelect.value;
                switchEditor(newEditor, containerId, statusEl, mtimeEl);
            });
        }

        // Focus editor after init
        if (editorAdapter && editorAdapter.focus) editorAdapter.focus();

        // File tree click handlers
        document.querySelectorAll('.file-item').forEach(item => {
            item.addEventListener('click', () => {
                const path = item.dataset.path;
                if (path) {
                    loadAndDisplayFile(path, statusEl, mtimeEl);
                }
            });
        });

        // Start auto-refresh
        startAutoRefresh(statusEl, mtimeEl);

        // Sidebar panel logic
        initSidebarPanels();

        // Commit panel logic
        initCommitPanel();

        console.log(`[${NS}] popup.js initialized – model ready`);
    }

    async function loadAndDisplayFile(path, statusEl, mtimeEl) {
        try {
            const data = await window.AI2EditorCore.loadFileContent(path);
            if (editorAdapter) {
                editorAdapter.setValue(data.content || '', -1);
            }
            lastMtime = data.mtime;
            if (mtimeEl) {
                mtimeEl.textContent = `Last modified: ${new Date(lastMtime * 1000).toLocaleTimeString()}`;
            }
            if (statusEl) {
                statusEl.textContent = `Loaded: ${path.split('/').pop()}`;
            }
            highlightActiveFile(path);
            currentFilePath = path;
        } catch (err) {
            if (statusEl) statusEl.textContent = 'Error loading file';
        }
    }

    function switchEditor(editorName, containerId, statusEl, mtimeEl) {
        if (editorAdapter) {
            editorAdapter.destroy();
        }
        editorAdapter = window.AI2EditorCore.createEditor(editorName, containerId, {
            fontSize: '14px'
        });
        if (currentFilePath && editorAdapter) {
            loadAndDisplayFile(currentFilePath, statusEl, mtimeEl);
        }
        console.log(`[${NS}] Switched to editor: ${editorName}`);
    }

    function highlightActiveFile(path) {
        document.querySelectorAll('.file-item').forEach(el => {
            el.classList.remove('active');
            if (el.dataset.path === path || el.textContent.includes(path.split('/').pop())) {
                el.classList.add('active');
            }
        });
    }

    function startAutoRefresh(statusEl, mtimeEl) {
        if (autoRefreshTimer) clearInterval(autoRefreshTimer);
        autoRefreshTimer = setInterval(async () => {
            if (!currentFilePath) return;
            const newMtime = await window.AI2EditorCore.getFileMtime(currentFilePath);
            if (newMtime && newMtime !== lastMtime) {
                console.log(`[${NS}] External change detected, reloading...`);
                await loadAndDisplayFile(currentFilePath, statusEl, mtimeEl);
            }
        }, 4000);
    }

    /**
     * Sidebar panel logic (reuses global toggleSection when available)
     * Works in both full page and standalone island mode.
     */
    function initSidebarPanels() {
        const panelsContainer = document.getElementById('sidebar-panels');
        if (!panelsContainer) return;

        let currentPanel = null;

        function showSidebarPanel(name) {
            const allPanels = panelsContainer.querySelectorAll('.sidebar-panel');
            const targetId = 'panel-' + name;
            const target = document.getElementById(targetId);

            // Clear active states
            document.querySelectorAll('.sidebar-icon').forEach(el => el.classList.remove('active'));

            if (currentPanel === name) {
                panelsContainer.style.display = 'none';
                currentPanel = null;
                return;
            }

            allPanels.forEach(p => p.style.display = 'none');

            if (target) {
                target.style.display = 'block';
            } else {
                console.warn(`[${NS}] Panel not found: #${targetId}`);
            }

            panelsContainer.style.display = 'block';
            currentPanel = name;

            const icon = document.querySelector(`.sidebar-icon[data-panel="${name}"]`);
            if (icon) icon.classList.add('active');

            // Special handling for projects panel
            if (name === 'projects') {
                loadProjectFiles();
            }
        }

        // Event delegation on sidebar container (works for dynamically added icons too)
        const sidebar = document.getElementById('sidebar-icons');
        if (sidebar) {
            sidebar.addEventListener('click', function(ev) {
                const icon = ev.target.closest('.sidebar-icon');
                if (!icon) return;
                const panelName = icon.getAttribute('data-panel');
                if (panelName) {
                    showSidebarPanel(panelName);
                }
            });
        }

        // Also attach direct listeners (idempotent)
        document.querySelectorAll('.sidebar-icon').forEach(icon => {
            if (!icon.dataset.wired) {
                icon.dataset.wired = '1';
                icon.addEventListener('click', () => {
                    const panelName = icon.getAttribute('data-panel');
                    if (panelName) showSidebarPanel(panelName);
                });
            }
        });
    }

    /**
     * Load project files into the projects panel (island-safe)
     */
    async function loadProjectFiles() {
        const panel = document.getElementById('panel-projects');
        if (!panel) return;

        try {
            const res = await fetch('/ai2/project_files');
            if (!res.ok) throw new Error('HTTP ' + res.status);
            const files = await res.json();

            let html = '<h4 style="margin:0 0 8px 0; font-size:12px; color:#aaa;">PROJECTS</h4><ul class="file-tree">';
            (files || []).forEach(f => {
                html += `<li data-path="${f.path}" class="file-item">📄 ${f.name}</li>`;
            });
            html += '</ul>';
            panel.innerHTML = html;

            // Re-attach file click handlers
            panel.querySelectorAll('.file-item').forEach(item => {
                item.addEventListener('click', () => {
                    const path = item.dataset.path;
                    if (path && window.AI2EditorCore) {
                        const statusEl = document.getElementById('file-status');
                        const mtimeEl = document.getElementById('last-modified');
                        loadAndDisplayFile(path, statusEl, mtimeEl);
                    }
                });
            });

            console.log(`[${NS}] Project files loaded`);
        } catch (err) {
            console.error(`[${NS}] loadProjectFiles error:`, err);
            panel.innerHTML = '<div style="padding:12px;color:#f66;">Failed to load files</div>';
        }
    }

    /**
     * Commit panel logic
     */
    function initCommitPanel() {
        const doBtn = document.getElementById('do-commit-btn');
        const cancelBtn = document.getElementById('cancel-commit-btn');
        const gitPanel = document.getElementById('panel-git');

        if (doBtn) {
            doBtn.addEventListener('click', () => {
                alert('Committed!');
                if (gitPanel) gitPanel.style.display = 'none';
                document.querySelectorAll('.sidebar-icon').forEach(el => el.classList.remove('active'));
            });
        }

        if (cancelBtn) {
            cancelBtn.addEventListener('click', () => {
                if (gitPanel) gitPanel.style.display = 'none';
                document.querySelectorAll('.sidebar-icon').forEach(el => el.classList.remove('active'));
            });
        }
    }

    function initPopupSafe() {
        const container = document.getElementById('ace-editor');
        if (!container || container.dataset.initialized === '1') return;
        container.dataset.initialized = '1';
        initPopupEditor();
        // Ensure sidebar icons are wired even in island mode
        initSidebarPanels();
    }

    function initAll() {
        initPopupSafe();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initAll);
    } else {
        initAll();
    }
    document.addEventListener('htmx:afterSwap', initAll);

    window.showAiEditorPopup = function() {
        const popup = document.querySelector('.ai2editor-popup');
        if (popup) popup.style.display = 'block';
        else window.open('/ai2/editing_widget_popup', '_blank');
    };

    window.AI2EditorPopup = { initPopupEditor, initPopupSafe };

    // Expose island entry point for core.js bootstrap
    window.AI2EditorCore = window.AI2EditorCore || {};
    window.AI2EditorCore.initIslandPopup = initPopupSafe;

})();