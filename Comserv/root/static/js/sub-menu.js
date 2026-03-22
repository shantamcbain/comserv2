function activateSite(site) {
    console.log('Site activated:', site);
}

function toggleDebugMode() {
    var debugMode = getSessionDebugMode();
    var newDebugMode = debugMode === 0 ? 1 : 0;
    setSessionDebugMode(newDebugMode);
}

function setSessionDebugMode(debugMode) {
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/update_debug_mode', true);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onload = function() {
        if (xhr.status === 200) {
            console.log('Debug mode updated successfully');
            location.reload();
        }
    };
    xhr.onerror = function() {
        console.error('Error updating debug mode');
    };
    xhr.send('debug_mode=' + debugMode);
}

function getSessionDebugMode() {
    const debugMode = document.documentElement.getAttribute('data-debug-mode');
    return debugMode ? parseInt(debugMode) : (sessionStorage.getItem('debug_mode') ? parseInt(sessionStorage.getItem('debug_mode')) : 0);
}

document.addEventListener('DOMContentLoaded', function() {
    console.log('Menu initialization starting...');

    var horizontalMenus = document.querySelectorAll('.horizontal-menu');
    horizontalMenus.forEach(function(menu) {
        menu.style.display = 'flex';
        menu.style.flexDirection = 'row';
        menu.style.listStyleType = 'none';
        menu.style.margin = '0';
        menu.style.padding = '0';
        menu.style.width = '100%';
    });

    var dropdowns = document.querySelectorAll('.horizontal-dropdown');
    dropdowns.forEach(function(dropdown) {
        dropdown.style.position = 'relative';
        dropdown.style.display = 'inline-block';
        dropdown.style.marginRight = '5px';

        dropdown.addEventListener('mouseenter', function() {
            var content = this.querySelector('.dropdown-content');
            if (content) {
                content.style.display = 'block';
                content.style.opacity = '1';
                content.style.visibility = 'visible';
                console.log('Dropdown shown');
            }
        });

        dropdown.addEventListener('mouseleave', function() {
            var content = this.querySelector('.dropdown-content');
            if (content) {
                content.style.display = 'none';
                content.style.opacity = '0';
                content.style.visibility = 'hidden';
                console.log('Dropdown hidden');
            }
        });
    });

    var submenus = document.querySelectorAll('.submenu-item');
    submenus.forEach(function(submenu) {
        submenu.addEventListener('mouseenter', function() {
            var submenuContent = this.querySelector('.submenu');
            if (submenuContent) {
                submenuContent.style.display = 'block';
                submenuContent.style.opacity = '1';
                submenuContent.style.visibility = 'visible';
                console.log('Submenu shown');
            }
        });

        submenu.addEventListener('mouseleave', function() {
            var submenuContent = this.querySelector('.submenu');
            if (submenuContent) {
                submenuContent.style.display = 'none';
                submenuContent.style.opacity = '0';
                submenuContent.style.visibility = 'hidden';
                console.log('Submenu hidden');
            }
        });
    });

    var dropbtns = document.querySelectorAll('.dropbtn');
    dropbtns.forEach(function(dropbtn) {
        dropbtn.addEventListener('click', function(e) {
            var href = this.getAttribute('href');
            
            if (!href || href === '#') {
                e.preventDefault();
                
                var dropdown = this.closest('.horizontal-dropdown');
                var content = dropdown.querySelector('.dropdown-content');
                
                if (content.style.display === 'block') {
                    content.style.display = 'none';
                    content.style.opacity = '0';
                    content.style.visibility = 'hidden';
                } else {
                    document.querySelectorAll('.dropdown-content').forEach(function(dc) {
                        dc.style.display = 'none';
                        dc.style.opacity = '0';
                        dc.style.visibility = 'hidden';
                    });
                    content.style.display = 'block';
                    content.style.opacity = '1';
                    content.style.visibility = 'visible';
                }
                console.log('Dropdown toggled');
            } else {
                console.log('Navigating to: ' + href);
            }
        });
    });

    console.log('Menu dropdown functionality initialized');
});