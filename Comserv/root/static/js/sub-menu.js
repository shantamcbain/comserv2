function activateSite(site) {
    // Code to be executed when a site is clicked
    console.log('Site activated:', site);
    // Replace the console.log statement with your desired code for site activation
    // Perform the necessary action based on the site clicked (e.g., redirect, perform an operation, etc.)
}

function toggleDebugMode() {
    var debugMode = getSessionDebugMode();
    var newDebugMode = debugMode === 0 ? 1 : 0;
    setSessionDebugMode(newDebugMode);
}

function setSessionDebugMode(debugMode) {
    // Update the debug mode value on the server-side
    $.ajax({
        url: '/update_debug_mode',
        method: 'POST',
        data: { debug_mode: debugMode },
        success: function(response) {
            console.log('Debug mode updated successfully');
            // Reload the page or perform any necessary action after updating the debug mode
            location.reload();
        },
        error: function(xhr, status, error) {
            console.error('Error updating debug mode:', error);
        }
    });
}

function getSessionDebugMode() {
    // Retrieve the debug mode value from the session via AJAX
    // Since this is a static JS file, we can't use Template Toolkit syntax
    // We'll return 0 as default and let the server handle the actual state
    return 0;
}

// Add dropdown menu functionality when the document is ready
$(document).ready(function() {
    console.log('Menu initialization starting...');

    // Force horizontal menu layout
    $('.horizontal-menu').css({
        'display': 'flex',
        'flex-direction': 'row',
        'list-style-type': 'none',
        'margin': '0',
        'padding': '0',
        'width': '100%'
    });

    // Force horizontal dropdown layout
    $('.horizontal-dropdown').css({
        'position': 'relative',
        'display': 'inline-block',
        'margin-right': '5px'
    });

    // Add hover event handlers for dropdown menus
    $('.horizontal-dropdown').hover(
        function() {
            $(this).find('.dropdown-content').css('display', 'block');
            console.log('Dropdown shown');
        },
        function() {
            $(this).find('.dropdown-content').css('display', 'none');
            console.log('Dropdown hidden');
        }
    );

    // Add hover event handlers for submenus
    $('.submenu-item').hover(
        function() {
            $(this).find('.submenu').css('display', 'block');
            console.log('Submenu shown');
        },
        function() {
            $(this).find('.submenu').css('display', 'none');
            console.log('Submenu hidden');
        }
    );

    // Add click handlers for mobile
    $('.dropbtn').on('click', function(e) {
        var $dropdown = $(this).closest('.horizontal-dropdown');
        var $content = $dropdown.find('.dropdown-content');

        if ($content.is(':visible')) {
            $content.hide();
        } else {
            // Hide all other dropdowns
            $('.dropdown-content').hide();
            $content.show();
        }

        e.preventDefault();
        console.log('Dropdown clicked');
    });

    console.log('Menu dropdown functionality initialized');
});