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
        agentsConfig: null,
        selectedProvider: 'ollama',
        conversationMessages: []
    };
    
    // Load persisted state from sessionStorage
    function loadPersistedState() {
        try {
            const savedConvId = sessionStorage.getItem('currentConversationId');
            if (savedConvId && savedConvId !== 'null' && savedConvId !== 'undefined') {
                state.currentConversationId = parseInt(savedConvId);
                console.debug('Restored conversation ID from storage:', state.currentConversationId);
            }
        } catch (e) {
            console.warn('Failed to load persisted state:', e);
        }
    }
    
    // Save conversation ID to sessionStorage
    function persistConversationId() {
        try {
            if (state.currentConversationId) {
                sessionStorage.setItem('currentConversationId', state.currentConversationId);
                console.debug('Persisted conversation ID to storage:', state.currentConversationId);
            }
        } catch (e) {
            console.warn('Failed to persist conversation ID:', e);
        }
    }
    
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
        chatHeader.innerHTML = '<h3>AI Assistant</h3><div class="chat-header-buttons"><select id="conversation-selector" class="conversation-selector" title="Select conversation"><option value="">Current Chat</option></select><button id="new-chat" class="new-chat-btn" title="Start new conversation">New Chat</button><button id="close-chat">×</button></div>';
        
        // Create chat messages area
        const chatMessages = document.createElement('div');
        chatMessages.id = 'chat-messages';
        chatMessages.className = 'chat-messages';
        
        // Add welcome message
        const welcomeMessage = document.createElement('div');
        welcomeMessage.className = 'message system-message';
        welcomeMessage.textContent = 'Hello! I\'m your AI assistant. Ask me anything and I\'ll help you right away.';
        chatMessages.appendChild(welcomeMessage);
        
        // Create provider selector
        const providerSelector = document.createElement('div');
        providerSelector.className = 'provider-selector';
        providerSelector.innerHTML = '<label for="ai-provider">AI Model:</label>' +
                                    '<select id="ai-provider">' +
                                    '<option value="ollama">Ollama (Local)</option>' +
                                    '</select>' +
                                    '<a href="/ai/manage_api_keys" target="_blank" class="manage-keys-link" title="Manage your API keys">⚙️</a>';
        
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
        chatPanel.appendChild(providerSelector);
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
        
        // Add provider selector change listener
        document.getElementById('ai-provider').addEventListener('change', function(e) {
            state.selectedProvider = e.target.value;
            console.debug('Provider changed to:', state.selectedProvider);
            const statusIndicator = document.getElementById('chat-status');
            statusIndicator.textContent = `AI Ready (${state.selectedProvider === 'grok' ? 'Grok' : 'Ollama'})`;
        });
        
        // Add conversation selector change listener
        document.getElementById('conversation-selector').addEventListener('change', function(e) {
            const conversationId = parseInt(e.target.value);
            if (conversationId) {
                loadConversation(conversationId);
            }
        });
    }
    
    // Load conversation list and populate dropdown
    function loadConversationList() {
        fetch('/ai/get_conversation_list', {
            method: 'GET',
            credentials: 'include'
        })
        .then(response => response.json())
        .then(data => {
            if (data.success && data.conversations) {
                const selector = document.getElementById('conversation-selector');
                // Clear existing options except first one
                selector.innerHTML = '<option value="">Current Chat</option>';
                
                // Add conversations to dropdown
                data.conversations.forEach(conv => {
                    const option = document.createElement('option');
                    option.value = conv.id;
                    option.textContent = `${conv.title} (${conv.message_count} msgs)`;
                    if (state.currentConversationId && conv.id === state.currentConversationId) {
                        option.selected = true;
                    }
                    selector.appendChild(option);
                });
                
                console.debug('Loaded', data.conversations.length, 'conversations');
            }
        })
        .catch(error => {
            console.error('Failed to load conversation list:', error);
        });
    }
    
    // Load a specific conversation's messages
    function loadConversation(conversationId) {
        const statusIndicator = document.getElementById('chat-status');
        statusIndicator.textContent = 'Loading conversation...';
        
        fetch(`/ai/get_conversation_messages/${conversationId}`, {
            method: 'GET',
            credentials: 'include'
        })
        .then(response => response.json())
        .then(data => {
            if (data.success && data.messages) {
                // Clear current messages
                const chatMessages = document.getElementById('chat-messages');
                chatMessages.innerHTML = '';
                
                // Add conversation messages
                data.messages.forEach(msg => {
                    const className = msg.role === 'user' ? 'user-message' : 'ai-message';
                    addMessage(msg.content, className);
                });
                
                // Update state
                state.currentConversationId = conversationId;
                persistConversationId();
                
                // Update header
                const chatHeader = document.querySelector('.chat-header h3');
                chatHeader.textContent = data.conversation.title;
                
                statusIndicator.textContent = `Loaded: ${data.conversation.title}`;
                console.debug('Loaded conversation', conversationId, 'with', data.messages.length, 'messages');
            } else {
                statusIndicator.textContent = 'Error loading conversation';
                alert(data.error || 'Failed to load conversation');
            }
        })
        .catch(error => {
            console.error('Failed to load conversation:', error);
            statusIndicator.textContent = 'Error loading conversation';
        });
    }
    
    // Load user's available AI providers
    function loadUserProviders() {
        fetch('/ai/get_user_providers', {
            method: 'GET',
            credentials: 'include'
        })
        .then(response => response.json())
        .then(data => {
            if (data.success && data.providers) {
                const providerSelect = document.getElementById('ai-provider');
                
                // Clear existing options except Ollama
                providerSelect.innerHTML = '<option value="ollama">Ollama (Local)</option>';
                
                // Add user's configured providers
                data.providers.forEach(provider => {
                    const option = document.createElement('option');
                    option.value = provider.service;
                    option.textContent = provider.display_name;
                    providerSelect.appendChild(option);
                });
                
                console.debug('Loaded', data.providers.length, 'user providers');
            }
        })
        .catch(error => {
            console.error('Failed to load user providers:', error);
        });
    }
    
    // Open chat panel
    function openChat() {
        const chatPanel = document.getElementById('chat-panel');
        const chatButton = document.getElementById('chat-button');
        
        // Load persisted conversation state
        loadPersistedState();
        
        // Load conversation list for dropdown
        loadConversationList();
        
        // Load user's available providers
        loadUserProviders();
        
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
        
        // Show status if resuming conversation
        if (state.currentConversationId) {
            const statusIndicator = document.getElementById('chat-status');
            statusIndicator.textContent = `Resuming conversation #${state.currentConversationId}`;
            console.debug('Resuming conversation:', state.currentConversationId);
        }
        
        // Focus on the input field
        const messageInput = document.getElementById('message-input');
        messageInput.focus();
    }
    
    // Reset conversation - clear session and UI
    function resetConversation() {
        // Clear client-side conversation state immediately
        state.currentConversationId = null;
        sessionStorage.removeItem('currentConversationId');
        
        // Clear messages from UI
        const chatMessages = document.getElementById('chat-messages');
        chatMessages.innerHTML = '<div class="message system-message">Hello! I\'m your AI assistant. Ask me anything and I\'ll help you right away.</div>';
        
        // Reset status
        const statusIndicator = document.getElementById('chat-status');
        statusIndicator.textContent = 'AI Ready - New Conversation';
        statusIndicator.className = 'chat-status connected';
        
        console.debug('Conversation reset - starting fresh');
        
        // Call server to clear session conversation_id (async, don't wait)
        fetch('/ai/reset_conversation', {
            method: 'POST',
            credentials: 'include'
        })
        .then(response => response.json())
        .then(data => {
            if (data.success) {
                console.debug('Server conversation reset confirmed');
            }
        })
        .catch(error => {
            console.error('Error resetting conversation on server:', error);
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
            provider: state.selectedProvider,
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
                    persistConversationId();  // Save to sessionStorage
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
                background-color: var(--primary-color);
                color: var(--text-color);
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
                background-color: var(--background-color);
                border-radius: 10px;
                box-shadow: var(--dropdown-shadow);
                display: flex;
                flex-direction: column;
                font-family: inherit;
                z-index: 1002;
            }
            
            .chat-header {
                background-color: var(--primary-color);
                color: var(--text-color);
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
            
            .conversation-selector {
                background: var(--background-color);
                border: 1px solid var(--border-color);
                color: var(--text-color);
                font-size: 12px;
                padding: 4px 8px;
                border-radius: 4px;
                cursor: pointer;
                max-width: 200px;
            }
            
            #new-chat {
                background: var(--nav-hover-bg);
                border: 1px solid var(--border-color);
                color: var(--text-color);
                font-size: 12px;
                padding: 4px 8px;
                border-radius: 4px;
                cursor: pointer;
                transition: background-color 0.2s;
            }
            
            #new-chat:hover {
                background: var(--secondary-color);
            }
            
            #close-chat {
                background: none;
                border: none;
                color: var(--text-color);
                font-size: 20px;
                cursor: pointer;
            }
            
            .chat-messages {
                flex-grow: 1;
                padding: 15px;
                overflow-y: auto;
                background-color: var(--background-color);
            }
            
            .message {
                margin-bottom: 10px;
                padding: 8px 12px;
                border-radius: 18px;
                max-width: 80%;
                word-wrap: break-word;
            }
            
            .system-message {
                background-color: var(--secondary-color);
                color: var(--text-color);
                align-self: flex-start;
                margin-right: auto;
                border-bottom-left-radius: 5px;
            }
            
            .user-message {
                background-color: var(--primary-color);
                color: var(--text-color);
                align-self: flex-end;
                margin-left: auto;
                border-bottom-right-radius: 5px;
            }
            
            .ai-message {
                background-color: var(--secondary-color);
                color: var(--text-color);
                align-self: flex-start;
                margin-right: auto;
                border-bottom-left-radius: 5px;
                border-left: 3px solid var(--success-color);
            }
            
            .ai-message.loading {
                background-color: var(--secondary-color);
                color: var(--schema-text-muted);
                font-style: italic;
            }
            
            .error-message {
                background-color: var(--secondary-color);
                border: 1px solid var(--warning-color);
                color: var(--text-color);
                align-self: center;
                margin: 5px auto;
                font-size: 0.9em;
            }
            
            .chat-status {
                padding: 5px 10px;
                font-size: 0.8em;
                text-align: center;
                background-color: var(--background-color);
                border-top: 1px solid var(--border-color);
            }
            
            .chat-status.connected {
                color: var(--success-color);
            }
            
            .chat-status.error {
                color: var(--warning-color);
            }
            
            .chat-status.processing {
                color: var(--accent-color);
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
            
            .provider-selector {
                padding: 8px 15px;
                background-color: #f5f5f5;
                border-bottom: 1px solid var(--border-color);
                display: flex;
                align-items: center;
                gap: 10px;
                font-size: 13px;
            }
            
            .provider-selector label {
                font-weight: 600;
                color: #555;
            }
            
            .provider-selector select {
                flex-grow: 1;
                padding: 5px 10px;
                border: 1px solid var(--border-color);
                border-radius: 4px;
                background-color: white;
                cursor: pointer;
            }
            
            .manage-keys-link {
                display: inline-flex;
                align-items: center;
                justify-content: center;
                width: 28px;
                height: 28px;
                background: var(--link-color);
                color: white;
                border-radius: 4px;
                text-decoration: none;
                font-size: 14px;
                transition: background 0.2s;
            }
            
            .manage-keys-link:hover {
                background: #0056b3;
                text-decoration: none;
            }
            
            .chat-input {
                padding: 10px;
                border-top: 1px solid var(--border-color);
                display: flex;
            }
            
            #message-input {
                flex-grow: 1;
                border: 1px solid var(--border-color);
                border-radius: 4px;
                padding: 8px;
                resize: none;
                height: 40px;
                margin-right: 8px;
                background-color: var(--background-color);
                color: var(--text-color);
            }
            
            #send-message {
                background-color: var(--primary-color);
                color: var(--text-color);
                border: none;
                border-radius: 4px;
                padding: 8px 15px;
                cursor: pointer;
                font-family: inherit;
            }
            
            #send-message:hover {
                background-color: var(--primary-color);
                opacity: 0.8;
                color: var(--text-color);
            }
            
            #send-message:disabled {
                background-color: var(--secondary-color);
                color: var(--schema-text-muted);
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