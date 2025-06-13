/**
 * Menu Position Handler
 * 
 * This script ensures that submenus don't go off-screen by dynamically
 * adjusting their position based on the viewport.
 * 
 * Version: 1.0
 * Date: 2025-09-20
 * Author: Development Team
 */

document.addEventListener('DOMContentLoaded', function() {
    // Function to check and adjust submenu positions
    function adjustSubmenuPositions() {
        const submenuItems = document.querySelectorAll('.submenu-item');
        
        submenuItems.forEach(function(item) {
            const submenu = item.querySelector('.submenu');
            if (!submenu) return;
            
            // Reset position to default first
            submenu.style.left = '100%';
            submenu.style.right = 'auto';
            
            // Add event listener to check position when hovering
            item.addEventListener('mouseenter', function() {
                const rect = submenu.getBoundingClientRect();
                const viewportWidth = window.innerWidth;
                
                // If submenu would go off the right edge of the screen
                if (rect.right > viewportWidth) {
                    submenu.style.left = 'auto';
                    submenu.style.right = '100%';
                } else {
                    submenu.style.left = '100%';
                    submenu.style.right = 'auto';
                }
            });
        });
    }
    
    // Run on page load
    adjustSubmenuPositions();
    
    // Also run when window is resized
    window.addEventListener('resize', adjustSubmenuPositions);
});