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
        pageDocFetched: false,
        currentAgent: null,
        agentsConfig: null,
        selectedProvider: 'ollama',
        conversationMessages: [],
        username: 'You',
        activeModel: null
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
    
    // Fetch documentation content for the current page from the server.
    // Returns a Promise that resolves to a string (empty if not found).
    function fetchPageDoc(pagePath) {
        return fetch('/ai/get_page_doc?page=' + encodeURIComponent(pagePath), {
            credentials: 'include'
        })
        .then(function(r) { return r.ok ? r.json() : null; })
        .then(function(data) {
            if (data && data.success && data.content) {
                console.debug('[AI widget] Doc loaded from', data.file, '(' + data.content.length + ' chars)');
                return data.content;
            }
            return '';
        })
        .catch(function() { return ''; });
    }

    // Extract visible text content from the current page for context
    function extractPageContent() {
        const skipSelectors = '#local-chat-widget, #chat-panel, script, style, nav, footer, .navbar, header';
        const contentSelectors = ['main', '.main-content', '#content', '.content-area', '.page-content', 'article', '.container'];
        for (const sel of contentSelectors) {
            const el = document.querySelector(sel);
            if (!el) continue;
            const clone = el.cloneNode(true);
            clone.querySelectorAll(skipSelectors).forEach(function(e) { e.remove(); });
            const text = clone.textContent.replace(/\s+/g, ' ').trim();
            if (text.length > 200) {
                return text.substring(0, 3000);
            }
        }
        // Fallback: body text
        const bodyClone = document.body.cloneNode(true);
        bodyClone.querySelectorAll(skipSelectors).forEach(function(e) { e.remove(); });
        const bodyText = bodyClone.textContent.replace(/\s+/g, ' ').trim();
        return bodyText.substring(0, 2000);
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
        
        // Extract current page content for context awareness
        const pageContent = extractPageContent();
        
        if (selectedAgent) {
            context.page_type = selectedAgent.id;
            context.agent_id = selectedAgent.id;
            context.agent_name = selectedAgent.display_name;
            context.system_prompt = selectedAgent.system_prompt +
                (pageContent ? '\n\nCurrent page "' + pageTitle + '" (' + pathname + ') content:\n' + pageContent : '');
            context.capabilities = selectedAgent.capabilities;
            context.model_settings = selectedAgent.model_settings;
        } else {
            // Fallback to general
            context.page_type = 'general';
            context.agent_id = 'general';
            context.system_prompt = 'You are a helpful AI assistant ready to assist with general questions and tasks.' +
                (pageContent ? '\n\nCurrent page "' + pageTitle + '" (' + pathname + ') content:\n' + pageContent : '');
        }
        
        return context;
    }
    
    // Create chat widget elements
    function createChatWidget() {
        // ── Floating chat button ──────────────────────────────────────────────
        const chatContainer = document.createElement('div');
        chatContainer.id = 'local-chat-widget';
        chatContainer.className = 'local-chat-widget';

        const chatButton = document.createElement('button');
        chatButton.id = 'chat-button';
        chatButton.className = 'chat-button';
        chatButton.innerHTML = '<span class="chat-icon">🤖</span> Chat with AI';
        chatContainer.appendChild(chatButton);
        document.body.appendChild(chatContainer);

        // ── Chat panel ────────────────────────────────────────────────────────
        const chatPanel = document.createElement('div');
        chatPanel.id = 'chat-panel';
        chatPanel.className = 'chat-panel';
        chatPanel.style.display = 'none';
        document.body.appendChild(chatPanel);  // direct child of body for z-index

        // Header (drag handle)
        const chatHeader = document.createElement('div');
        chatHeader.className = 'chat-header';
        chatHeader.innerHTML =
            '<div class="chat-header-drag" id="chat-drag-handle" title="Drag to move">⠿</div>' +
            '<h3 id="chat-title">AI Assistant</h3>' +
            '<div class="chat-header-buttons">' +
                '<button id="toggle-history-btn" class="chat-header-icon-btn" title="Conversation history">🕐</button>' +
                '<button id="new-chat" class="chat-header-icon-btn" title="New conversation">✏️</button>' +
                '<button id="detach-chat" class="chat-header-icon-btn" title="Detach to moveable window (works across monitors)">⤢</button>' +
                '<button id="close-chat" class="chat-header-icon-btn" title="Close">✕</button>' +
            '</div>';

        // History drawer (hidden by default, slides in from top of messages area)
        const historyDrawer = document.createElement('div');
        historyDrawer.id = 'widget-history-drawer';
        historyDrawer.className = 'widget-history-drawer';
        historyDrawer.style.display = 'none';
        historyDrawer.innerHTML =
            '<div class="widget-history-header">' +
                '<span>Recent Conversations</span>' +
                '<button id="history-close-btn" class="chat-header-icon-btn" title="Close history">✕</button>' +
            '</div>' +
            '<div id="widget-history-list" class="widget-history-list"><div class="wh-loading">Loading…</div></div>';

        // Messages area
        const chatMessages = document.createElement('div');
        chatMessages.id = 'chat-messages';
        chatMessages.className = 'chat-messages';
        const welcomeMessage = document.createElement('div');
        welcomeMessage.className = 'message system-message';
        welcomeMessage.textContent = 'Hello! I\'m your AI assistant. Ask me anything and I\'ll help you right away.';
        chatMessages.appendChild(welcomeMessage);

        // Provider / model selector bar
        const providerSelector = document.createElement('div');
        providerSelector.className = 'provider-selector';
        providerSelector.innerHTML =
            '<label for="ai-provider">AI Model:</label>' +
            '<select id="ai-provider"><option value="ollama">Ollama (Local)</option></select>' +
            '<a href="/ai/manage_api_keys" target="_blank" class="manage-keys-link" title="Manage API keys">⚙️</a>';

        // Status indicator
        const statusIndicator = document.createElement('div');
        statusIndicator.id = 'chat-status';
        statusIndicator.className = 'chat-status';
        statusIndicator.textContent = 'AI Ready';

        // Input area
        const chatInput = document.createElement('div');
        chatInput.className = 'chat-input';
        chatInput.innerHTML =
            '<textarea id="message-input" placeholder="Type your message…"></textarea>' +
            '<button id="send-message">Send</button>';

        // Assemble panel
        chatPanel.appendChild(chatHeader);
        chatPanel.appendChild(historyDrawer);
        chatPanel.appendChild(chatMessages);
        chatPanel.appendChild(providerSelector);
        chatPanel.appendChild(statusIndicator);
        chatPanel.appendChild(chatInput);

        // ── Populate provider dropdown ────────────────────────────────────────
        fetch('/ai/get_user_providers', { method: 'GET', credentials: 'include' })
            .then(r => r.json())
            .then(function(data) {
                if (data.success) {
                    // Capture username
                    if (data.username) {
                        state.username = data.username;
                    }
                }
                if (data.success && data.providers && data.providers.length > 0) {
                    const sel = document.getElementById('ai-provider');
                    if (!sel) return;
                    data.providers.forEach(function(p) {
                        if (p.service === 'grok') {
                            const grp = document.createElement('optgroup');
                            grp.label = 'External AI (xAI)';
                            const grokModels = (p.models && p.models.length > 0)
                                ? p.models
                                    .filter(function(m) { return m.id && !m.id.match(/imagine|video/i); })
                                    .map(function(m) {
                                        const label = m.id.replace(/-/g, ' ').replace(/\b\w/g, function(c){ return c.toUpperCase(); });
                                        return { val: 'grok|' + m.id, label: label + ' (xAI)' };
                                    })
                                : [
                                    { val: 'grok|grok-3-mini',               label: 'Grok 3 Mini (fast)' },
                                    { val: 'grok|grok-3',                    label: 'Grok 3' },
                                    { val: 'grok|grok-4-0709',               label: 'Grok 4' },
                                    { val: 'grok|grok-4-fast-non-reasoning', label: 'Grok 4 Fast' },
                                    { val: 'grok|grok-code-fast-1',          label: 'Grok Code Fast' }
                                ];
                            grokModels.forEach(function(m) {
                                const opt = document.createElement('option');
                                opt.value = m.val; opt.textContent = m.label;
                                grp.appendChild(opt);
                            });
                            sel.appendChild(grp);
                        }
                    });
                }
            })
            .catch(function() {});

        // ── Drag to move ──────────────────────────────────────────────────────
        (function initDrag() {
            const handle = document.getElementById('chat-drag-handle');
            let dragging = false, startX, startY, origLeft, origBottom, origTop, origRight;

            handle.addEventListener('mousedown', function(e) {
                e.preventDefault();
                dragging = true;
                startX = e.clientX;
                startY = e.clientY;
                const rect = chatPanel.getBoundingClientRect();
                // Switch from bottom/right positioning to top/left for free movement
                chatPanel.style.bottom = 'auto';
                chatPanel.style.right  = 'auto';
                chatPanel.style.top    = rect.top + 'px';
                chatPanel.style.left   = rect.left + 'px';
                chatPanel.style.margin = '0';
                document.body.style.userSelect = 'none';
            });

            document.addEventListener('mousemove', function(e) {
                if (!dragging) return;
                const dx = e.clientX - startX;
                const dy = e.clientY - startY;
                startX = e.clientX;
                startY = e.clientY;
                const rect = chatPanel.getBoundingClientRect();
                const newTop  = Math.max(0, Math.min(window.innerHeight - 60, rect.top + dy));
                const newLeft = Math.max(0, Math.min(window.innerWidth  - 60, rect.left + dx));
                chatPanel.style.top  = newTop  + 'px';
                chatPanel.style.left = newLeft + 'px';
            });

            document.addEventListener('mouseup', function() {
                dragging = false;
                document.body.style.userSelect = '';
            });

            // Touch support
            handle.addEventListener('touchstart', function(e) {
                const t = e.touches[0];
                startX = t.clientX; startY = t.clientY;
                const rect = chatPanel.getBoundingClientRect();
                chatPanel.style.bottom = 'auto'; chatPanel.style.right = 'auto';
                chatPanel.style.top = rect.top + 'px'; chatPanel.style.left = rect.left + 'px';
                chatPanel.style.margin = '0';
            }, { passive: true });

            document.addEventListener('touchmove', function(e) {
                if (!handle._touching) return;
                const t = e.touches[0];
                const dx = t.clientX - startX; const dy = t.clientY - startY;
                startX = t.clientX; startY = t.clientY;
                const rect = chatPanel.getBoundingClientRect();
                chatPanel.style.top  = Math.max(0, rect.top  + dy) + 'px';
                chatPanel.style.left = Math.max(0, rect.left + dx) + 'px';
            }, { passive: true });

            handle.addEventListener('touchstart', function() { handle._touching = true; }, { passive: true });
            handle.addEventListener('touchend',   function() { handle._touching = false; });
        })();

        // ── History drawer ────────────────────────────────────────────────────
        document.getElementById('toggle-history-btn').addEventListener('click', function() {
            const drawer = document.getElementById('widget-history-drawer');
            if (drawer.style.display === 'none') {
                drawer.style.display = 'flex';
                loadWidgetHistory();
            } else {
                drawer.style.display = 'none';
            }
        });

        document.getElementById('history-close-btn').addEventListener('click', function() {
            document.getElementById('widget-history-drawer').style.display = 'none';
        });

        // ── Other events ──────────────────────────────────────────────────────
        chatButton.addEventListener('click', function() { openChat(); });
        document.getElementById('close-chat').addEventListener('click', function() { closeChat(); });
        document.getElementById('new-chat').addEventListener('click', function() { resetConversation(); });
        document.getElementById('detach-chat').addEventListener('click', function() { detachToPopup(); });
        document.getElementById('send-message').addEventListener('click', sendMessage);
        document.getElementById('message-input').addEventListener('keypress', function(e) {
            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
        });
        document.getElementById('ai-provider').addEventListener('change', function(e) {
            state.selectedProvider = e.target.value;
            const parts = state.selectedProvider.split('|');
            let modelDisplay;
            if (parts[0] === 'grok') {
                modelDisplay = 'Grok (xAI)' + (parts[1] ? ': ' + parts[1] : '');
            } else {
                modelDisplay = 'Ollama (Local)' + (parts[1] ? ': ' + parts[1] : '');
            }
            state.activeModel = modelDisplay;
            const statusEl = document.getElementById('chat-status');
            statusEl.textContent = '🔵 ' + modelDisplay + ' selected';
            statusEl.className = 'chat-status connected';
        });
    }

    // Load conversation list into widget history drawer
    function loadWidgetHistory() {
        const list = document.getElementById('widget-history-list');
        if (!list) return;
        list.innerHTML = '<div class="wh-loading">Loading…</div>';
        fetch('/ai/get_conversation_list', { credentials: 'include' })
            .then(r => r.json())
            .then(function(data) {
                list.innerHTML = '';
                if (!data.success || !data.conversations || !data.conversations.length) {
                    list.innerHTML = '<div class="wh-empty">No conversations yet</div>';
                    return;
                }
                data.conversations.forEach(function(conv) {
                    const item = document.createElement('button');
                    item.className = 'wh-item' + (state.currentConversationId && String(conv.id) === String(state.currentConversationId) ? ' active' : '');
                    item.innerHTML =
                        '<div class="wh-title">' + escWidgetHtml(conv.title || 'Untitled') + '</div>' +
                        '<div class="wh-meta">' + (conv.message_count || 0) + ' msgs · ' + wRelTime(conv.updated_at) + '</div>';
                    item.addEventListener('click', function() {
                        loadConversation(conv.id);
                        document.getElementById('widget-history-drawer').style.display = 'none';
                        document.getElementById('chat-title').textContent = conv.title || 'AI Assistant';
                        document.querySelectorAll('.wh-item').forEach(i => i.classList.remove('active'));
                        item.classList.add('active');
                    });
                    list.appendChild(item);
                });
            })
            .catch(function() { list.innerHTML = '<div class="wh-empty">Failed to load</div>'; });
    }

    function escWidgetHtml(s) {
        return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }

    function wRelTime(dateStr) {
        if (!dateStr) return '';
        try {
            const d = new Date(dateStr.replace(' ','T'));
            const mins = Math.floor((Date.now() - d.getTime()) / 60000);
            if (mins < 2)  return 'just now';
            if (mins < 60) return mins + 'm ago';
            const hrs = Math.floor(mins / 60);
            if (hrs < 24)  return hrs + 'h ago';
            return Math.floor(hrs / 24) + 'd ago';
        } catch(e) { return ''; }
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
    
    // Detach widget to a standalone popup window (moveable to any monitor)
    function detachToPopup() {
        const convId = state.currentConversationId;
        const url = '/ai' + (convId ? '?resume=' + convId : '');
        const popup = window.open(url, 'ai-chat-popup',
            'width=720,height=860,resizable=yes,menubar=no,toolbar=no,location=no,status=no');
        if (popup) {
            closeChat();
        } else {
            const statusIndicator = document.getElementById('chat-status');
            statusIndicator.textContent = 'Please allow popups for this site to detach chat';
        }
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
        
        // Auto-reload messages if resuming a conversation
        if (state.currentConversationId) {
            const chatMessages = document.getElementById('chat-messages');
            const hasMessages = chatMessages && chatMessages.children.length > 1;
            if (!hasMessages) {
                loadConversation(state.currentConversationId);
            }
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

            // Fetch documentation for the current page (cached after first load)
            const docPromise = state.pageDocFetched
                ? Promise.resolve('')
                : fetchPageDoc(window.location.pathname).then(function(docText) {
                    state.pageDocFetched = true;
                    if (docText && state.pageContext) {
                        state.pageContext.system_prompt =
                            (state.pageContext.system_prompt || '') +
                            '\n\n--- Page Documentation ---\n' + docText;
                    }
                    return docText;
                });

            docPromise.then(function() {
                sendAIRequest(prompt, statusIndicator, loadingMessage);
            });
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
        // Parse provider|model format (e.g. "grok|grok-2-latest" or "ollama")
        const providerParts = (state.selectedProvider || 'ollama').split('|');
        const providerName = providerParts[0];
        const modelName = providerParts[1] || null;

        // Build request payload with page context and agent info
        const requestPayload = {
            prompt: prompt,
            provider: providerName,
            page_context: state.pageContext.page_type,
            page_path: state.pageContext.page_path,
            page_title: state.pageContext.page_title,
            system: state.pageContext.system_prompt,
            agent_id: state.pageContext.agent_id,
            agent_name: state.pageContext.agent_name
        };
        
        // Include selected model for Grok
        if (modelName) {
            requestPayload.model = modelName;
        }

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
        .then(response => response.json())
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
                
                // Update status with provider + model name
                const providerParts2 = (state.selectedProvider || 'ollama').split('|');
                const provName = providerParts2[0];
                const rawModel = data.model || providerParts2[1] || '';
                let modelLabel;
                if (provName === 'grok') {
                    modelLabel = 'Grok (xAI)' + (rawModel ? ': ' + rawModel : '');
                } else {
                    modelLabel = 'Ollama (Local)' + (rawModel ? ': ' + rawModel : '');
                }
                state.activeModel = modelLabel;
                statusIndicator.textContent = '🟢 ' + modelLabel;
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
    
    // Function to add a message to the chat with sender label
    function addMessage(text, className) {
        const chatMessages = document.getElementById('chat-messages');
        const wrapper = document.createElement('div');
        wrapper.className = 'msg-wrapper ' + (className === 'user-message' ? 'msg-wrapper-user' : 'msg-wrapper-ai');

        // Sender label
        const label = document.createElement('div');
        label.className = 'msg-label';
        if (className === 'user-message') {
            label.textContent = state.username;
        } else if (className === 'ai-message') {
            const modelLabel = state.activeModel || (state.pageContext && state.pageContext.agent_name) || 'AI Assistant';
            label.textContent = modelLabel;
        } else {
            label.textContent = 'System';
        }

        const messageElement = document.createElement('div');
        messageElement.className = 'message ' + className;
        messageElement.textContent = text;

        wrapper.appendChild(label);
        wrapper.appendChild(messageElement);
        chatMessages.appendChild(wrapper);
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
                z-index: 9999;
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
                z-index: 10000;
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
                min-width: 280px;
                max-width: 90vw;
                height: 500px;
                min-height: 300px;
                max-height: 90vh;
                background-color: var(--background-color);
                border-radius: 10px;
                box-shadow: var(--dropdown-shadow);
                display: flex;
                flex-direction: column;
                font-family: inherit;
                z-index: 10001;
                resize: both;
                overflow: hidden;
            }
            
            .chat-header {
                background-color: var(--primary-color);
                color: var(--text-color);
                padding: 8px 12px;
                border-top-left-radius: 10px;
                border-top-right-radius: 10px;
                display: flex;
                justify-content: space-between;
                align-items: center;
                gap: 6px;
                flex-shrink: 0;
            }

            .chat-header-drag {
                cursor: grab; font-size: 18px; opacity: 0.5; padding: 0 4px;
                user-select: none; letter-spacing: -2px; flex-shrink: 0;
            }
            .chat-header-drag:active { cursor: grabbing; }

            .chat-header h3 {
                margin: 0; font-size: 14px; flex: 1; white-space: nowrap;
                overflow: hidden; text-overflow: ellipsis;
            }
            
            .chat-header-buttons {
                display: flex; gap: 4px; align-items: center; flex-shrink: 0;
            }

            .chat-header-icon-btn {
                background: none; border: none; color: var(--text-color);
                font-size: 15px; cursor: pointer; padding: 2px 5px;
                border-radius: 4px; opacity: 0.75; transition: opacity 0.15s, background 0.15s;
            }
            .chat-header-icon-btn:hover { opacity: 1; background: rgba(255,255,255,0.1); }

            /* History drawer */
            .widget-history-drawer {
                display: flex; flex-direction: column;
                background-color: var(--background-color);
                border-bottom: 1px solid var(--border-color);
                max-height: 220px; overflow: hidden; flex-shrink: 0;
            }
            .widget-history-header {
                display: flex; justify-content: space-between; align-items: center;
                padding: 6px 10px; font-size: 12px; font-weight: 600;
                border-bottom: 1px solid var(--border-color); flex-shrink: 0;
            }
            .widget-history-list {
                overflow-y: auto; padding: 4px;
                display: flex; flex-direction: column; gap: 2px;
            }
            .wh-item {
                width: 100%; text-align: left; background: transparent; border: none;
                border-radius: 5px; padding: 6px 8px; cursor: pointer; font-size: 12px;
                color: var(--text-color); transition: background 0.15s;
            }
            .wh-item:hover { background: var(--secondary-color); }
            .wh-item.active { background: var(--secondary-color); border-left: 3px solid var(--link-color); }
            .wh-title { font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            .wh-meta { font-size: 10px; opacity: 0.5; margin-top: 1px; }
            .wh-loading, .wh-empty { text-align: center; padding: 12px; font-size: 12px; opacity: 0.5; }

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
                background: none; border: none; color: var(--text-color);
                font-size: 15px; cursor: pointer; padding: 2px 5px;
                border-radius: 4px; opacity: 0.75;
            }
            
            #close-chat {
                background: none; border: none; color: var(--text-color);
                font-size: 18px; cursor: pointer; opacity: 0.75;
            }
            
            .chat-messages {
                flex-grow: 1;
                padding: 10px 12px;
                overflow-y: auto;
                background-color: var(--background-color);
                display: flex;
                flex-direction: column;
                gap: 6px;
            }

            .msg-wrapper { display: flex; flex-direction: column; max-width: 85%; gap: 2px; }
            .msg-wrapper-user { align-self: flex-end; align-items: flex-end; }
            .msg-wrapper-ai  { align-self: flex-start; align-items: flex-start; }
            .msg-label {
                font-size: 10px; font-weight: 600; opacity: 0.6;
                padding: 0 4px; letter-spacing: 0.02em;
            }
            
            .message {
                padding: 8px 12px;
                border-radius: 18px;
                word-wrap: break-word;
                margin: 0;
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