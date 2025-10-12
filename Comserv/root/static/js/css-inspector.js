class CSSInspector {
    constructor() {
        this.isActive = false;
        this.currentElement = null;
        this.originalStyles = new Map();
        this.initUI();
    }

    initUI() {
        // Create main container
        this.container = document.createElement('div');
        this.container.id = 'css-inspector';
        this.container.style.cssText = `
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
        title.textContent = 'CSS Inspector';
        title.style.margin = '0';
        
        this.toggleBtn = document.createElement('button');
        this.toggleBtn.textContent = 'Close';
        this.toggleBtn.onclick = () => this.toggle();
        
        header.appendChild(title);
        header.appendChild(this.toggleBtn);
        
        // Create content area
        const content = document.createElement('div');
        content.id = 'css-inspector-content';
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
        `;
        
        // Create style editor section
        const styleEditor = document.createElement('div');
        styleEditor.id = 'style-editor';
        styleEditor.innerHTML = `
            <h4>Styles</h4>
            <div id="style-properties">
                <p>Select an element to edit its styles</p>
            </div>
            <div id="color-picker" style="display: none;">
                <input type="color" id="color-input">
                <button id="apply-color">Apply</button>
                <button id="cancel-color">Cancel</button>
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
        saveBtn.textContent = 'Save Changes';
        saveBtn.onclick = () => this.saveChanges();
        
        const resetBtn = document.createElement('button');
        resetBtn.textContent = 'Reset';
        resetBtn.onclick = () => this.resetStyles();
        
        actions.appendChild(saveBtn);
        actions.appendChild(resetBtn);
        
        // Assemble the UI
        content.appendChild(elementInfo);
        content.appendChild(styleEditor);
        this.container.appendChild(header);
        this.container.appendChild(content);
        this.container.appendChild(actions);
        
        // Add to body
        document.body.appendChild(this.container);
        
        // Add styles
        this.addStyles();
        
        // Initialize event listeners
        this.initEventListeners();
    }
    
    addStyles() {
        const style = document.createElement('style');
        style.textContent = `
            .info-row {
                margin-bottom: 8px;
                display: flex;
                gap: 10px;
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
            .style-property input, .style-property select {
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
            #css-inspector button {
                padding: 6px 12px;
                border: 1px solid #ccc;
                background: #f5f5f5;
                border-radius: 4px;
                cursor: pointer;
            }
            #css-inspector button:hover {
                background: #e5e5e5;
            }
            #css-inspector button.primary {
                background: #007bff;
                color: white;
                border-color: #0056b3;
            }
            #css-inspector button.primary:hover {
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
        `;
        document.head.appendChild(style);
    }
    
    initEventListeners() {
        // Toggle inspector on Ctrl+Shift+I
        document.addEventListener('keydown', (e) => {
            if (e.ctrlKey && e.shiftKey && e.key === 'I') {
                e.preventDefault();
                this.toggle();
            }
        });
        
        // Element selection
        document.addEventListener('mouseover', this.handleMouseOver.bind(this));
        document.addEventListener('click', this.handleElementClick.bind(this), true);
    }
    
    handleMouseOver(e) {
        if (!this.isActive) return;
        
        const element = e.target;
        if (element === this.container || this.container.contains(element)) return;
        
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
        if (!this.isActive) return;
        
        e.preventDefault();
        e.stopPropagation();
        
        const element = e.target;
        if (element === this.container || this.container.contains(element)) return;
        
        this.selectElement(element);
        return false;
    }
    
    selectElement(element) {
        this.currentElement = element;
        
        // Update element info
        document.getElementById('selected-element').textContent = element.tagName.toLowerCase();
        document.getElementById('element-id').textContent = element.id || '-';
        document.getElementById('element-classes').textContent = element.className || '-';
        
        // Display styles
        this.displayElementStyles(element);
    }
    
    displayElementStyles(element) {
        const styles = window.getComputedStyle(element);
        const styleProperties = document.getElementById('style-properties');
        styleProperties.innerHTML = '';
        
        // Common CSS properties to display
        const commonProperties = [
            'color', 'background-color', 'font-size', 'font-family',
            'width', 'height', 'margin', 'padding', 'border', 'display'
        ];
        
        commonProperties.forEach(prop => {
            const value = styles.getPropertyValue(prop);
            if (!value) return;
            
            const propDiv = document.createElement('div');
            propDiv.className = 'style-property';
            
            const label = document.createElement('label');
            label.textContent = prop;
            
            let input;
            
            if (prop.includes('color')) {
                input = document.createElement('input');
                input.type = 'color';
                input.value = this.rgbToHex(value) || '#000000';
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
    
    updateStyle(property, value) {
        if (!this.currentElement) return;
        
        // Store original style if not already stored
        if (!this.originalStyles.has(this.currentElement)) {
            this.originalStyles.set(this.currentElement, {});
        }
        
        const elementStyles = this.originalStyles.get(this.currentElement);
        
        // If this is the first time modifying this property, store the original value
        if (!elementStyles[property]) {
            const originalValue = window.getComputedStyle(this.currentElement).getPropertyValue(property);
            elementStyles[property] = originalValue;
        }
        
        // Apply the new style
        this.currentElement.style.setProperty(property, value);
    }
    
    resetStyles() {
        if (!this.currentElement || !this.originalStyles.has(this.currentElement)) return;
        
        const elementStyles = this.originalStyles.get(this.currentElement);
        
        for (const [property, value] of Object.entries(elementStyles)) {
            this.currentElement.style.setProperty(property, value);
        }
        
        // Clear the stored styles
        this.originalStyles.delete(this.currentElement);
        
        // Refresh the display
        this.displayElementStyles(this.currentElement);
    }
    
    saveChanges() {
        // In a real implementation, this would save the styles to a CSS file or database
        alert('In a real implementation, this would save the styles to your theme.');
        console.log('Saving styles:', this.originalStyles);
    }
    
    toggle() {
        this.isActive = !this.isActive;
        
        if (this.isActive) {
            this.container.style.display = 'flex';
            this.toggleBtn.textContent = 'Close';
            document.body.style.cursor = 'crosshair';
        } else {
            this.container.style.display = 'none';
            this.toggleBtn.textContent = 'Open CSS Inspector';
            document.body.style.cursor = '';
            
            // Remove highlights
            if (this.highlightedElement) {
                this.highlightedElement.classList.remove('highlighted');
                this.highlightedElement = null;
            }
        }
    }
    
    // Helper function to convert RGB/RGBA to hex
    rgbToHex(rgb) {
        if (!rgb) return null;
        
        // Handle rgb/rgba values
        const rgbMatch = rgb.match(/^rgba?\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*[\d.]+\s*)?\)/i);
        
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
}

// Initialize the CSS Inspector when the DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    window.cssInspector = new CSSInspector();
    
    // Add a floating button to toggle the inspector
    const toggleBtn = document.createElement('button');
    toggleBtn.textContent = 'CSS';
    toggleBtn.style.cssText = `
        position: fixed;
        bottom: 20px;
        right: 20px;
        z-index: 9999;
        width: 50px;
        height: 50px;
        border-radius: 50%;
        background: #4a90e2;
        color: white;
        border: none;
        font-size: 14px;
        font-weight: bold;
        cursor: pointer;
        box-shadow: 0 2px 10px rgba(0,0,0,0.2);
    `;
    
    toggleBtn.onclick = () => window.cssInspector.toggle();
    document.body.appendChild(toggleBtn);
});
