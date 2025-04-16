/**
 * Local Chat Implementation
 * A simple chat widget that works without external dependencies
 */

(function() {
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
        
        // Assemble the chat panel
        chatPanel.appendChild(chatHeader);
        chatPanel.appendChild(chatMessages);
        chatPanel.appendChild(chatInput);
        
        // Add everything to the container
        chatContainer.appendChild(chatButton);
        chatContainer.appendChild(chatPanel);
        
        // Add the container to the body
        document.body.appendChild(chatContainer);
        
        // Add event listeners
        chatButton.addEventListener('click', function() {
            chatPanel.style.display = 'block';
            chatButton.style.display = 'none';
        });
        
        document.getElementById('close-chat').addEventListener('click', function() {
            chatPanel.style.display = 'none';
            chatButton.style.display = 'block';
        });
        
        document.getElementById('send-message').addEventListener('click', sendMessage);
        document.getElementById('message-input').addEventListener('keypress', function(e) {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                sendMessage();
            }
        });
    }
    
    // Function to send a message
    function sendMessage() {
        const messageInput = document.getElementById('message-input');
        const message = messageInput.value.trim();
        
        if (message) {
            // Add user message to chat
            addMessage(message, 'user-message');
            
            // Clear input
            messageInput.value = '';
            
            // Simulate response (in a real implementation, this would send to a server)
            setTimeout(function() {
                addMessage('Thank you for your message. Our team will review it and get back to you soon.', 'system-message');
            }, 1000);
            
            // In a real implementation, you would send the message to your server here
            console.log('Message sent (would be sent to server):', message);
            
            // Store in local storage for demo purposes
            const messages = JSON.parse(localStorage.getItem('chatMessages') || '[]');
            messages.push({
                text: message,
                sender: 'user',
                timestamp: new Date().toISOString()
            });
            localStorage.setItem('chatMessages', JSON.stringify(messages));
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
                font-family: Arial, sans-serif;
            }
            
            .chat-button {
                background-color: var(--primary-color, #007bff);
                color: white;
                border: none;
                border-radius: 50px;
                padding: 10px 20px;
                cursor: pointer;
                display: flex;
                align-items: center;
                box-shadow: 0 2px 5px rgba(0,0,0,0.2);
            }
            
            .chat-icon {
                margin-right: 8px;
                font-size: 1.2em;
            }
            
            .chat-panel {
                width: 300px;
                height: 400px;
                background-color: white;
                border-radius: 10px;
                box-shadow: 0 5px 15px rgba(0,0,0,0.2);
                display: flex;
                flex-direction: column;
            }
            
            .chat-header {
                background-color: var(--primary-color, #007bff);
                color: white;
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
                align-self: flex-start;
                margin-right: auto;
            }
            
            .user-message {
                background-color: var(--primary-color, #007bff);
                color: white;
                align-self: flex-end;
                margin-left: auto;
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
                color: white;
                border: none;
                border-radius: 4px;
                padding: 8px 15px;
                cursor: pointer;
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