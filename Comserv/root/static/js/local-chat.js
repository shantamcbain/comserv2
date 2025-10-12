/**
 * Live Chat Implementation
 * A chat widget that connects to the server API
 */

(function() {
    // Configuration
    const config = {
        apiEndpoints: {
            generateResponse: '/ai/generate'
        },
        maxRetries: 3,      // Max retries for failed API calls
    };
    
    // State
    let state = {
        retryCount: 0,
        isOpen: false
    };
    
    // Create chat widget elements
    function createChatWidget() {
        // Create main container
        const chatContainer = document.createElement('div');
        chatContainer.id = 'local-chat-widget';
        chatContainer.className = 'local-chat-widget';
        
        // Create chat button
        const chatButton = document.createElement('button');
        chatButton.id = 'chat-button';
        chatButton.className = 'chat-button';
        chatButton.innerHTML = '<span class="chat-icon">🤖</span> Chat with AI';
        
        // Create chat panel (initially hidden)
        const chatPanel = document.createElement('div');
        chatPanel.id = 'chat-panel';
        chatPanel.className = 'chat-panel';
        chatPanel.style.display = 'none';
        
        // Create chat header
        const chatHeader = document.createElement('div');
        chatHeader.className = 'chat-header';
        chatHeader.innerHTML = '<h3>AI Assistant</h3><button id="close-chat">×</button>';
        
        // Create chat messages area
        const chatMessages = document.createElement('div');
        chatMessages.id = 'chat-messages';
        chatMessages.className = 'chat-messages';
        
        // Add welcome message
        const welcomeMessage = document.createElement('div');
        welcomeMessage.className = 'message system-message';
        welcomeMessage.textContent = 'Hello! I\'m your AI assistant. Ask me anything and I\'ll help you right away.';
        chatMessages.appendChild(welcomeMessage);
        
        // Create chat input area
        const chatInput = document.createElement('div');
        chatInput.className = 'chat-input';
        chatInput.innerHTML = '<textarea id="message-input" placeholder="Type your message..."></textarea>' +
                             '<button id="send-message">Send</button>';
        
        // Create status indicator
        const statusIndicator = document.createElement('div');
        statusIndicator.id = 'chat-status';
        statusIndicator.className = 'chat-status';
        statusIndicator.textContent = 'AI Ready';
        
        // Assemble the chat panel
        chatPanel.appendChild(chatHeader);
        chatPanel.appendChild(chatMessages);
        chatPanel.appendChild(statusIndicator);
        chatPanel.appendChild(chatInput);
        
        // Add everything to the container
        chatContainer.appendChild(chatButton);
        chatContainer.appendChild(chatPanel);
        
        // Add the container to the body
        document.body.appendChild(chatContainer);
        
        // Add event listeners
        chatButton.addEventListener('click', function() {
            openChat();
        });
        
        document.getElementById('close-chat').addEventListener('click', function() {
            closeChat();
        });
        
        document.getElementById('send-message').addEventListener('click', sendMessage);
        document.getElementById('message-input').addEventListener('keypress', function(e) {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                sendMessage();
            }
        });
    }
    
    // Open chat panel
    function openChat() {
        const chatPanel = document.getElementById('chat-panel');
        const chatButton = document.getElementById('chat-button');
        
        chatPanel.style.display = 'flex';
        chatButton.style.display = 'none';
        state.isOpen = true;
        
        // Focus on the input field
        const messageInput = document.getElementById('message-input');
        messageInput.focus();
    }
    
    // Close chat panel
    function closeChat() {
        const chatPanel = document.getElementById('chat-panel');
        const chatButton = document.getElementById('chat-button');
        
        chatPanel.style.display = 'none';
        chatButton.style.display = 'flex';
        state.isOpen = false;
    }
    
    // Function to query AI and get response
    function queryAI(prompt) {
        const statusIndicator = document.getElementById('chat-status');
        statusIndicator.textContent = 'AI is thinking...';
        statusIndicator.className = 'chat-status processing';
        
        // Show a loading message
        const loadingMessage = document.createElement('div');
        loadingMessage.className = 'message ai-message loading';
        loadingMessage.id = 'ai-loading';
        loadingMessage.innerHTML = '<span class="loading-dots">●●●</span> AI is thinking...';
        document.getElementById('chat-messages').appendChild(loadingMessage);
       document.getElementById('chat-messages').scrollTop = document.getElementById('chat-messages').scrollHeight;
        
        // Send to AI
        const formData = new FormData();
        formData.append('prompt', prompt);
        
        fetch(config.apiEndpoints.generateResponse, {
            method: 'POST',
            body: formData
        })
         .then(response => {
            if (!response.ok) {
                throw new Error('Network response was not ok');
            }
            return response.json();
        })
        .then(data => {
            // Remove loading message
            const loading = document.getElementById('ai-loading');
            if (loading) {
                loading.remove();
            }
            
            if (data.success) {
                // Reset retry counter on success
                state.retryCount = 0;
                
                // Update status
                statusIndicator.textContent = 'AI Ready';
                statusIndicator.className = 'chat-status connected';
                
                // Add AI response
                addMessage(data.response, 'ai-message');
            } else {
                console.error('Error getting AI response:', data.error);
                statusIndicator.textContent = 'AI Error';
                statusIndicator.className = 'chat-status error';
                
                // Show error in chat
                addMessage('Sorry, I encountered an error. Please try again.', 'error-message');
            }
        })
        .catch(error => {
            // Remove loading message
            const loading = document.getElementById('ai-loading');
            if (loading) {
                loading.remove();
            }
            
            console.error('Error querying AI:', error);
            statusIndicator.textContent = 'AI Error';
            statusIndicator.className = 'chat-status error';
            
            // Show error in chat
            addMessage('Sorry, I\'m having trouble connecting. Please try again.', 'error-message');
        });
    }
    
    // Function to send a message
    function sendMessage() {
        const messageInput = document.getElementById('message-input');
        const message = messageInput.value.trim();
        
        if (message) {
            // Add user message to chat immediately
            addMessage(message, 'user-message');
            
            // Clear input
            messageInput.value = '';
            
            // Query AI for response
            queryAI(message);
        }
    }
    
    // Function to add a message to the chat
    function addMessage(text, className) {
        const chatMessages = document.getElementById('chat-messages');
        const messageElement = document.createElement('div');
        messageElement.className = 'message ' + className;
        messageElement.textContent = text;
        chatMessages.appendChild(messageElement);
        chatMessages.scrollTop = chatMessages.scrollHeight;
    }
    
    // Add CSS styles
    function addChatStyles() {
        const style = document.createElement('style');
        style.textContent = `
            .local-chat-widget {
                position: fixed;
                bottom: 20px;
                right: 20px;
                z-index: 1000;
                font-family: inherit;
            }
            
            .chat-button {
                background-color: var(--primary-color, #007bff);
                color: var(--text-on-primary, white);
                border: none;
                border-radius: 50px;
                padding: 10px 20px;
                cursor: pointer;
                display: flex;
                align-items: center;
                box-shadow: 0 2px 5px rgba(0,0,0,0.2);
                font-family: inherit;
            }
            
            .chat-icon {
                margin-right: 8px;
                font-size: 1.2em;
            }
            
            .chat-panel {
                width: 300px;
                height: 400px;
                background-color: var(--background-color, white);
                border-radius: 10px;
                box-shadow: 0 5px 15px rgba(0,0,0,0.2);
                display: flex;
                flex-direction: column;
                font-family: inherit;
            }
            
            .chat-header {
                background-color: var(--primary-color, #007bff);
                color: var(--text-on-primary, white);
                padding: 10px 15px;
                border-top-left-radius: 10px;
                border-top-right-radius: 10px;
                display: flex;
                justify-content: space-between;
                align-items: center;
            }
            
            .chat-header h3 {
                margin: 0;
                font-size: 16px;
            }
            
            #close-chat {
                background: none;
                border: none;
                color: white;
                font-size: 20px;
                cursor: pointer;
            }
            
            .chat-messages {
                flex-grow: 1;
                padding: 15px;
                overflow-y: auto;
                background-color: #f8f9fa;
            }
            
            .message {
                margin-bottom: 10px;
                padding: 8px 12px;
                border-radius: 18px;
                max-width: 80%;
                word-wrap: break-word;
            }
            
            .system-message {
                background-color: #e9ecef;
                color: #212529;
                align-self: flex-start;
                margin-right: auto;
                border-bottom-left-radius: 5px;
            }
            
            .user-message {
                background-color: var(--primary-color, #007bff);
                color: var(--text-on-primary, white);
                align-self: flex-end;
                margin-left: auto;
                border-bottom-right-radius: 5px;
            }
            
            .ai-message {
                background-color: #e3f2fd;
                color: #1976d2;
                align-self: flex-start;
                margin-right: auto;
                border-bottom-left-radius: 5px;
                border-left: 3px solid #2196f3;
            }
            
            .ai-message.loading {
                background-color: #f5f5f5;
                color: #666;
                font-style: italic;
            }
            
            .error-message {
                background-color: #f8d7da;
                color: #721c24;
                align-self: center;
                margin: 5px auto;
                font-size: 0.9em;
            }
            
            .chat-status {
                padding: 5px 10px;
                font-size: 0.8em;
                text-align: center;
                background-color: #f8f9fa;
                border-top: 1px solid #dee2e6;
            }
            
            .chat-status.connected {
                color: #28a745;
            }
            
            .chat-status.error {
                color: #dc3545;
            }
            
            .chat-status.processing {
                color: #ffc107;
            }
            
            .loading-dots {
                display: inline-block;
                animation: loadingDots 1.5s infinite;
            }
            
            @keyframes loadingDots {
                0%, 20% { opacity: 0.2; }
                50% { opacity: 1; }
                100% { opacity: 0.2; }
            }
            
            .chat-input {
                padding: 10px;
                border-top: 1px solid #dee2e6;
                display: flex;
            }
            
            #message-input {
                flex-grow: 1;
                border: 1px solid #ced4da;
                border-radius: 4px;
                padding: 8px;
                resize: none;
                height: 40px;
                margin-right: 8px;
            }
            
            #send-message {
                background-color: var(--primary-color, #007bff);
                color: var(--text-on-primary, white);
                border: none;
                border-radius: 4px;
                padding: 8px 15px;
                cursor: pointer;
                font-family: inherit;
            }
            
            #send-message:hover {
                background-color: var(--primary-color-dark, #0069d9);
                color: var(--text-on-primary, white);
            }
            
            #send-message:disabled {
                background-color: #6c757d;
                cursor: not-allowed;
            }
        `;
        document.head.appendChild(style);
    }
    
    // Initialize chat when the DOM is loaded
    document.addEventListener('DOMContentLoaded', function() {
        addChatStyles();
        createChatWidget();
    });
})();