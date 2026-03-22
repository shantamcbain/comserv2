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
     * Converts plain text containing markdown links and bare URLs into safe HTML.
     * Renders [label](url) as <a> tags and bare http(s) URLs as clickable links.
     * Converts newlines to <br> and escapes all other HTML.
     * @param {string} text - Plain text (NOT yet HTML-escaped)
     * @returns {string} - Safe HTML with clickable links
     */
    renderTextWithLinks: function(text) {
        if (!text) return '';
        // Tokenise: split on markdown links [label](url) and bare URLs
        const TOKEN_RE = /\[([^\]]+)\]\((https?:\/\/[^)]+)\)|(https?:\/\/[^\s<>")\]]+)/g;
        let result = '';
        let lastIndex = 0;
        let match;
        while ((match = TOKEN_RE.exec(text)) !== null) {
            // Escape and flush the plain text before this match
            if (match.index > lastIndex) {
                result += this.escapeHtml(text.slice(lastIndex, match.index));
            }
            if (match[1] !== undefined) {
                // Markdown link: [label](url)
                const label = this.escapeHtml(match[1]);
                const url   = this.escapeHtml(match[2]);
                const sameOrigin = url.startsWith(window.location.origin + '/') || url.startsWith('/');
                const target = sameOrigin ? '_self' : '_blank';
                result += `<a href="${url}" target="${target}" rel="noopener noreferrer">${label}</a>`;
            } else {
                // Bare URL
                const url = this.escapeHtml(match[3]);
                const sameOrigin = url.startsWith(window.location.origin + '/');
                const target = sameOrigin ? '_self' : '_blank';
                result += `<a href="${url}" target="${target}" rel="noopener noreferrer">${url}</a>`;
            }
            lastIndex = TOKEN_RE.lastIndex;
        }
        // Flush any remaining plain text
        if (lastIndex < text.length) {
            result += this.escapeHtml(text.slice(lastIndex));
        }
        // Convert newlines to <br>
        return result.replace(/\n/g, '<br>');
    },

    /**
     * Formats message content, handling markdown-style code blocks,
     * markdown links [text](url), bare URLs, and newlines.
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
                // Text part — strip style tags, then render links and newlines
                let text = this.stripStyles(parts[i]);
                html += this.renderTextWithLinks(text);
            } else {
                // Code block — language specifier on first line is stripped
                let code = parts[i];
                const firstNewLine = code.indexOf('\n');
                if (firstNewLine !== -1 && firstNewLine < 20) {
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
