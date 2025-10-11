/**
 * Back to Top Button Functionality
 * 
 * This script adds a "Back to Top" button that appears when the user scrolls down
 * and smoothly scrolls back to the top of the page when clicked.
 */
$(document).ready(function() {
    // Show/hide the button based on scroll position
    $(window).scroll(function() {
        if ($(this).scrollTop() > 300) {
            $('#back-to-top').fadeIn();
        } else {
            $('#back-to-top').fadeOut();
        }
    });
    
    // Smooth scroll to top when button is clicked
    $('#back-to-top').click(function() {
        $('html, body').animate({scrollTop: 0}, 800);
        return false;
    });
    
    // Initially hide the button
    $('#back-to-top').hide();
    
    // Log to console for debugging
    console.log('Back to Top button initialized');
    
    // Accessibility enhancement - add keyboard support
    $(document).keydown(function(e) {
        // Alt + Home key combination
        if (e.altKey && e.keyCode === 36) {
            $('html, body').animate({scrollTop: 0}, 800);
            return false;
        }
    });
});