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

/* Must match the @media query in menu-theme.css. CSS owns layout.
   This file only toggles nav-open / touch-open. Never set element.style.display
   on menu nodes — inline display beats the hamburger stylesheet. */
var SMALL_SCREEN_QUERY = '(max-width: 640px)';

function isSmallScreen() {
    return window.matchMedia(SMALL_SCREEN_QUERY).matches;
}

document.addEventListener('DOMContentLoaded', function() {
    var menuList = document.getElementById('main-menu-list');
    var navToggle = document.querySelector('.nav-toggle');

    if (navToggle && menuList) {
        navToggle.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            var open = menuList.classList.toggle('nav-open');
            navToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
            navToggle.textContent = open ? '\u2715' : '\u2630';
        });
    }

    document.addEventListener('click', function(e) {
        if (!isSmallScreen()) return;
        if (e.target.closest('.nav-toggle')) return;

        var header = e.target.closest('.submenu-header');
        if (header) {
            var item = header.closest('.submenu-item');
            if (item && item.querySelector('.submenu')) {
                e.preventDefault();
                var wasOpen = item.classList.contains('touch-open');
                var parent = item.parentElement;
                if (parent) {
                    var kids = parent.children;
                    for (var i = 0; i < kids.length; i++) {
                        if (kids[i] !== item && kids[i].classList && kids[i].classList.contains('submenu-item')) {
                            kids[i].classList.remove('touch-open');
                        }
                    }
                }
                if (wasOpen) item.classList.remove('touch-open');
                else item.classList.add('touch-open');
            }
            return;
        }

        var btn = e.target.closest('.dropbtn');
        if (btn) {
            var li = btn.closest('.horizontal-dropdown');
            if (!li || !li.querySelector('.dropdown-content')) return;
            e.preventDefault();
            var wasDrop = li.classList.contains('touch-open');
            var drops = document.querySelectorAll('.horizontal-dropdown.touch-open');
            for (var j = 0; j < drops.length; j++) {
                drops[j].classList.remove('touch-open');
            }
            if (!wasDrop) li.classList.add('touch-open');
        }
    });

    window.addEventListener('resize', function() {
        if (!isSmallScreen()) {
            var open = document.querySelectorAll('.horizontal-dropdown.touch-open, .submenu-item.touch-open');
            for (var k = 0; k < open.length; k++) open[k].classList.remove('touch-open');
            if (menuList) menuList.classList.remove('nav-open');
            if (navToggle) {
                navToggle.setAttribute('aria-expanded', 'false');
                navToggle.textContent = '\u2630';
            }
        }
    });
});