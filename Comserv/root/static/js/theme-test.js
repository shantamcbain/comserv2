// Theme Test JavaScript
document.addEventListener('DOMContentLoaded', function() {
    console.log('Theme test script loaded');
    
    // Check if the background image is loaded
    const body = document.querySelector('body');
    const computedStyle = window.getComputedStyle(body);
    const backgroundImage = computedStyle.backgroundImage;
    
    console.log('Background image:', backgroundImage);
    
    // Display the background image info on the page
    const bgInfoElement = document.getElementById('bg-info');
    if (bgInfoElement) {
        bgInfoElement.textContent = backgroundImage;
        
        // Check if it contains the honey2.jpg image
        if (backgroundImage.includes('honey2.jpg')) {
            bgInfoElement.style.color = 'green';
            bgInfoElement.textContent += ' ✓ (Background image is correctly set)';
        } else {
            bgInfoElement.style.color = 'red';
            bgInfoElement.textContent += ' ✗ (Background image is not set correctly)';
        }
    }
    
    // Check if the CSS file is loaded
    const cssLinkElement = document.querySelector('link[href*="apis.css"]');
    const cssInfoElement = document.getElementById('css-info');
    
    if (cssInfoElement) {
        if (cssLinkElement) {
            cssInfoElement.textContent = cssLinkElement.getAttribute('href');
            cssInfoElement.style.color = 'green';
            cssInfoElement.textContent += ' ✓ (CSS file is loaded)';
        } else {
            cssInfoElement.textContent = 'No apis.css file found in the document';
            cssInfoElement.style.color = 'red';
        }
    }
});