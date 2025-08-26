/**
 * Main menu functionality for Comserv application
 * No external dependencies - pure vanilla JavaScript
 */

// Main menu functionality
document.addEventListener('DOMContentLoaded', function() {
    console.log('Main menu initialization...');
    
    // Initialize mobile menu toggle if it exists
    const mobileMenuToggle = document.getElementById('mobile-menu-toggle');
    if (mobileMenuToggle) {
        mobileMenuToggle.addEventListener('click', function() {
            const mainNav = document.querySelector('.main-nav');
            if (mainNav) {
                if (mainNav.classList.contains('mobile-visible')) {
                    mainNav.classList.remove('mobile-visible');
                } else {
                    mainNav.classList.add('mobile-visible');
                }
            }
        });
    }
    
    // Add accessibility features
    const menuItems = document.querySelectorAll('.menu-item');
    menuItems.forEach(function(item) {
        // Add keyboard navigation
        item.addEventListener('keydown', function(e) {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                this.click();
            }
        });
        
        // Add ARIA attributes for accessibility
        if (!item.getAttribute('role')) {
            item.setAttribute('role', 'menuitem');
        }
        
        // Add tabindex if not present
        if (!item.getAttribute('tabindex')) {
            item.setAttribute('tabindex', '0');
        }
    });
    
    // Add active class to current page link
    const currentPath = window.location.pathname;
    const links = document.querySelectorAll('a');
    links.forEach(function(link) {
        if (link.getAttribute('href') === currentPath) {
            link.classList.add('active');
            
            // Also add active class to parent menu items
            const parentMenuItem = link.closest('.menu-item');
            if (parentMenuItem) {
                parentMenuItem.classList.add('active');
            }
        }
    });
    
    console.log('Main menu initialization complete');
});