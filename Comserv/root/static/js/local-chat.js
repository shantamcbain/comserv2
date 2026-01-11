/**
 * Live Chat Implementation with Context-Aware Agent Selection
 * A chat widget that connects to the server API and selects agents based on page context
 */

(function() {
    // Configuration
    const config = {
        apiEndpoints: {
            generateResponse: '/ai/generate',
            agentsConfig: '/static/config/agents.json'
        },
        maxRetries: 3,      // Max retries for failed API calls
    };
    
    // State
    let state = {
        retryCount: 0,
        isOpen: false,
        currentConversationId: null,
        pageContext: null,
        currentAgent: null,
        agentsConfig: null
    };
    
    // Load agents configuration from JSON file
    function loadAgentsConfig() {
        return fetch(config.apiEndpoints.agentsConfig)
            .then(response => {
                if (!response.ok) {
                    console.error('Failed to load agents.json:', response.status);
                    return null;
                }
                return response.json();
            })
            .then(data => {
                state.agentsConfig = data;
                return data;
            })
            .catch(error => {
                console.error('Error loading agents config:', error);
                return null;
            });
    }
    
    // Match page URL against agent patterns and select appropriate agent
    function selectAgentForPage() {
        const pathname = window.location.pathname;
        
        if (!state.agentsConfig || !state.agentsConfig.agents) {
            console.warn('Agents config not loaded, using general agent');
            return null;
        }
        
        const agents = state.agentsConfig.agents;
        
        // Check each agent's URL patterns
        for (const [agentKey, agent] of Object.entries(agents)) {
            if (!agent.url_patterns) continue;
            
            // Check if any URL pattern matches the current pathname
            for (const pattern of agent.url_patterns) {
                let isMatch = false;
                
                if (pattern === '*') {
                    // Wildcard matches everything (use as fallback)
                    isMatch = true;
                } else {
                    // Check if pattern matches pathname
                    // Support both exact match and prefix match
                    isMatch = pathname === pattern || pathname.startsWith(pattern);
                }
                
                if (isMatch) {
                    console.debug(`Agent selected for ${pathname}: ${agent.id}`);
                    return agent;
                }
            }
        }
        
        // Fallback to general agent if no specific match
        if (agents.general) {
            console.debug(`Using general agent for ${pathname}`);
            return agents.general;
        }
        
        return null;
    }
    
    // Detect page context (documentation, helpdesk, project, etc.)
    function detectPageContext() {
        const pathname = window.location.pathname;
        const pageTitle = document.title || 'Unknown Page';
        
        // Try to load and select agent from config
        const selectedAgent = selectAgentForPage();
        state.currentAgent = selectedAgent;
        
        let context = {
            page_path: pathname,
            page_title: pageTitle,
            page_url: window.location.href
        };
        
        if (selectedAgent) {
            context.page_type = selectedAgent.id;
            context.agent_id = selectedAgent.id;
            context.agent_name = selectedAgent.display_name;
            context.system_prompt = selectedAgent.system_prompt;
            context.capabilities = selectedAgent.capabilities;
            context.model_settings = selectedAgent.model_settings;
        } else {
            // Fallback to general
            context.page_type = 'general';
            context.agent_id = 'general';
            context.system_prompt = 'You are a helpful AI assistant ready to assist with general questions and tasks.';
        }
        
        return context;
    }
    
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
        chatHeader.innerHTML = '<h3>AI Assistant</h3><div class="chat-header-buttons"><button id="new-chat" class="new-chat-btn" title="Start new conversation">New Chat</button><button id="close-chat">×</button></div>';
        
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
        
        // Add button to the container
        chatContainer.appendChild(chatButton);
        
        // Add the container to the body
        document.body.appendChild(chatContainer);
        
        // Add the panel directly to the body (not to container) to avoid stacking context issues
        document.body.appendChild(chatPanel);
        
        // Add event listeners
        chatButton.addEventListener('click', function() {
            openChat();
        });
        
        document.getElementById('close-chat').addEventListener('click', function() {
            closeChat();
        });
        
        document.getElementById('new-chat').addEventListener('click', function() {
            resetConversation();
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
        
        // Update chat header with selected agent info
        const chatHeader = document.querySelector('.chat-header h3');
        if (state.pageContext && state.pageContext.agent_name) {
            chatHeader.textContent = state.pageContext.agent_name;
        } else if (state.currentAgent && state.currentAgent.display_name) {
            chatHeader.textContent = state.currentAgent.display_name;
        }
        
        chatPanel.style.display = 'flex';
        chatButton.style.display = 'none';
        state.isOpen = true;
        
        // Focus on the input field
        const messageInput = document.getElementById('message-input');
        messageInput.focus();
    }
    
    // Reset conversation - clear session and UI
    function resetConversation() {
        // Call server to clear session conversation_id
        fetch('/ai/reset_conversation', {
            method: 'POST',
            credentials: 'include'
        })
        .then(response => response.json())
        .then(data => {
            if (data.success) {
                // Clear client-side conversation state
                state.currentConversationId = null;
                
                // Clear messages from UI
                const chatMessages = document.getElementById('chat-messages');
                chatMessages.innerHTML = '<div class="message system-message">Hello! I\'m your AI assistant. Ask me anything and I\'ll help you right away.</div>';
                
                // Reset status
                const statusIndicator = document.getElementById('chat-status');
                statusIndicator.textContent = 'AI Ready';
                statusIndicator.className = 'chat-status connected';
                
                console.debug('Conversation reset successfully');
            }
        })
        .catch(error => {
            console.error('Error resetting conversation:', error);
            alert('Failed to start new conversation');
        });
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
        
        // Ensure agents config is loaded before proceeding
        const ensureAgentsLoaded = state.agentsConfig 
            ? Promise.resolve(state.agentsConfig) 
            : loadAgentsConfig();
        
        ensureAgentsLoaded.then(function() {
            // Initialize page context if not already done (after agents loaded)
            if (!state.pageContext) {
                state.pageContext = detectPageContext();
            }
            
            // Send the request (extracted to helper function below)
            sendAIRequest(prompt, statusIndicator, loadingMessage);
        }).catch(function(error) {
            console.error('Failed to load agents config:', error);
            // Fallback: still send request with default context
            if (!state.pageContext) {
                state.pageContext = detectPageContext();
            }
            sendAIRequest(prompt, statusIndicator, loadingMessage);
        });
    }
    
    // Helper function to send AI request after context is ready
    function sendAIRequest(prompt, statusIndicator, loadingMessage) {
        // Build request payload with page context and agent info
        const requestPayload = {
            prompt: prompt,
            page_context: state.pageContext.page_type,
            page_path: state.pageContext.page_path,
            page_title: state.pageContext.page_title,
            system: state.pageContext.system_prompt,
            agent_id: state.pageContext.agent_id,
            agent_name: state.pageContext.agent_name
        };
        
        // Include model settings if available
        if (state.pageContext.model_settings) {
            requestPayload.model_settings = state.pageContext.model_settings;
        }
        
        // Include capabilities if available
        if (state.pageContext.capabilities) {
            requestPayload.capabilities = state.pageContext.capabilities;
        }
        
        // Include conversation ID if continuing existing conversation
        if (state.currentConversationId) {
            requestPayload.conversation_id = state.currentConversationId;
            console.debug('Adding conversation_id to request:', state.currentConversationId);
        } else {
            console.debug('No conversation_id in state, starting new conversation');
        }
        
        console.debug('Sending AI request with agent:', state.pageContext.agent_id, requestPayload);
        
        // Send to AI as JSON (not FormData)
        fetch(config.apiEndpoints.generateResponse, {
            method: 'POST',
            credentials: 'include',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(requestPayload)
        })
        .then(response => {
            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
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
                
                // Store conversation ID ONLY if it was successfully created
                if (data.conversation_id && data.conversation_id !== null && data.conversation_id !== undefined) {
                    state.currentConversationId = data.conversation_id;
                    console.debug('Conversation created successfully with ID:', data.conversation_id);
                } else {
                    console.warn('Warning: Conversation was not saved to database. New chat will be created on next message.');
                    if (data.warning) {
                        addMessage(`⚠️ ${data.warning}`, 'system-message');
                    }
                }
                
                // Update status
                statusIndicator.textContent = 'AI Ready';
                statusIndicator.className = 'chat-status connected';
                
                // Add AI response
                addMessage(data.response, 'ai-message');
                
                // Log context information for debugging
                console.debug('AI Query Success', {
                    conversationId: state.currentConversationId || 'NOT_CREATED',
                    pageContext: state.pageContext.page_type,
                    timestamp: new Date().toISOString()
                });
            } else {
                console.error('Error getting AI response:', data.error);
                statusIndicator.textContent = 'AI Error';
                statusIndicator.className = 'chat-status error';
                
                // Show error in chat
                addMessage(`Error: ${data.error || 'Failed to get response. Please try again.'}`, 'error-message');
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
            addMessage(`Network error: ${error.message}. Please check console and try again.`, 'error-message');
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
                position: relative;
                z-index: 1001;
            }
            
            .chat-icon {
                margin-right: 8px;
                font-size: 1.2em;
            }
            
            .chat-panel {
                position: fixed;
                bottom: 90px;
                right: 20px;
                width: 380px;
                height: 500px;
                background-color: var(--background-color, white);
                border-radius: 10px;
                box-shadow: 0 5px 15px rgba(0,0,0,0.3);
                display: flex;
                flex-direction: column;
                font-family: inherit;
                z-index: 1002;
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
            
            .chat-header-buttons {
                display: flex;
                gap: 8px;
                align-items: center;
            }
            
            #new-chat {
                background: rgba(255,255,255,0.2);
                border: 1px solid rgba(255,255,255,0.3);
                color: white;
                font-size: 12px;
                padding: 4px 8px;
                border-radius: 4px;
                cursor: pointer;
                transition: background-color 0.2s;
            }
            
            #new-chat:hover {
                background: rgba(255,255,255,0.3);
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
        
        // Load agents config asynchronously (doesn't block widget creation)
        loadAgentsConfig().then(function() {
            console.debug('Agents config loaded successfully');
            // Update button icon/text based on selected agent if widget is open
            if (state.isOpen && state.currentAgent) {
                const chatButton = document.getElementById('chat-button');
                if (chatButton && state.currentAgent.icon) {
                    chatButton.querySelector('.chat-icon').textContent = state.currentAgent.icon;
                }
            }
        });
    });
})();