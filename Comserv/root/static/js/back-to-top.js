// Back to Top functionality is now handled in layout.tt
// This file is kept for backward compatibility and custom enhancements

document.addEventListener('DOMContentLoaded', function() {
    var btn = document.getElementById('back-to-top');
    if (!btn) {
        console.log('Back to Top button not found - it should be in layout.tt');
        return;
    }
    console.log('Back to Top button initialized');
});