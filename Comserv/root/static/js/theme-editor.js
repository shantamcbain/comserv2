/**
 * Theme Editor JavaScript
 * Provides functionality for the theme editor interface
 */

// Wait for DOM to be fully loaded
document.addEventListener('DOMContentLoaded', function() {
    // Color picker functionality
    initColorPickers();
    
    // Tab switching functionality
    initTabs();
    
    // Image preview functionality
    initImagePreview();
    
    // Live preview functionality
    initLivePreview();
});

/**
 * Initialize color pickers
 */
function initColorPickers() {
    // Find all color pickers
    const colorPickers = document.querySelectorAll('input[type="color"]');
    
    colorPickers.forEach(picker => {
        // Get the variable name from the picker ID
        const varName = picker.id.replace('color_picker_', '');
        
        // Add event listener to update text input when color changes
        picker.addEventListener('input', function() {
            updateColorInput(varName, this.value);
            
            // If we're in the WYSIWYG editor, also update the preview
            if (window.updatePreviewCSS) {
                updatePreviewCSS(varName, this.value);
            }
        });
        
        // Find the corresponding text input
        const textInput = document.getElementById('var_' + varName);
        if (textInput) {
            // Add event listener to update color picker when text changes
            textInput.addEventListener('input', function() {
                // Only update if it's a valid hex color
                if (/^#[0-9A-F]{6}$/i.test(this.value)) {
                    document.getElementById('color_picker_' + varName).value = this.value;
                    
                    // If we're in the WYSIWYG editor, also update the preview
                    if (window.updatePreviewCSS) {
                        updatePreviewCSS(varName, this.value);
                    }
                }
            });
        }
    });
}

/**
 * Update color input text when color picker changes
 */
function updateColorInput(varName, value) {
    const textInput = document.getElementById('var_' + varName);
    if (textInput) {
        textInput.value = value;
    }
}

/**
 * Initialize tab switching functionality
 */
function initTabs() {
    const tabButtons = document.querySelectorAll('.tab-button');
    
    tabButtons.forEach(button => {
        button.addEventListener('click', function() {
            // Remove active class from all tabs
            document.querySelectorAll('.tab-button').forEach(btn => {
                btn.classList.remove('active');
            });
            
            // Hide all tab content
            document.querySelectorAll('.tab-content').forEach(content => {
                content.style.display = 'none';
            });
            
            // Add active class to clicked tab
            this.classList.add('active');
            
            // Show corresponding tab content
            const tabId = this.getAttribute('data-tab') + '-tab';
            document.getElementById(tabId).style.display = 'block';
        });
    });
}

/**
 * Initialize image preview functionality
 */
function initImagePreview() {
    const backgroundImage = document.getElementById('background_image');
    if (backgroundImage) {
        backgroundImage.addEventListener('change', function() {
            const imageUrl = this.value;
            const previewContainer = document.getElementById('image_preview_container');
            
            if (imageUrl) {
                // Convert relative path to absolute path for preview
                let absoluteUrl = imageUrl;
                if (imageUrl.startsWith('../')) {
                    absoluteUrl = '/static/' + imageUrl.replace(/^\.\.\//, '');
                } else if (!imageUrl.startsWith('/')) {
                    absoluteUrl = '/static/' + imageUrl;
                }
                
                previewContainer.innerHTML = `<img src="${absoluteUrl}" alt="Background Image Preview" id="preview_image">`;
            } else {
                previewContainer.innerHTML = '<p>No image selected</p>';
            }
        });
    }
    
    // Image browser functionality
    const browseButton = document.getElementById('browse_images');
    if (browseButton) {
        browseButton.addEventListener('click', function() {
            // Open image browser modal (to be implemented)
            alert('Image browser functionality will be implemented in a future update.');
        });
    }
}

/**
 * Initialize live preview functionality
 */
function initLivePreview() {
    // This will be implemented in the WYSIWYG editor
    if (typeof updateLivePreview === 'function') {
        // Add event listeners to all inputs that should trigger a live preview update
        const inputs = document.querySelectorAll('input[type="text"], input[type="color"], select');
        
        inputs.forEach(input => {
            input.addEventListener('change', updateLivePreview);
            
            // For text inputs and color pickers, also listen for input events
            if (input.type === 'text' || input.type === 'color') {
                input.addEventListener('input', updateLivePreview);
            }
        });
    }
}

/**
 * Update live preview (placeholder for WYSIWYG editor)
 */
function updateLivePreview() {
    console.log('Live preview update triggered');
    // This will be implemented in the WYSIWYG editor
}

/**
 * Apply theme changes in real-time (for WYSIWYG editor)
 */
function applyThemeChanges(themeData) {
    return fetch('/themeeditor/apply_changes', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
        },
        body: JSON.stringify(themeData)
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            return data.css;
        } else {
            console.error('Error applying theme changes:', data.error);
            return null;
        }
    })
    .catch(error => {
        console.error('Error:', error);
        return null;
    });
}

/**
 * Save theme changes
 */
function saveThemeChanges(themeData) {
    const formData = new FormData();
    
    // Add theme metadata
    formData.append('theme_name', themeData.theme_name);
    formData.append('theme_display_name', themeData.display_name);
    formData.append('theme_description', themeData.description);
    
    // Add theme variables
    for (const [varName, value] of Object.entries(themeData.variables)) {
        formData.append('var_' + varName, value);
    }
    
    // Add special styles
    for (const [styleName, value] of Object.entries(themeData.special_styles || {})) {
        formData.append('special_style_' + styleName, value);
    }
    
    return fetch('/themeeditor/update_theme', {
        method: 'POST',
        body: formData
    })
    .then(response => {
        if (response.ok) {
            return { success: true };
        } else {
            return { success: false, error: 'Error saving theme' };
        }
    })
    .catch(error => {
        console.error('Error:', error);
        return { success: false, error: error.message };
    });
}