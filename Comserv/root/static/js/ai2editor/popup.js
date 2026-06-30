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
     */
    function initSidebarPanels() {
        let currentPanel = null;

        function showSidebarPanel(name) {
            const panelsContainer = document.getElementById('sidebar-panels');
            const allPanels = panelsContainer.querySelectorAll('.sidebar-panel');
            const target = document.getElementById('panel-' + name);

            document.querySelectorAll('.sidebar-icon').forEach(el => el.classList.remove('active'));

            if (currentPanel === name) {
                panelsContainer.style.display = 'none';
                currentPanel = null;
                return;
            }

            allPanels.forEach(p => p.style.display = 'none');

            // Prefer global helper
            if (typeof window.toggleSection === 'function') {
                window.toggleSection(target.id);
            } else {
                target.style.display = 'block';
            }

            panelsContainer.style.display = 'block';
            currentPanel = name;

            const icon = document.querySelector(`.sidebar-icon[data-panel="${name}"]`);
            if (icon) icon.classList.add('active');
        }

        document.querySelectorAll('.sidebar-icon').forEach(icon => {
            icon.addEventListener('click', () => {
                const panelName = icon.getAttribute('data-panel');
                if (panelName) showSidebarPanel(panelName);
            });
        });
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

    // Boot when DOM ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initPopupEditor);
    } else {
        initPopupEditor();
    }

    // Expose for debugging / future extension
    window.AI2EditorPopup = { initPopupEditor };

})();