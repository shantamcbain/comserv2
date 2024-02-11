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
    // Retrieve the debug mode value from the session or stash
    return <%= $c->stash->{debug_mode} // $c->session->{debug_mode}%>;
}