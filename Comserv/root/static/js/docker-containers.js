// docker-containers.js
// Minimal JS for Docker page - respects global themes

function refreshContainers() {
    console.log("Refreshing containers...");
    // TODO: Call your existing Perl refresh logic
}

function rebuildContainerDirect(containerName) {
    if (confirm(`Rebuild ${containerName}?`)) {
        console.log(`Rebuilding ${containerName}...`);
        // TODO: Call Perl endpoint
    }
}

document.addEventListener('DOMContentLoaded', function() {
    refreshContainers();
});