// Linux Commands Documentation JavaScript - Minimal version to avoid conflicts
// This script only adds functionality to the linux_commands.md page

document.addEventListener('DOMContentLoaded', function() {
    // Only run this script on the linux_commands page
    const contentDiv = document.querySelector('.markdown-content');
    if (!contentDiv) return;
    
    // Add a container class to scope our CSS
    contentDiv.classList.add('linux-commands-doc');
    
    // Make sure details elements work properly
    const detailsElements = contentDiv.querySelectorAll('details');
    if (detailsElements.length > 0) {
        // Details elements are already in the markdown, just ensure they work
        detailsElements.forEach(function(details) {
            // Make sure summary elements have proper click behavior
            const summary = details.querySelector('summary');
            if (summary) {
                // Ensure the summary has the proper click behavior
                summary.addEventListener('click', function(e) {
                    // This is just to ensure the native details/summary behavior works
                    // We're not adding any custom behavior to avoid conflicts
                    e.stopPropagation();
                });
            }
        });
    }
    
    // Add copy functionality to code blocks without changing the DOM structure
    const codeBlocks = contentDiv.querySelectorAll('pre');
    codeBlocks.forEach(function(codeBlock) {
        codeBlock.addEventListener('dblclick', function() {
            // Select the text in the code block
            const range = document.createRange();
            range.selectNode(codeBlock);
            window.getSelection().removeAllRanges();
            window.getSelection().addRange(range);
            
            // Copy the text
            try {
                document.execCommand('copy');
                
                // Show a temporary "Copied!" message
                const message = document.createElement('div');
                message.textContent = 'Copied!';
                message.style.position = 'absolute';
                message.style.left = (codeBlock.offsetLeft + codeBlock.offsetWidth / 2 - 30) + 'px';
                message.style.top = (codeBlock.offsetTop + codeBlock.offsetHeight / 2 - 10) + 'px';
                message.style.background = 'rgba(0,0,0,0.7)';
                message.style.color = 'white';
                message.style.padding = '5px 10px';
                message.style.borderRadius = '3px';
                message.style.zIndex = '1000';
                
                document.body.appendChild(message);
                
                // Remove the message after 1.5 seconds
                setTimeout(function() {
                    document.body.removeChild(message);
                }, 1500);
            } catch (err) {
                console.error('Could not copy text: ', err);
            }
            
            // Deselect the text
            window.getSelection().removeAllRanges();
        });
        Reference - Minimal Enhancement JavaScript
// This script only enhances the existing linux_commands.tt page without changing structure

document.addEventListener('DOMContentLoaded', function() {
    // Only run this script on the linux_commands page
    const commandCards = document.querySelectorAll('.command-card');
    if (commandCards.length === 0) return;
    
    // Add copy functionality to code blocks
    const codeElements = document.querySelectorAll('.command-card code');
    codeElements.forEach(function(codeElement) {
        // Make code elements clickable for copy
        codeElement.style.cursor = 'pointer';
        codeElement.title = 'Click to copy command';
        
        codeElement.addEventListener('click', function() {
            // Get the text content
            const text = this.textContent;
            
            // Create a temporary textarea element to copy from
            const textarea = document.createElement('textarea');
            textarea.value = text;
            textarea.setAttribute('readonly', '');
            textarea.style.position = 'absolute';
            textarea.style.left = '-9999px';
            document.body.appendChild(textarea);
            
            // Select and copy the text
            textarea.select();
            document.execCommand('copy');
            document.body.removeChild(textarea);
            
            // Visual feedback that the command was copied
            const originalBackground = this.style.backgroundColor;
            const originalTransition = this.style.transition;
            
            this.style.transition = 'background-color 0.3s';
            this.style.backgroundColor = '#e6f7e6';
            
            setTimeout(() => {
                this.style.backgroundColor = originalBackground;
                setTimeout(() => {
                    this.style.transition = originalTransition;
                }, 300);
            }, 500);
        });
    });
    
    // Add smooth scrolling to navigation links
    const navLinks = document.querySelectorAll('.nav-links a');
    navLinks.forEach(function(link) {
        link.addEventListener('click', function(e) {
            e.preventDefault();
            
            const targetId = this.getAttribute('href').substring(1);
            const targetElement = document.getElementById(targetId);
            
            if (targetElement) {
                window.scrollTo({
                    top: targetElement.offsetTop - 20,
                    behavior: 'smooth'
                });
            }
        });
        // Add a hint about double-clicking to copy
        codeBlock.title = 'Double-click to copy';
    });
});