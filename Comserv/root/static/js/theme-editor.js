/**
 * Enhanced Theme Editor JavaScript
 * Provides interactive theme editing capabilities
 */

class ThemeEditor {
    constructor() {
        this.themeVariables = {};
        this.editableElements = [];
        this.activeElement = null;
        this.activeElementType = null;
        this.modal = null;
        this.backgroundPopup = null;
        this.currentBgImage = null;
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

        // Apply initial styles
        this.applyThemeStyles();
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
        document.getElementById('bgColor').addEventListener('input', this.updateBackgroundPreview.bind(this));
        document.getElementById('bgRepeat').addEventListener('change', this.updateBackgroundPreview.bind(this));
        document.getElementById('bgPosition').addEventListener('change', this.updateBackgroundPreview.bind(this));
        document.getElementById('bgSize').addEventListener('change', this.updateBackgroundPreview.bind(this));

        // Add image upload handler
        document.getElementById('bgImageInput').addEventListener('change', (e) => {
            const file = e.target.files[0];
            if (file) {
                const reader = new FileReader();
                reader.onload = (event) => {
                    const imageUrl = `url(${event.target.result})`;
                    document.getElementById('bgPreview').style.backgroundImage = imageUrl;
                    this.currentBgImage = imageUrl;
                };
                reader.readAsDataURL(file);
            }
        });

        document.getElementById('cancelBgBtn').addEventListener('click', () => {
            popupElement.style.display = 'none';
        });

        document.getElementById('applyBgBtn').addEventListener('click', () => {
            this.applyBackgroundChanges(property);
            popupElement.style.display = 'none';
        });

        document.getElementById('advancedBgBtn').addEventListener('click', () => {
            popupElement.style.display = 'none';
            this.openPropertyEditor(element);
        });

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
    document.getElementById('save-theme-btn').addEventListener('click', () => {
        // Set the theme variables to the hidden input
        document.getElementById('theme-variables').value = JSON.stringify(themeVariables);
        // Submit the form
        document.getElementById('theme-editor-form').submit();
    });

    const editor = new ThemeEditor();
    editor.init();
});
