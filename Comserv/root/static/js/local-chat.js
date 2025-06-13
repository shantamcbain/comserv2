/**
 * Live Chat Implementation
 * A chat widget that connects to the server API
 */

(function() {
    // Configuration
    const config = {
        apiEndpoints: {
            sendMessage: '/chat/send_message',
            getMessages: '/chat/get_messages'
        },
        pollInterval: 5000, // How often to check for new messages (ms)
        maxRetries: 3,      // Max retries for failed API calls
    };
    
    // State
    let state = {
        lastMessageId: 0,
        isPolling: false,
        retryCount: 0,
        pollTimer: null,
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
        chatButton.innerHTML = '<span class="chat-icon">💬</span> Chat with us';
        
        // Create chat panel (initially hidden)
        const chatPanel = document.createElement('div');
        chatPanel.id = 'chat-panel';
        chatPanel.className = 'chat-panel';
        chatPanel.style.display = 'none';
        
        // Create chat header
        const chatHeader = document.createElement('div');
        chatHeader.className = 'chat-header';
        chatHeader.innerHTML = '<h3>Chat Support</h3><button id="close-chat">×</button>';
        
        // Create chat messages area
        const chatMessages = document.createElement('div');
        chatMessages.id = 'chat-messages';
        chatMessages.className = 'chat-messages';
        
        // Add welcome message
        const welcomeMessage = document.createElement('div');
        welcomeMessage.className = 'message system-message';
        welcomeMessage.textContent = 'Welcome to our chat support. Please leave a message and we\'ll get back to you soon.';
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
        statusIndicator.textContent = 'Connected';
        
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
    
    // Open chat panel and start polling
    function openChat() {
        const chatPanel = document.getElementById('chat-panel');
        const chatButton = document.getElementById('chat-button');
        
        chatPanel.style.display = 'flex';
        chatButton.style.display = 'none';
        state.isOpen = true;
        
        // Start polling for messages
        startPolling();
        
        // Load existing messages
        fetchMessages();
    }
    
    // Close chat panel and stop polling
    function closeChat() {
        const chatPanel = document.getElementById('chat-panel');
        const chatButton = document.getElementById('chat-button');
        
        chatPanel.style.display = 'none';
        chatButton.style.display = 'flex';
        state.isOpen = false;
        
        // Stop polling
        stopPolling();
    }
    
    // Start polling for new messages
    function startPolling() {
        if (!state.isPolling) {
            state.isPolling = true;
            state.pollTimer = setInterval(fetchMessages, config.pollInterval);
        }
    }
    
    // Stop polling for new messages
    function stopPolling() {
        if (state.isPolling) {
            clearInterval(state.pollTimer);
            state.isPolling = false;
        }
    }
    
    // Fetch messages from the server
    function fetchMessages() {
        const statusIndicator = document.getElementById('chat-status');
        statusIndicator.textContent = 'Connecting...';
        
        fetch(config.apiEndpoints.getMessages + '?last_id=' + state.lastMessageId)
            .then(response => {
                if (!response.ok) {
                    throw new Error('Network response was not ok');
                }
                return response.json();
            })
            .then(data => {
                if (data.success) {
                    // Reset retry counter on success
                    state.retryCount = 0;
                    
                    // Update status
                    statusIndicator.textContent = 'Connected';
                    statusIndicator.className = 'chat-status connected';
                    
                    // Process new messages
                    if (data.messages && data.messages.length > 0) {
                        data.messages.forEach(msg => {
                            const className = msg.is_system_message ? 'system-message' : 'user-message';
                            addMessage(msg.message, className);
                            
                            // Update last message ID
                            if (msg.id > state.lastMessageId) {
                                state.lastMessageId = msg.id;
                            }
                        });
                    }
                } else {
                    console.error('Error fetching messages:', data.error);
                    statusIndicator.textContent = 'Connection error';
                    statusIndicator.className = 'chat-status error';
                }
            })
            .catch(error => {
                console.error('Error fetching messages:', error);
                statusIndicator.textContent = 'Connection error';
                statusIndicator.className = 'chat-status error';
                
                // Retry logic
                state.retryCount++;
                if (state.retryCount > config.maxRetries) {
                    stopPolling();
                    statusIndicator.textContent = 'Connection failed';
                }
            });
    }
    
    // Function to send a message
    function sendMessage() {
        const messageInput = document.getElementById('message-input');
        const statusIndicator = document.getElementById('chat-status');
        const message = messageInput.value.trim();
        
        if (message) {
            // Add user message to chat immediately for better UX
            addMessage(message, 'user-message');
            
            // Clear input
            messageInput.value = '';
            
            // Update status
            statusIndicator.textContent = 'Sending...';
            
            // Send to server
            const formData = new FormData();
            formData.append('message', message);
            
            fetch(config.apiEndpoints.sendMessage, {
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
                if (data.success) {
                    // Message sent successfully
                    statusIndicator.textContent = 'Message sent';
                    statusIndicator.className = 'chat-status connected';
                    
                    // Update last message ID if provided
                    if (data.message_id && data.message_id > state.lastMessageId) {
                        state.lastMessageId = data.message_id;
                    }
                    
                    // Fetch any new messages (including potential auto-responses)
                    setTimeout(fetchMessages, 1000);
                } else {
                    console.error('Error sending message:', data.error);
                    statusIndicator.textContent = 'Failed to send';
                    statusIndicator.className = 'chat-status error';
                    
                    // Show error in chat
                    addMessage('Error sending message. Please try again.', 'error-message');
                }
            })
            .catch(error => {
                console.error('Error sending message:', error);
                statusIndicator.textContent = 'Failed to send';
                statusIndicator.className = 'chat-status error';
                
                // Show error in chat
                addMessage('Error sending message. Please try again.', 'error-message');
            });
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