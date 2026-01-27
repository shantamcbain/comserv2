/**
 * AI Module Common Utilities
 * Shared functions for message formatting, HTML escaping, and clipboard operations.
 */

const AIUtils = {
    /**
     * Escapes HTML characters to prevent XSS
     * @param {string} text - Raw text to escape
     * @returns {string} - Escaped HTML
     */
    escapeHtml: function(text) {
        if (!text) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    },

    /**
     * Strips potentially dangerous or layout-breaking style tags from content
     * @param {string} content - Raw content
     * @returns {string} - Cleaned content
     */
    stripStyles: function(content) {
        if (!content) return '';
        // Remove <style>...</style> tags completely to prevent global CSS leakage
        return content.replace(/<style\b[^>]*>([\s\S]*?)<\/style>/gim, "");
    },

    /**
     * Formats message content, handling markdown-style code blocks
     * @param {string} content - Raw message content
     * @returns {string} - Formatted HTML
     */
    formatMessageContent: function(content) {
        if (!content) return '';
        
        // Split by triple backticks
        const parts = content.split(/```/);
        let html = '';
        
        for (let i = 0; i < parts.length; i++) {
            if (i % 2 === 0) {
                // Text part - strip styles then escape HTML but keep newlines
                let text = this.stripStyles(parts[i]);
                html += this.escapeHtml(text);
            } else {
                // Code part - do NOT strip styles here as they are escaped inside <code> tags
                let code = parts[i];
                // Check if there's a language specifier (e.g., ```javascript)
                const firstNewLine = code.indexOf('\n');
                if (firstNewLine !== -1 && firstNewLine < 20) {
                    // Skip the language specifier line
                    code = code.substring(firstNewLine + 1);
                }
                html += `<code class="code-block">${this.escapeHtml(code.trim())}</code>`;
            }
        }
        
        return html;
    },

    /**
     * Copies text to clipboard and provides visual feedback
     * @param {HTMLElement} btn - The button element clicked
     * @param {string} text - The text to copy
     * @param {Object} options - Configuration options for feedback
     */
    copyToClipboard: function(btn, text, options = {}) {
        if (!text) return;

        const successText = options.successText || '✅';
        const successBg = options.successBg || 'var(--success-color)';
        const successColor = options.successColor || 'var(--text-color)';
        const timeout = options.timeout || 2000;
        const changeStyle = options.changeStyle !== undefined ? options.changeStyle : (successText === 'Copied!');
        
        const originalText = btn.textContent;
        const originalBg = btn.style.background;
        const originalColor = btn.style.color;

        function showSuccess() {
            btn.textContent = successText;
            if (changeStyle) {
                btn.style.background = successBg;
                btn.style.color = successColor;
            }
            
            setTimeout(() => {
                btn.textContent = originalText;
                btn.style.background = originalBg;
                btn.style.color = originalColor;
            }, timeout);
        }

        function fallbackCopy(textToCopy) {
            try {
                const textArea = document.createElement("textarea");
                textArea.value = textToCopy;
                textArea.style.position = "fixed";
                textArea.style.left = "-999999px";
                textArea.style.top = "-999999px";
                document.body.appendChild(textArea);
                textArea.focus();
                textArea.select();
                const successful = document.execCommand('copy');
                document.body.removeChild(textArea);
                if (successful) {
                    showSuccess();
                } else {
                    console.error('Unable to copy text via fallback');
                    alert('Unable to copy. Please select and copy manually.');
                }
            } catch (err) {
                console.error('Fallback copy failed', err);
                alert('Unable to copy. Please select and copy manually.');
            }
        }

        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text).then(showSuccess).catch(err => {
                console.error('Failed to copy text via clipboard API: ', err);
                fallbackCopy(text);
            });
        } else {
            fallbackCopy(text);
        }
    }
};

// Also expose as global functions for legacy support if needed
window.AIUtils = AIUtils;
window.escapeHtml = AIUtils.escapeHtml;
window.formatMessageContent = AIUtils.formatMessageContent;
window.copyMessageText = function(btn) {
    // Legacy support for existing onclick="copyMessageText(this)"
    let textToCopy = '';
    
    // Check if it's the result page or conversation history
    const messageDiv = btn.closest('.chat-message, .ai-conversations-message, .response-section');
    if (messageDiv) {
        const contentDiv = messageDiv.querySelector('.message-content, .response-content');
        if (contentDiv) {
            textToCopy = contentDiv.getAttribute('data-raw-content') || contentDiv.textContent.trim();
        }
    }
    
    AIUtils.copyToClipboard(btn, textToCopy, {
        successText: 'Copied!',
        changeStyle: true
    });
};
