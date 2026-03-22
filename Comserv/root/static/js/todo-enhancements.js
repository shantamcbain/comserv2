/**
 * Todo Page Enhancements
 * Provides interactive functionality for the todo system
 */

// Overdue todos toggle functionality
function toggleOverdueSection() {
    const overdueList = document.getElementById('overdue-list');
    const toggleIcon = document.getElementById('overdue-toggle-icon');
    
    if (overdueList && toggleIcon) {
        if (overdueList.style.display === 'none') {
            overdueList.style.display = 'block';
            toggleIcon.innerHTML = '&#9650;'; // Up arrow
            // Store preference in localStorage
            localStorage.setItem('overdue-section-expanded', 'true');
        } else {
            overdueList.style.display = 'none';
            toggleIcon.innerHTML = '&#9660;'; // Down arrow
            // Store preference in localStorage
            localStorage.setItem('overdue-section-expanded', 'false');
        }
    }
}

// Initialize overdue section state from localStorage
function initializeOverdueSection() {
    const overdueList = document.getElementById('overdue-list');
    const toggleIcon = document.getElementById('overdue-toggle-icon');
    const isExpanded = localStorage.getItem('overdue-section-expanded');
    
    if (overdueList && toggleIcon) {
        // Always default to collapsed (normally closed)
        if (isExpanded === 'true') {
            overdueList.style.display = 'block';
            toggleIcon.innerHTML = '&#9650;'; // Up arrow
        } else {
            overdueList.style.display = 'none';
            toggleIcon.innerHTML = '&#9660;'; // Down arrow
        }
    }
}

// Table row highlighting functionality
function initializeTableHighlighting() {
    document.querySelectorAll('.week-view-table tbody tr').forEach(row => {
        row.addEventListener('click', () => {
            row.classList.toggle('highlight');
        });
    });
}

// Comprehensive site-specific icon management system
function getSiteIcon(siteName, iconType, priority = null, status = null) {
    const iconMaps = {
        'BMaster': {
            // Priority icons
            'priority-high': '🐝🔥',
            'priority-medium': '🐝⚡',
            'priority-normal': '🐝📋',
            'priority-default': '🐝',
            // Status icons
            'status-new': '🐝🆕',
            'status-progress': '🐝⚡',
            'status-completed': '🐝✅',
            'status-default': '🐝',
            // Action icons
            'warning': '🐝⚠️',
            'success': '🐝✅',
            'info': '🐝ℹ️',
            'ai-create': '🐝🤖',
            'overdue': '🐝⚠️'
        },
        'CSC': {
            // Priority icons
            'priority-high': '⚙️🔥',
            'priority-medium': '⚙️⚡',
            'priority-normal': '⚙️📋',
            'priority-default': '⚙️',
            // Status icons
            'status-new': '⚙️🆕',
            'status-progress': '⚙️⚡',
            'status-completed': '⚙️✅',
            'status-default': '⚙️',
            // Action icons
            'warning': '⚙️⚠️',
            'success': '⚙️✅',
            'info': '⚙️ℹ️',
            'ai-create': '⚙️🤖',
            'overdue': '⚙️⚠️'
        },
        'default': {
            // Priority icons with proper defaults
            'priority-high': '🔥 High',
            'priority-medium': '⚡ Medium',
            'priority-normal': '📋 Normal',
            'priority-default': '📋',
            // Status icons with proper defaults
            'status-new': '🆕 New',
            'status-progress': '⚡ In Progress',
            'status-completed': '✅ Completed',
            'status-default': '📋',
            // Action icons - minimal icons for default site
            'warning': '⚠️',
            'success': '✅',
            'info': 'ℹ️',
            'ai-create': '🤖',
            'overdue': '⚠️'
        }
    };
    
    const siteMap = iconMaps[siteName] || iconMaps['default'];
    
    // Handle priority-specific requests
    if (iconType === 'priority' && priority !== null) {
        if (priority == 1) return siteMap['priority-high'] || siteMap['priority-default'];
        if (priority == 2) return siteMap['priority-medium'] || siteMap['priority-default'];
        if (priority == 3) return siteMap['priority-normal'] || siteMap['priority-default'];
        return siteMap['priority-default'];
    }
    
    // Handle status-specific requests
    if (iconType === 'status' && status !== null) {
        if (status == 1) return siteMap['status-new'] || siteMap['status-default'];
        if (status == 2) return siteMap['status-progress'] || siteMap['status-default'];
        if (status == 3) return siteMap['status-completed'] || siteMap['status-default'];
        return siteMap['status-default'];
    }
    
    // Return specific icon or fallback to default
    return siteMap[iconType] || iconMaps['default'][iconType] || '';
}

// Initialize site-specific icons
function initializeSiteIcons() {
    // Update overdue section icons
    document.querySelectorAll('.overdue-icon-text').forEach(element => {
        const siteName = element.getAttribute('data-site');
        const icon = getSiteIcon(siteName, 'overdue');
        console.log('Overdue icon debug:', {siteName, icon, iconLength: icon ? icon.length : 0});
        if (icon && icon.trim() !== '' && siteName !== 'default') {
            element.textContent = icon + ' Overdue TODOs';
        } else {
            element.textContent = 'Overdue TODOs';
        }
    });
    
    // Update AI create button icons
    document.querySelectorAll('.ai-create-icon-text').forEach(element => {
        const siteName = element.getAttribute('data-site');
        const icon = getSiteIcon(siteName, 'ai-create');
        if (icon && icon.trim() !== '' && siteName !== 'default') {
            element.textContent = icon + ' AI Create Todo';
        } else {
            element.textContent = 'AI Create Todo';
        }
    });
    
    // Update priority icons
    document.querySelectorAll('.priority-icon-text').forEach(element => {
        const siteName = element.getAttribute('data-site');
        const priority = parseInt(element.getAttribute('data-priority'));
        const iconText = getSiteIcon(siteName, 'priority', priority);
        if (iconText) {
            element.textContent = iconText;
        }
    });
    
    // Update status icons
    document.querySelectorAll('.status-icon-text').forEach(element => {
        const siteName = element.getAttribute('data-site');
        const status = parseInt(element.getAttribute('data-status'));
        const iconText = getSiteIcon(siteName, 'status', null, status);
        if (iconText) {
            element.textContent = iconText;
        }
    });
}

// Collapsible todo container functionality
function toggleTodoDetails(todoId) {
    const detailsElement = document.getElementById('todo-details-' + todoId);
    const iconElement = document.getElementById('todo-icon-' + todoId);
    
    if (detailsElement && iconElement) {
        if (detailsElement.style.display === 'none') {
            detailsElement.style.display = 'block';
            iconElement.classList.add('expanded');
            iconElement.innerHTML = '&#9650;'; // Up arrow
            // Store expanded state
            localStorage.setItem('todo-expanded-' + todoId, 'true');
        } else {
            detailsElement.style.display = 'none';
            iconElement.classList.remove('expanded');
            iconElement.innerHTML = '&#9660;'; // Down arrow
            // Store collapsed state
            localStorage.setItem('todo-expanded-' + todoId, 'false');
        }
    }
}

// Initialize todo container states from localStorage
function initializeTodoContainers() {
    document.querySelectorAll('.feature-card[data-todo-id]').forEach(container => {
        const todoId = container.getAttribute('data-todo-id');
        if (todoId) {
            const isExpanded = localStorage.getItem('todo-expanded-' + todoId);
            const detailsElement = document.getElementById('todo-details-' + todoId);
            const iconElement = document.getElementById('todo-icon-' + todoId);
            
            if (detailsElement && iconElement) {
                if (isExpanded === 'true') {
                    detailsElement.style.display = 'block';
                    iconElement.classList.add('expanded');
                    iconElement.innerHTML = '&#9650;'; // Up arrow
                } else {
                    detailsElement.style.display = 'none';
                    iconElement.classList.remove('expanded');
                    iconElement.innerHTML = '&#9660;'; // Down arrow
                }
            }
        }
    });
}

// Floating header and back-to-top functionality
function initializeFloatingElements() {
    // Create floating header
    const floatingHeader = document.createElement('div');
    floatingHeader.className = 'todo-floating-header';
    floatingHeader.innerHTML = `
        <div class="floating-header-fields">
            <div class="floating-header-field">Subject</div>
            <div class="floating-header-field">Priority</div>
            <div class="floating-header-field">Status</div>
            <div class="floating-header-field">Due Date</div>
            <div class="floating-header-field">Actions</div>
        </div>
        <button class="btn btn-secondary btn-sm" onclick="window.scrollTo({top: 0, behavior: 'smooth'})">
            ↑ Top
        </button>
    `;
    document.body.appendChild(floatingHeader);
    
    // Create back-to-top button
    const backToTop = document.createElement('button');
    backToTop.className = 'back-to-top';
    backToTop.innerHTML = '↑';
    backToTop.title = 'Back to top';
    backToTop.onclick = () => window.scrollTo({top: 0, behavior: 'smooth'});
    document.body.appendChild(backToTop);
    
    // Handle scroll events
    let ticking = false;
    function handleScroll() {
        if (!ticking) {
            requestAnimationFrame(() => {
                const scrollTop = window.pageYOffset || document.documentElement.scrollTop;
                const showThreshold = 200;
                
                // Show/hide floating header
                if (scrollTop > showThreshold) {
                    floatingHeader.classList.add('visible');
                    backToTop.classList.add('visible');
                } else {
                    floatingHeader.classList.remove('visible');
                    backToTop.classList.remove('visible');
                }
                
                ticking = false;
            });
            ticking = true;
        }
    }
    
    window.addEventListener('scroll', handleScroll);
}

// Initialize all todo enhancements when DOM is ready
document.addEventListener('DOMContentLoaded', function() {
    initializeOverdueSection();
    initializeTableHighlighting();
    initializeSiteIcons();
    initializeTodoContainers();
    initializeFloatingElements();
    
    // Add smooth transitions to overdue section
    const overdueList = document.getElementById('overdue-list');
    if (overdueList) {
        overdueList.style.transition = 'all 0.3s ease';
    }
    
    console.log('Todo enhancements initialized');
});

// Export functions for global access
window.todoEnhancements = {
    toggleOverdueSection: toggleOverdueSection,
    toggleTodoDetails: toggleTodoDetails,
    getSiteIcon: getSiteIcon
};