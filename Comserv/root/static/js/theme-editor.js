/**
 * Enhanced Theme Editor with CSS Inspection
 * Combines theme variable management with direct element styling
 */

class ThemeEditor {
    constructor() {
        this.themeVariables = {};
        this.changedVariables = {};
        this.editableElements = [];
        this.activeElement = null;
        this.activeElementType = null;
        this.modal = null;
        this.backgroundPopup = null;
        this.currentBgImage = null;
        this.originalStyles = new Map();
        this.isInspectorActive = false;
        this.highlightedElement = null;
        this.themeName = document.getElementById('css-edit-toggle')?.dataset.themeName || 'default';
    }
    
    init() {
        // Initialize the theme variables from the form
        this.loadThemeVariables();

        // Find all editable elements
        this.findEditableElements();

        // Add event listeners
        this.addEventListeners();

        // Initialize the modal
        this.initModal();

        // Initialize the background popup
        this.initBackgroundPopup();

        // Initialize the inspector UI
        this.initInspectorUI();

        // Apply initial styles
        this.applyThemeStyles();
        
        // Add keyboard shortcut for toggling inspector
        this.addKeyboardShortcuts();
    }
    
    initInspectorUI() {
        // Create main container
        this.inspectorContainer = document.createElement('div');
        this.inspectorContainer.id = 'theme-inspector';
        this.inspectorContainer.style.cssText = `
            position: fixed;
            bottom: 0;
            right: 0;
            width: 350px;
            background: #fff;
            border: 1px solid #ccc;
            box-shadow: -2px -2px 10px rgba(0,0,0,0.1);
            z-index: 10000;
            max-height: 80vh;
            display: none;
            flex-direction: column;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        `;

        // Create header
        const header = document.createElement('div');
        header.style.cssText = `
            padding: 10px;
            background: #f5f5f5;
            border-bottom: 1px solid #ddd;
            display: flex;
            justify-content: space-between;
            align-items: center;
        `;
        
        const title = document.createElement('h3');
        title.textContent = 'Theme Inspector';
        title.style.margin = '0';
        
        this.toggleBtn = document.createElement('button');
        this.toggleBtn.textContent = 'Close';
        this.toggleBtn.style.cssText = `
            padding: 6px 12px;
            border: 1px solid #ccc;
            background: #f5f5f5;
            border-radius: 4px;
            cursor: pointer;
        `;
        const _closeHandler = (e) => {
            e.preventDefault();
            e.stopPropagation();
            this.forceCloseInspector();
        };
        this.toggleBtn.addEventListener('click', _closeHandler, true);
        this.toggleBtn.addEventListener('click', _closeHandler);
        
        header.appendChild(title);
        header.appendChild(this.toggleBtn);
        
        // Create content area
        const content = document.createElement('div');
        content.id = 'inspector-content';
        content.style.cssText = `
            padding: 15px;
            overflow-y: auto;
            flex-grow: 1;
        `;
        
        // Create element info section
        const elementInfo = document.createElement('div');
        elementInfo.id = 'element-info';
        elementInfo.innerHTML = `
            <div class="info-row">
                <label>Selected Element:</label>
                <span id="selected-element">None</span>
            </div>
            <div class="info-row">
                <label>Element ID:</label>
                <span id="element-id">-</span>
            </div>
            <div class="info-row">
                <label>Classes:</label>
                <span id="element-classes">-</span>
            </div>
            <div class="info-row">
                <label>Theme Variable:</label>
                <select id="theme-var-select">
                    <option value="">-- Select or create --</option>
                    ${Object.keys(this.themeVariables).map(varName => 
                        `<option value="${varName}">${varName}</option>`
                    ).join('')}
                </select>
                <button id="create-var">+</button>
            </div>
        `;
        
        // Create style editor section
        const styleEditor = document.createElement('div');
        styleEditor.id = 'style-editor';
        styleEditor.innerHTML = `
            <h4>Styles</h4>
            <div id="style-properties">
                <p>Select an element to edit its styles</p>
            </div>
        `;
        
        // Create action buttons
        const actions = document.createElement('div');
        actions.style.cssText = `
            padding: 10px;
            border-top: 1px solid #eee;
            display: flex;
            gap: 10px;
        `;
        
        const saveBtn = document.createElement('button');
        saveBtn.textContent = 'Save to Theme';
        saveBtn.className = 'btn btn-primary';
        saveBtn.onclick = () => this.saveToTheme();
        
        const resetBtn = document.createElement('button');
        resetBtn.textContent = 'Reset';
        resetBtn.className = 'btn btn-secondary';
        resetBtn.onclick = () => this.resetStyles();
        
        actions.appendChild(saveBtn);
        actions.appendChild(resetBtn);
        
        // Assemble the UI
        content.appendChild(elementInfo);
        content.appendChild(styleEditor);
        this.inspectorContainer.appendChild(header);
        this.inspectorContainer.appendChild(content);
        this.inspectorContainer.appendChild(actions);
        
        // Add to body
        document.body.appendChild(this.inspectorContainer);
        
        // Add styles
        this.addInspectorStyles();
        
        // Add floating toggle button
        this.addFloatingButton();
        
        // Ensure inspector starts in closed state
        this.isInspectorActive = false;
        this.inspectorContainer.style.display = 'none';
    }
    
    addInspectorStyles() {
        const style = document.createElement('style');
        style.textContent = `
            .info-row {
                margin-bottom: 8px;
                display: flex;
                gap: 10px;
                align-items: center;
            }
            .info-row label {
                font-weight: bold;
                min-width: 100px;
            }
            .style-property {
                display: flex;
                margin-bottom: 5px;
                align-items: center;
            }
            .style-property label {
                width: 120px;
                font-size: 12px;
                color: #555;
            }
            .style-property input, 
            .style-property select {
                flex-grow: 1;
                padding: 4px 8px;
                border: 1px solid #ddd;
                border-radius: 4px;
            }
            .style-property button {
                margin-left: 5px;
                padding: 2px 6px;
                font-size: 12px;
            }
            #theme-inspector button {
                padding: 6px 12px;
                border: 1px solid #ccc;
                background: #f5f5f5;
                border-radius: 4px;
                cursor: pointer;
            }
            #theme-inspector button:hover {
                background: #e5e5e5;
            }
            #theme-inspector button.primary {
                background: #007bff;
                color: white;
                border-color: #0056b3;
            }
            #theme-inspector button.primary:hover {
                background: #0069d9;
            }
            .highlighted {
                outline: 2px dashed #4a90e2 !important;
                position: relative;
            }
            .highlighted::after {
                content: attr(data-css-selector);
                position: absolute;
                top: -20px;
                left: 0;
                background: #4a90e2;
                color: white;
                font-size: 10px;
                padding: 2px 5px;
                border-radius: 3px;
                white-space: nowrap;
                z-index: 10001;
            }
            #theme-var-select {
                flex-grow: 1;
                margin-right: 5px;
            }
            .btn {
                padding: 6px 12px;
                border-radius: 4px;
                cursor: pointer;
            }
            .btn-primary {
                background: #007bff;
                color: white;
                border: 1px solid #0056b3;
            }
            .btn-secondary {
                background: #6c757d;
                color: white;
                border: 1px solid #5a6268;
            }
        `;
        document.head.appendChild(style);
    }
    
    addKeyboardShortcuts() {
        document.addEventListener('keydown', (e) => {
            if (e.ctrlKey && e.shiftKey && e.key === 'I') {
                e.preventDefault();
                this.toggleInspector();
            }
            
            if (e.key === 'Escape' && this.isInspectorActive) {
                this.toggleInspector();
            }
        });
    }
    
    addFloatingButton() {
        const toggleBtn = document.createElement('button');
        toggleBtn.textContent = 'Theme';
        toggleBtn.id = 'theme-inspector-toggle';
        toggleBtn.style.cssText = `
            position: fixed;
            bottom: 20px;
            right: 20px;
            z-index: 9999;
            width: 60px;
            height: 60px;
            border-radius: 50%;
            background: #4a90e2;
            color: white;
            border: none;
            font-size: 12px;
            font-weight: bold;
            cursor: pointer;
            box-shadow: 0 2px 10px rgba(0,0,0,0.2);
            display: flex;
            align-items: center;
            justify-content: center;
        `;
        this.floatingBtn = toggleBtn;
        toggleBtn.onclick = () => this.toggleInspector();
        document.body.appendChild(toggleBtn);
    }
    
    loadThemeVariables() {
        // Get values from color pickers
        const colorInputs = document.querySelectorAll('input[type="color"]');
        colorInputs.forEach(input => {
            const property = input.id;
            this.themeVariables[property] = input.value;
        });
        
        // Add additional variables
        this.themeVariables['button-bg'] = this.themeVariables['accent-color'] || '#FF9900';
        this.themeVariables['button-text'] = this.themeVariables['text-color'] || '#000000';
        this.themeVariables['nav-bg'] = this.themeVariables['primary-color'] || '#ffffff';
        this.themeVariables['nav-text'] = this.themeVariables['text-color'] || '#000000';
        this.themeVariables['heading-color'] = this.themeVariables['text-color'] || '#000000';
        this.themeVariables['background-color'] = '#ffffff';
        this.themeVariables['border-color'] = this.themeVariables['secondary-color'] || '#f9f9f9';
        
        // Add additional variables for the full page preview
        this.themeVariables['header-bg'] = this.themeVariables['primary-color'] || '#ffffff';
        this.themeVariables['footer-bg'] = '#f8f9fa';
        this.themeVariables['footer-text-color'] = this.themeVariables['text-color'] || '#000000';
        this.themeVariables['sidebar-bg'] = '#f8f9fa';
        this.themeVariables['article-bg'] = '#ffffff';
        this.themeVariables['main-bg'] = '#ffffff';
        this.themeVariables['nav-link-color'] = this.themeVariables['text-color'] || '#000000';
        this.themeVariables['login-area-bg'] = this.themeVariables['primary-color'] || '#ffffff';
    }
    
    findEditableElements() {
        const elements = document.querySelectorAll('.editable');
        elements.forEach(element => {
            const elementType = element.getAttribute('data-element') || 'generic';
            const property = element.getAttribute('data-property');

            this.editableElements.push({
                element: element,
                elementType: elementType,
                property: property
            });

            // Add visual indicator
            element.style.cursor = 'pointer';

            // Add hover effect
            element.addEventListener('mouseenter', () => {
                element.style.outline = '2px dashed #007bff';
            });

            element.addEventListener('mouseleave', () => {
                element.style.outline = 'none';
            });

            // Add click handler
            element.addEventListener('click', (e) => {
                e.preventDefault();
                e.stopPropagation();

                this.activeElement = element;
                this.activeElementType = elementType;

                // Check if this is a background element
                if (property.includes('bg') || property.includes('background')) {
                    this.openBackgroundPopup(element, property);
                } else {
                    this.openPropertyEditor(element);
                }
            });
        });
    }

    initBackgroundPopup() {
        // Create background popup if it doesn't exist
        let popupElement = document.getElementById('backgroundEditorPopup');
        if (!popupElement) {
            popupElement = document.createElement('div');
            popupElement.id = 'backgroundEditorPopup';
            popupElement.className = 'background-editor-popup';
            document.body.appendChild(popupElement);

            // Add styles for the popup
            const style = document.createElement('style');
            style.textContent = `
                .background-editor-popup {
                    position: absolute;
                    z-index: 1050;
                    background-color: white;
                    border: 1px solid #ccc;
                    border-radius: 8px;
                    box-shadow: 0 4px 8px rgba(0,0,0,0.2);
                    padding: 15px;
                    width: 300px;
                    display: none;
                }

                .background-editor-popup h4 {
                    margin-top: 0;
                    margin-bottom: 15px;
                    border-bottom: 1px solid #eee;
                    padding-bottom: 8px;
                }

                .background-editor-popup .form-group {
                    margin-bottom: 15px;
                }

                .background-editor-popup label {
                    display: block;
                    margin-bottom: 5px;
                    font-weight: bold;
                }

                .background-editor-popup input[type="color"] {
                    width: 100%;
                    height: 40px;
                }

                .background-editor-popup select {
                    width: 100%;
                    padding: 8px;
                    border-radius: 4px;
                    border: 1px solid #ccc;
                }

                .background-editor-popup .btn-group {
                    display: flex;
                    justify-content: space-between;
                    margin-top: 15px;
                }

                .background-editor-popup .btn {
                    padding: 8px 15px;
                    border-radius: 4px;
                    cursor: pointer;
                }

                .background-editor-popup .btn-primary {
                    background-color: #007bff;
                    color: white;
                    border: none;
                }

                .background-editor-popup .btn-secondary {
                    background-color: #6c757d;
                    color: white;
                    border: none;
                }

                .background-editor-popup .btn-advanced {
                    background-color: #17a2b8;
                    color: white;
                    border: none;
                    width: 100%;
                    margin-top: 10px;
                }

                .background-editor-popup .preview {
                    width: 100%;
                    height: 80px;
                    border: 1px solid #ccc;
                    margin-top: 10px;
                    background-position: center;
                    background-repeat: no-repeat;
                    background-size: cover;
                }
            `;
            document.head.appendChild(style);
        }
    }
    
    addEventListeners() {
        // Update preview when color inputs change
        const colorInputs = document.querySelectorAll('input[type="color"]');
        colorInputs.forEach(input => {
            input.addEventListener('input', () => {
                const property = input.id;
                this.themeVariables[property] = input.value;
                this.applyThemeStyles();
            });
        });
        
        // Add form submission handler
        const form = document.getElementById('theme-editor-form');
        if (form) {
            form.addEventListener('submit', (e) => {
                // Set the theme variables to the hidden input
                const hiddenInput = document.getElementById('theme-variables');
                if (hiddenInput) {
                    hiddenInput.value = JSON.stringify(this.themeVariables);
                }
            });
        }
        
        // Note: Inspector event listeners are added/removed dynamically via toggleInspector
        
        // Add event listener for creating new theme variables
        document.addEventListener('click', (e) => {
            if (e.target.id === 'create-var') {
                this.createNewThemeVar();
            }
        });
    }
    
    toggleInspector() {
        if (this.isInspectorActive) {
            this.closeInspector();
        } else {
            this.openInspector();
        }
    }
    
    _syncPagetopToggle(isActive) {
        const btn = document.getElementById('css-edit-toggle');
        if (btn) {
            if (isActive) {
                btn.innerHTML = '<i class="fas fa-times"></i> Close Editor';
                btn.classList.add('edit-mode');
            } else {
                btn.innerHTML = '<i class="fas fa-paint-brush"></i> Theme Editor';
                btn.classList.remove('edit-mode');
            }
        }
        if (this.floatingBtn) {
            this.floatingBtn.textContent = isActive ? '✕' : 'Theme';
            this.floatingBtn.style.background = isActive ? '#dc3545' : '#4a90e2';
        }
        document.body.classList.toggle('css-edit-mode', isActive);
    }

    closeInspector() {
        this.isInspectorActive = false;
        document.body.style.cursor = '';
        document.body.classList.remove('css-edit-mode');

        if (this.inspectorContainer) {
            this.inspectorContainer.style.display = 'none';
        } else {
            const el = document.getElementById('theme-inspector');
            if (el) el.style.display = 'none';
        }

        if (this.toggleBtn) this.toggleBtn.textContent = 'Open';

        this._syncPagetopToggle(false);

        if (this.highlightedElement) {
            this.highlightedElement.classList.remove('highlighted');
            this.highlightedElement = null;
        }
        this.removeInspectorEventListeners();
    }
    
    forceCloseInspector() {
        this.isInspectorActive = false;
        document.body.style.cursor = '';
        document.body.classList.remove('css-edit-mode');

        const inspector = document.getElementById('theme-inspector');
        if (inspector) {
            inspector.style.display = 'none';
            inspector.style.removeProperty('visibility');
        }
        if (this.inspectorContainer) {
            this.inspectorContainer.style.display = 'none';
        }

        this._syncPagetopToggle(false);

        document.querySelectorAll('.highlighted').forEach(el => el.classList.remove('highlighted'));
        this.highlightedElement = null;

        try { this.removeInspectorEventListeners(); } catch (e) {}
    }
    
    openInspector() {
        if (!this.inspectorContainer) return;
        
        this.isInspectorActive = true;
        this.inspectorContainer.style.display = 'flex';
        if (this.toggleBtn) this.toggleBtn.textContent = 'Close';
        document.body.style.cursor = 'crosshair';

        // Sync the pagetop toggle button
        this._syncPagetopToggle(true);
        
        // Update theme variables in the dropdown
        if (typeof this.updateThemeVarSelect === 'function') {
            this.updateThemeVarSelect();
        }
        // Add event listeners for inspector functionality
        this.addInspectorEventListeners();
    }
    
    addInspectorEventListeners() {
        this.mouseOverHandler = this.handleMouseOver.bind(this);
        this.clickHandler = this.handleElementClick.bind(this);
        
        document.addEventListener('mouseover', this.mouseOverHandler);
        document.addEventListener('click', this.clickHandler, true);
    }
    
    removeInspectorEventListeners() {
        if (this.mouseOverHandler) {
            document.removeEventListener('mouseover', this.mouseOverHandler);
        }
        if (this.clickHandler) {
            document.removeEventListener('click', this.clickHandler, true);
        }
    }
    
    handleMouseOver(e) {
        if (!this.isInspectorActive) return;
        
        const element = e.target;
        if (element === this.inspectorContainer || this.inspectorContainer.contains(element)) return;
        
        // Remove highlight from previous element
        if (this.highlightedElement) {
            this.highlightedElement.classList.remove('highlighted');
        }
        
        // Add highlight to current element
        element.classList.add('highlighted');
        element.dataset.cssSelector = this.getCssSelector(element);
        this.highlightedElement = element;
    }
    
    handleElementClick(e) {
        if (!this.isInspectorActive) return;

        const element = e.target;

        // Never intercept the inspector panel itself or its children
        try {
            if (element.closest('#theme-inspector')) return;
            if (this.inspectorContainer && this.inspectorContainer.contains(element)) return;
        } catch (ex) { return; }

        // Never intercept the pagetop toggle or the floating button
        try {
            if (element.closest('#css-edit-toggle') || element.closest('#theme-inspector-toggle')) return;
        } catch (ex) { return; }

        // Only now prevent the click from activating links/buttons on the page
        e.preventDefault();
        e.stopPropagation();

        this.selectElement(element);
    }
    
    selectElement(element) {
        this.activeElement = element;
        
        // Update element info
        document.getElementById('selected-element').textContent = element.tagName.toLowerCase();
        document.getElementById('element-id').textContent = element.id || '-';
        document.getElementById('element-classes').textContent = element.className || '-';
        
        // Display styles
        this.displayElementStyles(element);
        
        // Update theme variable selection
        this.updateThemeVarSelect();
    }
    
    displayElementStyles(element) {
        const styleProperties = document.getElementById('style-properties');
        styleProperties.innerHTML = '';

        const rootStyle = getComputedStyle(document.documentElement);
        const varsForElement = this.getVariablesForElement(element);

        // ── CSS Variable pickers (main WYSIWYG controls) ────────────────
        const varSection = document.createElement('div');
        varSection.style.cssText = 'margin-bottom:12px;';
        varSection.innerHTML = '<h5 style="margin:0 0 6px;font-size:13px;color:#555;">Theme Variables</h5>';

        varsForElement.forEach(varName => {
            if (varName === '_background-image') return; // handled separately below

            const currentVal = rootStyle.getPropertyValue('--' + varName).trim()
                            || this.changedVariables[varName] || '';

            const row = document.createElement('div');
            row.className = 'style-property';
            row.style.cssText = 'display:flex;align-items:center;gap:6px;margin-bottom:5px;';

            const lbl = document.createElement('label');
            lbl.textContent = '--' + varName;
            lbl.style.cssText = 'flex:1;font-size:11px;color:#444;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
            lbl.title = '--' + varName;

            const isColor = varName.includes('color') || varName.includes('bg') || varName.includes('background');

            if (isColor) {
                const picker = document.createElement('input');
                picker.type = 'color';
                picker.style.cssText = 'width:36px;height:28px;padding:0;border:none;cursor:pointer;';
                picker.value = this.rgbToHex(currentVal) || '#ffffff';
                picker.title = 'Current: ' + (currentVal || 'default');

                const txt = document.createElement('input');
                txt.type = 'text';
                txt.value = currentVal;
                txt.style.cssText = 'width:80px;font-size:11px;padding:2px 4px;border:1px solid #ccc;border-radius:3px;';

                picker.addEventListener('input', () => {
                    txt.value = picker.value;
                    this.updateCSSVariable(varName, picker.value);
                });
                txt.addEventListener('change', () => {
                    if (/^#[0-9a-fA-F]{6}$/.test(txt.value)) picker.value = txt.value;
                    this.updateCSSVariable(varName, txt.value);
                });

                row.appendChild(lbl);
                row.appendChild(picker);
                row.appendChild(txt);
            } else {
                const txt = document.createElement('input');
                txt.type = 'text';
                txt.value = currentVal;
                txt.style.cssText = 'flex:1;font-size:11px;padding:2px 4px;border:1px solid #ccc;border-radius:3px;';
                txt.placeholder = varName.includes('font') ? 'e.g. Arial, sans-serif' : 'value';
                txt.addEventListener('change', () => {
                    this.updateCSSVariable(varName, txt.value);
                });

                row.appendChild(lbl);
                row.appendChild(txt);
            }

            varSection.appendChild(row);
        });
        styleProperties.appendChild(varSection);

        // ── Background Image picker ────────────────────────────────────
        const bgSection = document.createElement('div');
        bgSection.style.cssText = 'border-top:1px solid #eee;padding-top:10px;margin-top:4px;';
        bgSection.innerHTML = `
            <h5 style="margin:0 0 6px;font-size:13px;color:#555;">Background Image</h5>
            <div style="display:flex;gap:6px;align-items:center;flex-wrap:wrap;">
                <input id="bg-image-url" type="text" placeholder="/static/images/…"
                    style="flex:1;min-width:120px;font-size:11px;padding:3px 6px;border:1px solid #ccc;border-radius:3px;">
                <button id="bg-image-apply" class="btn btn-sm btn-outline-secondary" style="font-size:11px;padding:2px 8px;">Apply</button>
                <button id="bg-image-clear" class="btn btn-sm btn-outline-danger"  style="font-size:11px;padding:2px 8px;">Clear</button>
            </div>
            <div id="bg-image-thumbs" style="display:flex;flex-wrap:wrap;gap:4px;margin-top:8px;max-height:140px;overflow-y:auto;"></div>`;
        styleProperties.appendChild(bgSection);

        // Fetch available images from a known set of folders
        const thumbsDiv = bgSection.querySelector('#bg-image-thumbs');
        const imgDirs = ['BMaster','apis','csc','usbm'];
        imgDirs.forEach(dir => {
            // We can't list directories from JS, but we can try known extensions
            // Instead, expose common images as thumbnails via a small scan endpoint
        });
        // Load thumbnails asynchronously
        this._loadBgThumbs(thumbsDiv, bgSection.querySelector('#bg-image-url'));

        bgSection.querySelector('#bg-image-apply').onclick = () => {
            const url = bgSection.querySelector('#bg-image-url').value.trim();
            if (url) {
                const val = `url("${url}")`;
                element.style.backgroundImage = val;
                // Save as a custom CSS rule, not a standard variable – store in changedVariables with special prefix
                this.changedVariables['_bg_image_' + this.getCssSelector(element).replace(/[^a-zA-Z0-9]/g,'_')] = `${this.getCssSelector(element)} { background-image: url("${url}"); }`;
            }
        };
        bgSection.querySelector('#bg-image-clear').onclick = () => {
            element.style.backgroundImage = '';
            bgSection.querySelector('#bg-image-url').value = '';
        };

        // ── Keep the legacy computed-styles section below ───────────────
        const sep = document.createElement('div');
        sep.style.cssText = 'border-top:1px solid #eee;padding-top:8px;margin-top:10px;';
        sep.innerHTML = '<h5 style="margin:0 0 6px;font-size:12px;color:#999;">Computed Styles (read-only)</h5>';
        styleProperties.appendChild(sep);

        const styles = window.getComputedStyle(element);
        const commonProperties = [
            'color', 'background-color', 'font-size', 'font-family',
            'width', 'height', 'margin', 'padding', 'border', 'display',
            'position', 'top', 'right', 'bottom', 'left', 'flex', 'flex-direction',
            'justify-content', 'align-items', 'gap', 'text-align'
        ];
        
        commonProperties.forEach(prop => {
            const value = styles.getPropertyValue(prop);
            if (!value) return;
            
            const propDiv = document.createElement('div');
            propDiv.className = 'style-property';
            
            const label = document.createElement('label');
            label.textContent = prop;
            
            let input;
            
            if (prop.includes('color') || prop.includes('background')) {
                input = document.createElement('input');
                input.type = 'color';
                input.value = this.rgbToHex(value) || '#000000';
                input.onchange = (e) => this.updateStyle(prop, e.target.value);
            } else if (prop === 'font-family' || prop === 'text-align' || 
                      prop === 'display' || prop === 'flex-direction' ||
                      prop === 'justify-content' || prop === 'align-items') {
                input = document.createElement('select');
                const options = this.getOptionsForProperty(prop);
                options.forEach(opt => {
                    const option = document.createElement('option');
                    option.value = opt.value;
                    option.textContent = opt.label;
                    option.selected = opt.value === value.trim();
                    input.appendChild(option);
                });
                input.onchange = (e) => this.updateStyle(prop, e.target.value);
            } else {
                input = document.createElement('input');
                input.type = 'text';
                input.value = value;
                input.onchange = (e) => this.updateStyle(prop, e.target.value);
            }
            
            propDiv.appendChild(label);
            propDiv.appendChild(input);
            
            styleProperties.appendChild(propDiv);
        });
    }
    
    getOptionsForProperty(property) {
        const options = {
            'font-family': [
                { value: 'Arial, sans-serif', label: 'Arial' },
                { value: '"Times New Roman", serif', label: 'Times New Roman' },
                { value: '"Courier New", monospace', label: 'Courier New' },
                { value: 'Georgia, serif', label: 'Georgia' },
                { value: 'Verdana, sans-serif', label: 'Verdana' }
            ],
            'text-align': [
                { value: 'left', label: 'Left' },
                { value: 'center', label: 'Center' },
                { value: 'right', label: 'Right' },
                { value: 'justify', label: 'Justify' }
            ],
            'display': [
                { value: 'block', label: 'Block' },
                { value: 'inline', label: 'Inline' },
                { value: 'inline-block', label: 'Inline Block' },
                { value: 'flex', label: 'Flex' },
                { value: 'grid', label: 'Grid' },
                { value: 'none', label: 'None' }
            ],
            'flex-direction': [
                { value: 'row', label: 'Row' },
                { value: 'row-reverse', label: 'Row Reverse' },
                { value: 'column', label: 'Column' },
                { value: 'column-reverse', label: 'Column Reverse' }
            ],
            'justify-content': [
                { value: 'flex-start', label: 'Flex Start' },
                { value: 'flex-end', label: 'Flex End' },
                { value: 'center', label: 'Center' },
                { value: 'space-between', label: 'Space Between' },
                { value: 'space-around', label: 'Space Around' },
                { value: 'space-evenly', label: 'Space Evenly' }
            ],
            'align-items': [
                { value: 'stretch', label: 'Stretch' },
                { value: 'flex-start', label: 'Flex Start' },
                { value: 'flex-end', label: 'Flex End' },
                { value: 'center', label: 'Center' },
                { value: 'baseline', label: 'Baseline' }
            ]
        };
        
        return options[property] || [];
    }
    
    updateStyle(property, value) {
        if (!this.activeElement) return;
        
        // Store original style if not already stored
        if (!this.originalStyles.has(this.activeElement)) {
            this.originalStyles.set(this.activeElement, {});
        }
        
        const elementStyles = this.originalStyles.get(this.activeElement);
        
        // If this is the first time modifying this property, store the original value
        if (!elementStyles[property]) {
            const originalValue = window.getComputedStyle(this.activeElement).getPropertyValue(property);
            elementStyles[property] = originalValue;
        }
        
        // Apply the new style
        this.activeElement.style.setProperty(property, value);
    }
    
    resetStyles() {
        if (!this.activeElement || !this.originalStyles.has(this.activeElement)) return;
        
        const elementStyles = this.originalStyles.get(this.activeElement);
        
        for (const [property, value] of Object.entries(elementStyles)) {
            this.activeElement.style.setProperty(property, value);
        }
        
        // Clear the stored styles
        this.originalStyles.delete(this.activeElement);
        
        // Refresh the display
        this.displayElementStyles(this.activeElement);
    }
    
    async saveToTheme() {
        const vars = this.changedVariables;
        if (Object.keys(vars).length === 0) {
            alert('No changes to save yet. Click an element and modify its colours or styles first.');
            return;
        }

        const body = new URLSearchParams();
        for (const [k, v] of Object.entries(vars)) {
            if (k.startsWith('_bg_image_')) continue; // background images handled separately
            body.append('var-' + k, v);
        }

        const saveBtn = document.querySelector('#theme-inspector button.btn-primary');
        const origText = saveBtn ? saveBtn.textContent : '';
        if (saveBtn) saveBtn.textContent = 'Saving…';

        try {
            const response = await fetch('/admin/theme/save_variables/' + encodeURIComponent(this.themeName), {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: body.toString(),
            });
            const data = await response.json();
            if (data.success) {
                this.changedVariables = {};
                alert('✓ ' + data.message);
            } else {
                alert('Error: ' + data.message);
            }
        } catch (err) {
            console.error('saveToTheme error:', err);
            alert('Network error saving theme: ' + err.message);
        } finally {
            if (saveBtn) saveBtn.textContent = origText;
        }
    }

    // Map element types to CSS variable names
    getVariablesForElement(element) {
        const tag = (element.tagName || '').toLowerCase();
        const cls = (element.className || '').toLowerCase();
        const id  = (element.id || '').toLowerCase();

        // Helper – check if element or ancestor matches
        const closest = (sel) => { try { return element.closest(sel); } catch(e) { return null; } };

        const vars = [];

        // Background / body
        if (tag === 'body' || tag === 'main' || tag === 'html') {
            vars.push('background-color', 'text-color', 'body-font', 'font-size-base');
        }

        // Navigation
        if (tag === 'nav' || closest('nav') || cls.includes('nav') || cls.includes('menu')) {
            vars.push('nav-bg', 'nav-text', 'nav-hover-bg');
        }

        // Buttons
        if (tag === 'button' || tag === 'input' || cls.includes('btn')) {
            vars.push('button-bg', 'button-text', 'button-border', 'button-hover-bg');
        }

        // Links
        if (tag === 'a') {
            vars.push('link-color', 'link-hover-color');
        }

        // Headings
        if (['h1','h2','h3','h4','h5','h6'].includes(tag)) {
            vars.push('text-color', 'header-font', 'font-size-large');
        }

        // Tables
        if (tag === 'table' || tag === 'th' || tag === 'thead' || closest('table')) {
            vars.push('table-header-bg', 'border-color');
        }

        // General: always offer background + text colour
        if (!vars.includes('background-color')) vars.push('background-color');
        if (!vars.includes('text-color')) vars.push('text-color');

        // Background image always available
        vars.push('_background-image');

        return [...new Set(vars)];
    }

    // Update a CSS variable live on :root
    updateCSSVariable(varName, value) {
        document.documentElement.style.setProperty('--' + varName, value);
        this.changedVariables[varName] = value;
    }
    
    createNewThemeVar() {
        const varName = prompt('Enter a name for the new theme variable (e.g., primary-button, card-bg):');
        if (!varName) return;
        
        // Add to theme variables
        if (!this.themeVariables[varName]) {
            this.themeVariables[varName] = {};
            this.updateThemeVarSelect(varName);
        } else {
            alert('A variable with this name already exists');
        }
    }
    
    updateThemeVarSelect(selectedVar = '') {
        const select = document.getElementById('theme-var-select');
        if (!select) return;
        
        // Save current selection
        const currentValue = selectedVar || select.value;
        
        // Clear and rebuild options
        select.innerHTML = '<option value="">-- Select or create --</option>';
        
        // Add theme variables
        Object.keys(this.themeVariables).sort().forEach(varName => {
            const option = document.createElement('option');
            option.value = varName;
            option.textContent = varName;
            if (varName === currentValue) {
                option.selected = true;
            }
            select.appendChild(option);
        });
    }
    
    // Helper function to convert RGB/RGBA to hex
    rgbToHex(rgb) {
        if (!rgb) return null;
        
        // Handle rgb/rgba values
        const rgbMatch = rgb.match(/^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*[\d.]+\s*)?\)/i);
        
        if (rgbMatch) {
            const r = parseInt(rgbMatch[1], 10);
            const g = parseInt(rgbMatch[2], 10);
            const b = parseInt(rgbMatch[3], 10);
            
            return '#' + ((1 << 24) + (r << 16) + (g << 8) + b).toString(16).slice(1);
        }
        
        // Return as-is if it's already in hex format or named color
        return rgb;
    }
    
    // Helper function to generate CSS selector for an element
    getCssSelector(element) {
        if (!element) return '';
        
        const parts = [];
        
        while (element && element.nodeType === Node.ELEMENT_NODE) {
            let selector = element.nodeName.toLowerCase();
            
            if (element.id) {
                selector += '#' + element.id;
                parts.unshift(selector);
                break;
            } else {
                let sibling = element;
                let siblingCount = 0;
                let siblingIndex = 0;
                
                while (sibling) {
                    if (sibling.nodeType === Node.ELEMENT_NODE && sibling.nodeName.toLowerCase() === selector) {
                        siblingCount++;
                        if (sibling === element) {
                            siblingIndex = siblingCount;
                        }
                    }
                    sibling = sibling.previousSibling;
                }
                
                if (siblingCount > 1) {
                    selector += ':nth-of-type(' + siblingIndex + ')';
                }
                
                parts.unshift(selector);
                
                if (element.className && typeof element.className === 'string') {
                    const classSelector = '.' + element.className.trim().replace(/\s+/g, '.');
                    parts[0] += classSelector;
                }
            }
            
            element = element.parentNode;
        }
        
        return parts.join(' > ');
    }
    
    async _loadBgThumbs(container, urlInput) {
        try {
            const res = await fetch('/admin/theme/list_images');
            if (!res.ok) return;
            const data = await res.json();
            const images = data.images || [];
            if (!images.length) {
                container.innerHTML = '<span style="font-size:11px;color:#999;">No images found in /static/images/</span>';
                return;
            }
            images.forEach(url => {
                const thumb = document.createElement('img');
                thumb.src = url;
                thumb.title = url;
                thumb.style.cssText = 'width:48px;height:48px;object-fit:cover;cursor:pointer;border:2px solid transparent;border-radius:3px;';
                thumb.onclick = () => {
                    urlInput.value = url;
                    container.querySelectorAll('img').forEach(i => i.style.borderColor = 'transparent');
                    thumb.style.borderColor = '#007bff';
                };
                container.appendChild(thumb);
            });
        } catch(e) {
            container.innerHTML = '<span style="font-size:11px;color:#999;">Image picker unavailable.</span>';
        }
    }

    initModal() {
        // Create modal if it doesn't exist
        let modalElement = document.getElementById('propertyEditorModal');
        if (!modalElement) {
            modalElement = document.createElement('div');
            modalElement.id = 'propertyEditorModal';
            modalElement.className = 'modal fade property-editor-modal';
            modalElement.setAttribute('tabindex', '-1');
            modalElement.setAttribute('aria-labelledby', 'propertyEditorModalLabel');
            modalElement.setAttribute('aria-hidden', 'true');
            document.body.appendChild(modalElement);
        }
    }

    openBackgroundPopup(element, property) {
        const popupElement = document.getElementById('backgroundEditorPopup');
        if (!popupElement) return;

        // Get current values
        const currentBgColor = this.themeVariables[property] || '#ffffff';
        const currentBgImage = this.themeVariables[`${property}-image`] || '';
        const currentBgRepeat = this.themeVariables[`${property}-repeat`] || 'repeat';
        const currentBgPosition = this.themeVariables[`${property}-position`] || 'center center';
        const currentBgSize = this.themeVariables[`${property}-size`] || 'auto';

        // Create popup content
        const propertyName = this.formatPropertyName(property);
        const content = `
            <h4>Edit ${propertyName}</h4>
            <div class="form-group">
                <label for="bgColor">Background Color:</label>
                <input type="color" id="bgColor" value="${currentBgColor}">
            </div>

            <div class="form-group">
                <label for="bgImageInput">Background Image:</label>
                <input type="file" id="bgImageInput" accept="image/*" class="form-control">
                <small class="text-muted">Select an image to use as background</small>
            </div>

            <div class="form-group">
                <label for="bgRepeat">Background Repeat:</label>
                <select id="bgRepeat">
                    <option value="repeat" ${currentBgRepeat === 'repeat' ? 'selected' : ''}>Repeat (Tile)</option>
                    <option value="repeat-x" ${currentBgRepeat === 'repeat-x' ? 'selected' : ''}>Repeat Horizontally</option>
                    <option value="repeat-y" ${currentBgRepeat === 'repeat-y' ? 'selected' : ''}>Repeat Vertically</option>
                    <option value="no-repeat" ${currentBgRepeat === 'no-repeat' ? 'selected' : ''}>No Repeat</option>
                </select>
            </div>

            <div class="form-group">
                <label for="bgPosition">Background Position:</label>
                <select id="bgPosition">
                    <option value="center center" ${currentBgPosition === 'center center' ? 'selected' : ''}>Center</option>
                    <option value="top left" ${currentBgPosition === 'top left' ? 'selected' : ''}>Top Left</option>
                    <option value="top center" ${currentBgPosition === 'top center' ? 'selected' : ''}>Top Center</option>
                    <option value="top right" ${currentBgPosition === 'top right' ? 'selected' : ''}>Top Right</option>
                    <option value="center left" ${currentBgPosition === 'center left' ? 'selected' : ''}>Center Left</option>
                    <option value="center right" ${currentBgPosition === 'center right' ? 'selected' : ''}>Center Right</option>
                    <option value="bottom left" ${currentBgPosition === 'bottom left' ? 'selected' : ''}>Bottom Left</option>
                    <option value="bottom center" ${currentBgPosition === 'bottom center' ? 'selected' : ''}>Bottom Center</option>
                    <option value="bottom right" ${currentBgPosition === 'bottom right' ? 'selected' : ''}>Bottom Right</option>
                </select>
            </div>

            <div class="form-group">
                <label for="bgSize">Background Size:</label>
                <select id="bgSize">
                    <option value="auto" ${currentBgSize === 'auto' ? 'selected' : ''}>Auto</option>
                    <option value="cover" ${currentBgSize === 'cover' ? 'selected' : ''}>Cover (Fill Area)</option>
                    <option value="contain" ${currentBgSize === 'contain' ? 'selected' : ''}>Contain (Show All)</option>
                    <option value="100% 100%" ${currentBgSize === '100% 100%' ? 'selected' : ''}>Stretch to Fill</option>
                    <option value="100% auto" ${currentBgSize === '100% auto' ? 'selected' : ''}>100% Width</option>
                    <option value="auto 100%" ${currentBgSize === 'auto 100%' ? 'selected' : ''}>100% Height</option>
                </select>
            </div>

            <div class="preview" id="bgPreview" style="
                background-color: ${currentBgColor};
                background-image: ${currentBgImage};
                background-repeat: ${currentBgRepeat};
                background-position: ${currentBgPosition};
                background-size: ${currentBgSize};
            "></div>

            <div class="btn-group">
                <button class="btn btn-secondary" id="cancelBgBtn">Cancel</button>
                <button class="btn btn-primary" id="applyBgBtn">Apply</button>
            </div>

            <button class="btn btn-advanced" id="advancedBgBtn">Advanced Options</button>
        `;

        // Update popup content
        popupElement.innerHTML = content;

        // Position the popup near the element
        const rect = element.getBoundingClientRect();
        const scrollTop = window.pageYOffset || document.documentElement.scrollTop;
        const scrollLeft = window.pageXOffset || document.documentElement.scrollLeft;

        popupElement.style.top = (rect.top + scrollTop + rect.height + 10) + 'px';
        popupElement.style.left = (rect.left + scrollLeft) + 'px';
        popupElement.style.display = 'block';

        // Add event listeners
        const bgColorEl = document.getElementById('bgColor');
        const bgRepeatEl = document.getElementById('bgRepeat');
        const bgPositionEl = document.getElementById('bgPosition');
        const bgSizeEl = document.getElementById('bgSize');
        const bgImageInputEl = document.getElementById('bgImageInput');
        const bgPreviewEl = document.getElementById('bgPreview');
        const cancelBgBtnEl = document.getElementById('cancelBgBtn');
        const applyBgBtnEl = document.getElementById('applyBgBtn');
        const advancedBgBtnEl = document.getElementById('advancedBgBtn');
        
        if (bgColorEl) bgColorEl.addEventListener('input', this.updateBackgroundPreview.bind(this));
        if (bgRepeatEl) bgRepeatEl.addEventListener('change', this.updateBackgroundPreview.bind(this));
        if (bgPositionEl) bgPositionEl.addEventListener('change', this.updateBackgroundPreview.bind(this));
        if (bgSizeEl) bgSizeEl.addEventListener('change', this.updateBackgroundPreview.bind(this));

        // Add image upload handler
        if (bgImageInputEl) {
            bgImageInputEl.addEventListener('change', (e) => {
                const file = e.target.files[0];
                if (file) {
                    const reader = new FileReader();
                    reader.onload = (event) => {
                        const imageUrl = `url(${event.target.result})`;
                        if (bgPreviewEl) {
                            bgPreviewEl.style.backgroundImage = imageUrl;
                        }
                        this.currentBgImage = imageUrl;
                    };
                    reader.readAsDataURL(file);
                }
            });
        }

        if (cancelBgBtnEl) {
            cancelBgBtnEl.addEventListener('click', () => {
                popupElement.style.display = 'none';
            });
        }

        if (applyBgBtnEl) {
            applyBgBtnEl.addEventListener('click', () => {
                this.applyBackgroundChanges(property);
                popupElement.style.display = 'none';
            });
        }

        if (advancedBgBtnEl) {
            advancedBgBtnEl.addEventListener('click', () => {
                popupElement.style.display = 'none';
                this.openPropertyEditor(element);
            });
        }

        // Close popup when clicking outside
        document.addEventListener('click', (e) => {
            if (popupElement.style.display === 'block' &&
                !popupElement.contains(e.target) &&
                e.target !== element) {
                popupElement.style.display = 'none';
            }
        });
    }

    updateBackgroundPreview() {
        const preview = document.getElementById('bgPreview');
        if (!preview) return;

        const bgColor = document.getElementById('bgColor').value;
        const bgRepeat = document.getElementById('bgRepeat').value;
        const bgPosition = document.getElementById('bgPosition').value;
        const bgSize = document.getElementById('bgSize').value;

        // Use the current background image if it exists
        const bgImage = this.currentBgImage || preview.style.backgroundImage;

        preview.style.backgroundColor = bgColor;
        if (bgImage) {
            preview.style.backgroundImage = bgImage;
        }
        preview.style.backgroundRepeat = bgRepeat;
        preview.style.backgroundPosition = bgPosition;
        preview.style.backgroundSize = bgSize;
    }

    applyBackgroundChanges(property) {
        const bgColor = document.getElementById('bgColor').value;
        const bgRepeat = document.getElementById('bgRepeat').value;
        const bgPosition = document.getElementById('bgPosition').value;
        const bgSize = document.getElementById('bgSize').value;

        // Get the background image if it was set
        const bgImage = this.currentBgImage || this.themeVariables[`${property}-image`] || '';

        // Update element style
        if (this.activeElement) {
            this.activeElement.style.backgroundColor = bgColor;
            if (bgImage) {
                this.activeElement.style.backgroundImage = bgImage;
            }
            this.activeElement.style.backgroundRepeat = bgRepeat;
            this.activeElement.style.backgroundPosition = bgPosition;
            this.activeElement.style.backgroundSize = bgSize;
        }

        // Store in theme variables
        this.themeVariables[property] = bgColor;
        if (bgImage) {
            this.themeVariables[`${property}-image`] = bgImage;
        }
        this.themeVariables[`${property}-repeat`] = bgRepeat;
        this.themeVariables[`${property}-position`] = bgPosition;
        this.themeVariables[`${property}-size`] = bgSize;

        // Reset the current background image
        this.currentBgImage = null;

        // Update the preview
        this.applyThemeStyles();
    }

    applyThemeStyles() {
        // Apply theme variables to CSS custom properties
        const root = document.documentElement;
        for (const [property, value] of Object.entries(this.themeVariables)) {
            root.style.setProperty(`--${property}`, value);

            // If this is a background image property, also set the related CSS properties
            if (property.endsWith('-image')) {
                const baseProperty = property.replace('-image', '');
                const repeat = this.themeVariables[`${baseProperty}-repeat`] || 'repeat';
                const position = this.themeVariables[`${baseProperty}-position`] || 'center center';
                const size = this.themeVariables[`${baseProperty}-size`] || 'auto';

                root.style.setProperty(`--${baseProperty}-repeat`, repeat);
                root.style.setProperty(`--${baseProperty}-position`, position);
                root.style.setProperty(`--${baseProperty}-size`, size);
            }
        }
    }
    
    openPropertyEditor(element) {
        this.activeElement = element;
        const property = element.getAttribute('data-property');
        const currentValue = this.themeVariables[property] || '#000000';
        
        // Create modal content
        const modalContent = this.createModalContent(property, currentValue);
        
        // Update modal
        const modalElement = document.getElementById('propertyEditorModal');
        modalElement.innerHTML = modalContent;
        
        // Initialize the modal
        if (typeof bootstrap !== 'undefined') {
            this.modal = new bootstrap.Modal(modalElement);
            this.modal.show();
            
            // Add event listeners to the form
            const form = document.getElementById('propertyEditorForm');
            if (form) {
                form.addEventListener('submit', (e) => {
                    e.preventDefault();
                    this.applyPropertyChange(property);
                });
            }
        } else {
            console.error('Bootstrap is not loaded. Modal cannot be displayed.');
        }
    }
    
    createModalContent(property, currentValue) {
        let content = `
        <div class="modal-dialog">
            <div class="modal-content modal-lg">
                <div class="modal-header">
                    <h5 class="modal-title" id="propertyEditorModalLabel">Edit ${this.formatPropertyName(property)}</h5>
                    <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>
                </div>
                <form id="propertyEditorForm">
                    <div class="modal-body">`;
        
        // Different input types based on property
        if (property.includes('color')) {
            content += `
                        <div class="mb-3">
                            <label for="colorPicker" class="form-label">Select Color:</label>
                            <input type="color" class="form-control" id="colorPicker" value="${currentValue}">
                        </div>`;
        } else if (property.includes('background')) {
            content += `
                        <div class="mb-3">
                            <label for="colorPicker" class="form-label">Background Color:</label>
                            <input type="color" class="form-control" id="colorPicker" value="${currentValue}">
                        </div>
                        <div class="mb-3">
                            <label for="imageInput" class="form-label">Background Image:</label>
                            <input type="file" class="form-control" id="imageInput" accept="image/*">
                            <small class="form-text text-muted">Select an image to use as background</small>
                        </div>
                        <div class="mb-3">
                            <label for="bgRepeat">Background Repeat:</label>
                            <select class="form-control" id="bgRepeat">
                                <option value="repeat">Repeat (Tile)</option>
                                <option value="repeat-x">Repeat Horizontally</option>
                                <option value="repeat-y">Repeat Vertically</option>
                                <option value="no-repeat">No Repeat</option>
                            </select>
                        </div>
                        <div class="mb-3">
                            <label for="bgPosition">Background Position:</label>
                            <select class="form-control" id="bgPosition">
                                <option value="center center">Center</option>
                                <option value="top left">Top Left</option>
                                <option value="top center">Top Center</option>
                                <option value="top right">Top Right</option>
                                <option value="center left">Center Left</option>
                                <option value="center right">Center Right</option>
                                <option value="bottom left">Bottom Left</option>
                                <option value="bottom center">Bottom Center</option>
                                <option value="bottom right">Bottom Right</option>
                            </select>
                        </div>
                        <div class="mb-3">
                            <label for="bgSize">Background Size:</label>
                            <select class="form-control" id="bgSize">
                                <option value="auto">Auto</option>
                                <option value="cover">Cover (Fill Area)</option>
                                <option value="contain">Contain (Show All)</option>
                                <option value="100% 100%">Stretch to Fill</option>
                                <option value="100% auto">100% Width</option>
                                <option value="auto 100%">100% Height</option>
                            </select>
                        </div>`;
        } else if (property.includes('bg')) {
            content += `
                        <div class="mb-3">
                            <label for="colorPicker" class="form-label">Background Color:</label>
                            <input type="color" class="form-control" id="colorPicker" value="${currentValue}">
                        </div>
                        <div class="mb-3">
                            <label for="imageInput" class="form-label">Background Image:</label>
                            <input type="file" class="form-control" id="imageInput" accept="image/*">
                            <small class="form-text text-muted">Select an image to use as background</small>
                        </div>
                        <div class="mb-3">
                            <label for="bgRepeat">Background Repeat:</label>
                            <select class="form-control" id="bgRepeat">
                                <option value="repeat">Repeat (Tile)</option>
                                <option value="repeat-x">Repeat Horizontally</option>
                                <option value="repeat-y">Repeat Vertically</option>
                                <option value="no-repeat">No Repeat</option>
                            </select>
                        </div>
                        <div class="mb-3">
                            <label for="bgPosition">Background Position:</label>
                            <select class="form-control" id="bgPosition">
                                <option value="center center">Center</option>
                                <option value="top left">Top Left</option>
                                <option value="top center">Top Center</option>
                                <option value="top right">Top Right</option>
                                <option value="center left">Center Left</option>
                                <option value="center right">Center Right</option>
                                <option value="bottom left">Bottom Left</option>
                                <option value="bottom center">Bottom Center</option>
                                <option value="bottom right">Bottom Right</option>
                            </select>
                        </div>
                        <div class="mb-3">
                            <label for="bgSize">Background Size:</label>
                            <select class="form-control" id="bgSize">
                                <option value="auto">Auto</option>
                                <option value="cover">Cover (Fill Area)</option>
                                <option value="contain">Contain (Show All)</option>
                                <option value="100% 100%">Stretch to Fill</option>
                                <option value="100% auto">100% Width</option>
                                <option value="auto 100%">100% Height</option>
                            </select>
                        </div>`;
        } else if (property.includes('text') || property.includes('font')) {
            content += `
                        <div class="mb-3">
                            <label for="textInput" class="form-label">Text:</label>
                            <input type="text" class="form-control" id="textInput" value="${this.activeElement.innerText}">
                        </div>
                        <div class="mb-3">
                            <label for="textColor" class="form-label">Text Color:</label>
                            <input type="color" class="form-control" id="textColor" value="${this.themeVariables['text-color'] || '#000000'}">
                        </div>
                        <div class="mb-3">
                            <label for="fontSize" class="form-label">Font Size:</label>
                            <select class="form-control" id="fontSize">
                                <option value="12px">Small (12px)</option>
                                <option value="16px" selected>Normal (16px)</option>
                                <option value="20px">Large (20px)</option>
                                <option value="24px">X-Large (24px)</option>
                                <option value="32px">XX-Large (32px)</option>
                            </select>
                        </div>
                        <div class="mb-3">
                            <label for="fontWeight" class="form-label">Font Weight:</label>
                            <select class="form-control" id="fontWeight">
                                <option value="normal">Normal</option>
                                <option value="bold">Bold</option>
                                <option value="lighter">Lighter</option>
                            </select>
                        </div>`;
        } else if (this.activeElementType === 'button') {
            content += `
                        <div class="mb-3">
                            <label for="buttonText" class="form-label">Button Text:</label>
                            <input type="text" class="form-control" id="buttonText" value="${this.activeElement.innerText}">
                        </div>
                        <div class="mb-3">
                            <label for="buttonBgColor" class="form-label">Button Background:</label>
                            <input type="color" class="form-control" id="buttonBgColor" value="${currentValue}">
                        </div>
                        <div class="mb-3">
                            <label for="buttonTextColor" class="form-label">Button Text Color:</label>
                            <input type="color" class="form-control" id="buttonTextColor" value="${this.themeVariables['button-text'] || '#ffffff'}">
                        </div>
                        <div class="mb-3">
                            <label for="buttonBorderColor" class="form-label">Button Border Color:</label>
                            <input type="color" class="form-control" id="buttonBorderColor" value="${this.themeVariables['button-border'] || currentValue}">
                        </div>
                        <div class="mb-3">
                            <label for="buttonBorderRadius" class="form-label">Button Border Radius:</label>
                            <select class="form-control" id="buttonBorderRadius">
                                <option value="0">Square (0px)</option>
                                <option value="4px" selected>Slightly Rounded (4px)</option>
                                <option value="8px">Rounded (8px)</option>
                                <option value="16px">Very Rounded (16px)</option>
                                <option value="50%">Circular</option>
                            </select>
                        </div>`;
        }
        
        content += `
                    </div>
                    <div class="modal-footer">
                        <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button>
                        <button type="submit" class="btn btn-primary">Apply</button>
                    </div>
                </form>
            </div>
        </div>`;
        
        return content;
    }
    
    applyPropertyChange(property) {
        let newValue;
        
        if (property.includes('color') || property.includes('bg')) {
            newValue = document.getElementById('colorPicker').value;
        } else if (document.getElementById('textInput')) {
            // Handle text input
            newValue = document.getElementById('textInput').value;
            // Update the element text
            if (this.activeElement) {
                this.activeElement.innerText = newValue;
            }
        } else if (document.getElementById('imageInput')) {
            // Handle image upload
            this.handleImageUpload(property);
            return; // Early return as image upload is handled asynchronously
        }
        
        // Handle button specific properties
        if (this.activeElementType === 'button') {
            this.handleButtonProperties();
            return; // Early return as button properties are handled separately
        }
        
        // Handle background properties if they exist
        if (property.includes('bg') && document.getElementById('bgRepeat')) {
            this.handleBackgroundProperties(property);
            return; // Early return as background properties are handled separately
        }
        
        // Handle font properties if they exist
        if ((property.includes('text') || property.includes('font')) && document.getElementById('fontSize')) {
            this.handleFontProperties(property);
            return; // Early return as font properties are handled separately
        }
        
        // Update the theme variables and element style
        if (newValue) {
            this.themeVariables[property] = newValue;
            this.updateElementStyle(property, newValue);
        }
        
        // Close the modal
        if (this.modal) {
            this.modal.hide();
        }
        
        // Update the preview
        this.applyThemeStyles();
    }
    
    handleImageUpload(property) {
        const fileInput = document.getElementById('imageInput');
        if (fileInput.files && fileInput.files[0]) {
            const reader = new FileReader();
            reader.onload = (e) => {
                const imageUrl = `url(${e.target.result})`;
                
                // Get background properties
                const bgRepeat = document.getElementById('bgRepeat').value;
                const bgPosition = document.getElementById('bgPosition').value;
                const bgSize = document.getElementById('bgSize').value;
                
                // Update element style with all background properties
                if (this.activeElement) {
                    this.activeElement.style.backgroundImage = imageUrl;
                    this.activeElement.style.backgroundRepeat = bgRepeat;
                    this.activeElement.style.backgroundPosition = bgPosition;
                    this.activeElement.style.backgroundSize = bgSize;
                }
                
                // Store in theme variables
                this.themeVariables[`${property}-image`] = imageUrl;
                this.themeVariables[`${property}-repeat`] = bgRepeat;
                this.themeVariables[`${property}-position`] = bgPosition;
                this.themeVariables[`${property}-size`] = bgSize;
                
                // Close the modal
                if (this.modal) {
                    this.modal.hide();
                }
                
                // Update the preview
                this.applyThemeStyles();
            };
            reader.readAsDataURL(fileInput.files[0]);
        }
    }
    
    handleBackgroundProperties(property) {
        // Get background color
        const bgColor = document.getElementById('colorPicker').value;
        
        // Get other background properties
        const bgRepeat = document.getElementById('bgRepeat').value;
        const bgPosition = document.getElementById('bgPosition').value;
        const bgSize = document.getElementById('bgSize').value;
        
        // Update element style with all background properties
        if (this.activeElement) {
            this.activeElement.style.backgroundColor = bgColor;
            this.activeElement.style.backgroundRepeat = bgRepeat;
            this.activeElement.style.backgroundPosition = bgPosition;
            this.activeElement.style.backgroundSize = bgSize;
        }
        
        // Store in theme variables
        this.themeVariables[property] = bgColor;
        this.themeVariables[`${property}-repeat`] = bgRepeat;
        this.themeVariables[`${property}-position`] = bgPosition;
        this.themeVariables[`${property}-size`] = bgSize;
        
        // Close the modal
        if (this.modal) {
            this.modal.hide();
        }
        
        // Update the preview
        this.applyThemeStyles();
    }
    
    handleFontProperties(property) {
        // Get text and color
        const text = document.getElementById('textInput').value;
        const textColor = document.getElementById('textColor').value;
        
        // Get font properties
        const fontSize = document.getElementById('fontSize').value;
        const fontWeight = document.getElementById('fontWeight').value;
        
        // Update element style with all font properties
        if (this.activeElement) {
            this.activeElement.innerText = text;
            this.activeElement.style.color = textColor;
            this.activeElement.style.fontSize = fontSize;
            this.activeElement.style.fontWeight = fontWeight;
        }
        
        // Store in theme variables
        this.themeVariables[property] = textColor;
        this.themeVariables[`${property}-size`] = fontSize;
        this.themeVariables[`${property}-weight`] = fontWeight;
        
        // Close the modal
        if (this.modal) {
            this.modal.hide();
        }
        
        // Update the preview
        this.applyThemeStyles();
    }
    
    handleButtonProperties() {
        // Get button text and colors
        const buttonText = document.getElementById('buttonText').value;
        const buttonBgColor = document.getElementById('buttonBgColor').value;
        const buttonTextColor = document.getElementById('buttonTextColor').value;
        const buttonBorderColor = document.getElementById('buttonBorderColor').value;
        const buttonBorderRadius = document.getElementById('buttonBorderRadius').value;
        
        // Update element style with all button properties
        if (this.activeElement) {
            this.activeElement.innerText = buttonText;
            this.activeElement.style.backgroundColor = buttonBgColor;
            this.activeElement.style.color = buttonTextColor;
            this.activeElement.style.borderColor = buttonBorderColor;
            this.activeElement.style.borderRadius = buttonBorderRadius;
        }
        
        // Store in theme variables
        this.themeVariables['button-bg'] = buttonBgColor;
        this.themeVariables['button-text'] = buttonTextColor;
        this.themeVariables['button-border'] = buttonBorderColor;
        this.themeVariables['button-radius'] = buttonBorderRadius;
        
        // Close the modal
        if (this.modal) {
            this.modal.hide();
        }
        
        // Update the preview
        this.applyThemeStyles();
    }
    
    updateElementStyle(property, value) {
        if (!this.activeElement) return;
        
        // Update the element style
        if (property.includes('color') || property.includes('bg')) {
            if (property === 'primary-color' || property === 'header-bg') {
                this.activeElement.style.backgroundColor = value;
            } else if (property === 'secondary-color') {
                this.activeElement.style.backgroundColor = value;
            } else if (property === 'text-color') {
                this.activeElement.style.color = value;
            } else if (property === 'link-color') {
                this.activeElement.style.color = value;
            } else if (property === 'button-bg') {
                this.activeElement.style.backgroundColor = value;
            } else if (property === 'nav-bg') {
                this.activeElement.style.backgroundColor = value;
            } else if (property === 'nav-link-color') {
                this.activeElement.style.color = value;
            } else if (property === 'heading-color') {
                this.activeElement.style.color = value;
            } else if (property === 'footer-bg') {
                this.activeElement.style.backgroundColor = value;
            } else if (property === 'footer-text-color') {
                this.activeElement.style.color = value;
            }
        } else if (property.includes('background') && value.startsWith('url(')) {
            this.activeElement.style.backgroundImage = value;
        }
        
        // Apply theme styles to the document
        document.documentElement.style.setProperty(`--${property}`, value);
    }
    
    formatPropertyName(property) {
        return property.split('-').map(word => word.charAt(0).toUpperCase() + word.slice(1)).join(' ');
    }
}

// Initialize the theme editor when the document is ready
document.addEventListener('DOMContentLoaded', () => {
    // Initialize theme editor with default values
    const themeVariables = {
        'primary-color': '[% theme.variables.item("primary-color") || "#ffffff" %]',
        'secondary-color': '[% theme.variables.item("secondary-color") || "#f9f9fa" %]',
        'accent-color': '[% theme.variables.item("accent-color") || "#FF9900" %]',
        'text-color': '[% theme.variables.item("text-color") || "#000000" %]',
        'link-color': '[% theme.variables.item("link-color") || "#0000FF" %]',
        'button-bg': '[% theme.variables.item("button-bg") || "#FF9900" %]',
        'button-text': '[% theme.variables.item("button-text") || "#ffffff" %]',
        'nav-bg': '[% theme.variables.item("nav-bg") || "#ccffff" %]',
        'nav-text': '[% theme.variables.item("nav-text") || "#000000" %]',
        'nav-link-color': '[% theme.variables.item("nav-link-color") || "#000000" %]',
        'heading-color': '[% theme.variables.item("heading-color") || "#000000" %]',
        'background-color': '[% theme.variables.item("background-color") || "#ffffff" %]',
        'border-color': '[% theme.variables.item("border-color") || "#dddddd" %]',
        'header-bg': '[% theme.variables.item("header-bg") || "#ffffff" %]',
        'footer-bg': '[% theme.variables.item("footer-bg") || "#f8f9fa" %]',
        'footer-text-color': '[% theme.variables.item("footer-text-color") || "#000000" %]',
        'sidebar-bg': '[% theme.variables.item("sidebar-bg") || "#f8f9fa" %]',
        'article-bg': '[% theme.variables.item("article-bg") || "#ffffff" %]',
        'main-bg': '[% theme.variables.item("main-bg") || "#ffffff" %]'
    };

    // Save button functionality
    const saveThemeBtn = document.getElementById('save-theme-btn');
    if (saveThemeBtn) {
        saveThemeBtn.addEventListener('click', () => {
            // Set the theme variables to the hidden input
            const themeVarsInput = document.getElementById('theme-variables');
            const themeForm = document.getElementById('theme-editor-form');
            if (themeVarsInput && themeForm) {
                themeVarsInput.value = JSON.stringify(themeVariables);
                // Submit the form
                themeForm.submit();
            }
        });
    }

    // Only initialize the theme editor if we're on the theme editor page
    if (document.getElementById('theme-editor-form')) {
        const editor = new ThemeEditor();
        editor.init();
    }
});
