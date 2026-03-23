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
        activeModel: null,
        isGuest: true,
        isAdmin: false,
        userModelOverride: false,   // true when user manually picks a model
        modelTiers: {
            small:  null,   // fastest/smallest Ollama model
            medium: null,   // mid-size Ollama model
            large:  null,   // largest Ollama model
            grok:   null    // Grok model (premium users)
        }
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

    // Save last 20 chat messages to sessionStorage so they survive page navigation
    function persistMessages() {
        try {
            const items = [];
            document.querySelectorAll('#chat-messages .msg-wrapper').forEach(function(w) {
                const isUser = w.classList.contains('msg-wrapper-user');
                const el = w.querySelector('.message');
                const lbl = w.querySelector('.msg-label');
                if (!el) return;
                items.push({
                    role: isUser ? 'user' : 'ai',
                    html: el.innerHTML,
                    label: lbl ? lbl.textContent : ''
                });
            });
            sessionStorage.setItem('chatMessages', JSON.stringify(items.slice(-20)));
        } catch (e) { }
    }

    // Restore chat messages saved by persistMessages on the previous page
    function restoreMessages() {
        try {
            const saved = sessionStorage.getItem('chatMessages');
            if (!saved) return;
            const items = JSON.parse(saved);
            if (!items || !items.length) return;
            const chatMessages = document.getElementById('chat-messages');
            if (!chatMessages) return;
            chatMessages.innerHTML = '';
            const sep = document.createElement('div');
            sep.className = 'message system-message';
            sep.textContent = '— Previous conversation —';
            chatMessages.appendChild(sep);
            items.forEach(function(item) {
                const wrapper = document.createElement('div');
                wrapper.className = 'msg-wrapper ' + (item.role === 'user' ? 'msg-wrapper-user' : 'msg-wrapper-ai');
                const label = document.createElement('div');
                label.className = 'msg-label';
                label.textContent = item.label || (item.role === 'user' ? 'You' : 'AI');
                const el = document.createElement('div');
                el.className = 'message ' + (item.role === 'user' ? 'user-message' : 'ai-message');
                el.innerHTML = item.html;
                wrapper.appendChild(label);
                wrapper.appendChild(el);
                chatMessages.appendChild(wrapper);
            });
            chatMessages.scrollTop = chatMessages.scrollHeight;
        } catch (e) { }
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
            
            // Check if any URL pattern matches the current pathname (case-insensitive)
            const pathLower = pathname.toLowerCase();
            for (const pattern of agent.url_patterns) {
                let isMatch = false;
                
                if (pattern === '*') {
                    // Wildcard matches everything (use as fallback)
                    isMatch = true;
                } else {
                    // Exact match or prefix match, case-insensitive
                    const patLower = pattern.toLowerCase();
                    isMatch = pathLower === patLower || pathLower.startsWith(patLower);
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

    // Extract all meaningful links from the current page (nav menu + quick links + content links)
    function extractPageLinks() {
        const seen = new Set();
        const navLinks = [];
        const contentLinks = [];
        const skip = /^(javascript:|mailto:|#|$)/i;

        function collectLink(a, bucket) {
            const href = a.getAttribute('href');
            const label = (a.textContent || a.title || '').replace(/\s+/g, ' ').trim();
            if (!href || skip.test(href) || !label || seen.has(href)) return;
            seen.add(href);
            const abs = href.startsWith('http') ? href : (window.location.origin + (href.startsWith('/') ? href : '/' + href));
            bucket.push(label + ': ' + abs);
        }

        // 1. Navigation menu and header links (always include these for link auditing)
        const navSelectors = ['nav', 'header nav', '.navbar', '#main-menu', '#nav', '.nav-menu', '.site-nav', '.menu', 'header'];
        navSelectors.forEach(function(sel) {
            const el = document.querySelector(sel);
            if (!el) return;
            // Exclude the chat widget itself
            if (el.closest('#local-chat-widget, #chat-panel')) return;
            el.querySelectorAll('a[href]').forEach(function(a) { collectLink(a, navLinks); });
        });

        // 2. Quick-link cards and explicitly labelled link sections
        const prioritySelectors = [
            '.quick-link-card', '.quick-links a', '[class*="quick-link"] a',
            '.page-links a', '.link-list a', '.resource-links a',
            '.tabs a', '.tab-links a', '[data-tab] a'
        ];
        prioritySelectors.forEach(function(sel) {
            document.querySelectorAll(sel).forEach(function(a) { collectLink(a, contentLinks); });
        });

        // 3. General content-area links
        const contentSelectors = ['main', '.main-content', '#content', '.content-area', '.page-content', 'article'];
        contentSelectors.forEach(function(sel) {
            const el = document.querySelector(sel);
            if (!el) return;
            el.querySelectorAll('a[href]').forEach(function(a) { collectLink(a, contentLinks); });
        });

        // Return nav links labelled separately so AI knows which section they came from
        const result = [];
        if (navLinks.length)    result.push('[Navigation menu links]\n' + navLinks.map(function(l) { return '  ' + l; }).join('\n'));
        if (contentLinks.length) result.push('[Page content links]\n' + contentLinks.map(function(l) { return '  ' + l; }).join('\n'));
        return result; // array of sections
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
        
        // Extract current page content and links for context awareness
        // extractPageLinks() returns an array of section strings (nav + content)
        const pageContent = extractPageContent();
        const pageLinkSections = extractPageLinks();
        const linksSection = pageLinkSections.length > 0
            ? '\n\nLinks on this page:\n' + pageLinkSections.join('\n\n')
            : '';

        if (selectedAgent) {
            context.page_type = selectedAgent.id;
            context.agent_id = selectedAgent.id;
            context.agent_name = selectedAgent.display_name;
            context.system_prompt = selectedAgent.system_prompt
                + '\nDo NOT invent file paths, documentation URLs, or system details not explicitly provided.'
                + '\nCurrent page: "' + pageTitle + '" at URL: ' + pathname
                + (pageContent ? '\n\nPage content:\n' + pageContent : '')
                + linksSection;
            context.capabilities = selectedAgent.capabilities;
            context.model_settings = selectedAgent.model_settings;
        } else {
            // Fallback to general
            context.page_type = 'general';
            context.agent_id = 'general';
            context.system_prompt = 'You are a helpful AI assistant for the Comserv web application. '
                + 'You can only answer based on information explicitly provided to you here. '
                + 'Do NOT invent file paths, documentation URLs, or system details not shown below.\n\n'
                + 'Current page: "' + pageTitle + '" at URL: ' + pathname
                + (pageContent ? '\n\nPage content:\n' + pageContent : '')
                + linksSection;
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
            '<span id="web-search-toggle" style="display:none;margin-left:6px;" title="Enable Grok web search (uses API credits)">' +
              '<label style="cursor:pointer;font-size:0.85em;user-select:none;">' +
                '<input type="checkbox" id="enable-web-search" style="vertical-align:middle;"> 🔍 Web' +
              '</label>' +
            '</span>' +
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

        // Resize handle (bottom-right corner)
        const resizeHandle = document.createElement('div');
        resizeHandle.id = 'chat-resize-handle';
        resizeHandle.className = 'chat-resize-handle';
        resizeHandle.title = 'Drag to resize';

        // Assemble panel
        chatPanel.appendChild(chatHeader);
        chatPanel.appendChild(historyDrawer);
        chatPanel.appendChild(chatMessages);
        chatPanel.appendChild(providerSelector);
        chatPanel.appendChild(statusIndicator);
        chatPanel.appendChild(chatInput);
        chatPanel.appendChild(resizeHandle);

        // ── Populate provider dropdown ────────────────────────────────────────
        fetch('/ai/get_user_providers', { method: 'GET', credentials: 'include' })
            .then(r => r.json())
            .then(function(data) {
                if (data.success) {
                    if (data.username)  state.username = data.username;
                    if (data.is_admin)  state.isAdmin  = !!data.is_admin;
                    if (data.is_guest !== undefined) state.isGuest = !!data.is_guest;
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
                            // Cheapest Grok for complex queries (non-guest)
                            if (!state.isGuest) {
                                state.modelTiers.grok = grokModels[0] ? grokModels[0].val : 'grok|grok-3-mini';
                            }
                            // Show web search toggle for any user who has Grok access
                            // (toggle applies to Grok requests whether selected manually or via auto-routing)
                            const wst = document.getElementById('web-search-toggle');
                            if (wst) {
                                wst.style.display = 'inline';
                                wst.title = 'Enable web search for Grok requests (uses API credits)';
                            }
                        } else if (p.service === 'ollama' && p.models && p.models.length > 0) {
                            // Filter to chat-capable models only, then sort by size
                            const chatModels = p.models.filter(function(m) { return isChatModel(m.id); });
                            if (chatModels.length > 0) {
                                const sorted = chatModels.slice().sort(function(a, b) {
                                    return modelSizeScore(a.id) - modelSizeScore(b.id);
                                });
                                state.modelTiers.small  = 'ollama|' + sorted[0].id;
                                state.modelTiers.large  = 'ollama|' + sorted[sorted.length - 1].id;
                                state.modelTiers.medium = 'ollama|' + sorted[Math.floor(sorted.length / 2)].id;
                            }
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

        // ── Resize handle ─────────────────────────────────────────────────────
        (function initResize() {
            const rh = document.getElementById('chat-resize-handle');
            if (!rh) return;
            let resizing = false, startX, startY, startW, startH;
            rh.addEventListener('mousedown', function(e) {
                e.preventDefault();
                resizing = true;
                startX = e.clientX; startY = e.clientY;
                const rect = chatPanel.getBoundingClientRect();
                startW = rect.width; startH = rect.height;
                document.body.style.userSelect = 'none';
            });
            document.addEventListener('mousemove', function(e) {
                if (!resizing) return;
                const newW = Math.max(280, Math.min(window.innerWidth  - 20, startW + (e.clientX - startX)));
                const newH = Math.max(300, Math.min(window.innerHeight - 20, startH + (e.clientY - startY)));
                chatPanel.style.width  = newW + 'px';
                chatPanel.style.height = newH + 'px';
            });
            document.addEventListener('mouseup', function() {
                resizing = false;
                document.body.style.userSelect = '';
            });
        })();

        // ── Textarea auto-grow ────────────────────────────────────────────────
        (function initTextareaGrow() {
            const ta = document.getElementById('message-input');
            if (!ta) return;
            ta.addEventListener('input', function() {
                this.style.height = 'auto';
                const max = 140;
                this.style.height = Math.min(this.scrollHeight, max) + 'px';
                this.style.overflowY = this.scrollHeight > max ? 'auto' : 'hidden';
            });
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
            state.userModelOverride = true;   // user chose manually — disable auto-select
            const parts = state.selectedProvider.split('|');
            let modelDisplay;
            const isGrok = parts[0] === 'grok';
            if (isGrok) {
                modelDisplay = 'Grok (xAI)' + (parts[1] ? ': ' + parts[1] : '');
            } else {
                modelDisplay = 'Ollama (Local)' + (parts[1] ? ': ' + parts[1] : '');
            }
            state.activeModel = modelDisplay;
            const statusEl = document.getElementById('chat-status');
            statusEl.textContent = '🔵 ' + modelDisplay + ' (manual)';
            statusEl.className = 'chat-status connected';
            // Show web search toggle only for Grok (admin users see it; controlled server-side too)
            const wsToggle = document.getElementById('web-search-toggle');
            if (wsToggle) wsToggle.style.display = isGrok ? 'inline' : 'none';
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
    
    // Load user's available AI providers and populate model dropdown.
    // Returns a Promise that resolves when role and tiers are known.
    function loadUserProviders() {
        return fetch('/ai/get_user_providers', {
            method: 'GET',
            credentials: 'include'
        })
        .then(response => response.json())
        .then(data => {
            if (!data.success) return;

            if (data.username)              state.username = data.username;
            if (data.is_admin !== undefined) state.isAdmin = !!data.is_admin;
            if (data.is_guest !== undefined) state.isGuest = !!data.is_guest;

            // Hide provider selector and history button for guests / non-admins
            if (data.is_guest || !data.can_access_history) {
                const selectorBar = document.querySelector('.provider-selector');
                if (selectorBar) selectorBar.style.display = 'none';
                const histBtn = document.getElementById('toggle-history-btn');
                if (histBtn) histBtn.style.display = 'none';
                // Clear any stale conversation ID left from a previous login session
                state.currentConversationId = null;
                sessionStorage.removeItem('currentConversationId');
                return;
            }

            if (!data.providers || !data.providers.length) return;

            const providerSelect = document.getElementById('ai-provider');
            if (!providerSelect) return;
            providerSelect.innerHTML = '';

            data.providers.forEach(function(p) {
                if (p.service === 'ollama') {
                    const grp = document.createElement('optgroup');
                    grp.label = 'Ollama (Local)';
                    if (p.models && p.models.length > 0) {
                        // Build model tiers from chat-capable models only, sorted by size
                        const chatModels = p.models.filter(function(m) { return isChatModel(m.id); });
                        if (chatModels.length > 0) {
                            const sorted = chatModels.slice().sort(function(a, b) {
                                return modelSizeScore(a.id) - modelSizeScore(b.id);
                            });
                            state.modelTiers.small  = 'ollama|' + sorted[0].id;
                            state.modelTiers.large  = 'ollama|' + sorted[sorted.length - 1].id;
                            state.modelTiers.medium = 'ollama|' + sorted[Math.floor(sorted.length / 2)].id;
                        }
                        p.models.forEach(function(m) {
                            const opt = document.createElement('option');
                            opt.value = 'ollama|' + m.id;
                            opt.textContent = m.id;
                            grp.appendChild(opt);
                        });
                    } else {
                        const opt = document.createElement('option');
                        opt.value = 'ollama';
                        opt.textContent = 'Ollama (default)';
                        grp.appendChild(opt);
                    }
                    providerSelect.appendChild(grp);
                } else if (p.service === 'grok') {
                    const grp = document.createElement('optgroup');
                    grp.label = 'xAI (Grok)';
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
                        opt.value = m.val;
                        opt.textContent = m.label;
                        grp.appendChild(opt);
                    });
                    providerSelect.appendChild(grp);
                    // Set grok tier for complex queries (non-guest users)
                    if (!state.isGuest && grokModels.length > 0) {
                        state.modelTiers.grok = grokModels[0].val;
                    }
                } else {
                    const opt = document.createElement('option');
                    opt.value = p.service;
                    opt.textContent = p.name || p.display_name || p.service;
                    providerSelect.appendChild(opt);
                }
            });

            // Show web-search toggle only when a Grok option is selected
            const curVal = providerSelect.value || '';
            const wst = document.getElementById('web-search-toggle');
            if (wst) wst.style.display = curVal.startsWith('grok') ? 'inline' : 'none';

            console.debug('Loaded', data.providers.length, 'providers');
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
        
        chatPanel.style.display = 'flex';
        chatButton.style.display = 'none';
        state.isOpen = true;

        // Update chat header with selected agent info
        const chatHeader = document.querySelector('.chat-header h3');
        if (state.pageContext && state.pageContext.agent_name) {
            chatHeader.textContent = state.pageContext.agent_name;
        } else if (state.currentAgent && state.currentAgent.display_name) {
            chatHeader.textContent = state.currentAgent.display_name;
        }

        // Restore messages from sessionStorage immediately (works for all roles)
        const chatMsgsEl = document.getElementById('chat-messages');
        const alreadyHasMessages = chatMsgsEl && chatMsgsEl.querySelectorAll('.msg-wrapper').length > 0;
        if (!alreadyHasMessages) {
            restoreMessages();
        }

        // Resolve role first, then conditionally load server-side history
        loadUserProviders().then(function() {
            if (!state.isGuest) {
                // Authenticated user: restore conversation ID and load history if needed
                loadPersistedState();
                loadConversationList();
                const stillNoMessages = document.getElementById('chat-messages')
                    .querySelectorAll('.msg-wrapper').length === 0;
                if (stillNoMessages && state.currentConversationId) {
                    loadConversation(state.currentConversationId);
                }
            }
            // Guests: nothing to load from server — sessionStorage messages already restored above
        }).catch(function() {});

        // Focus on the input field
        const messageInput = document.getElementById('message-input');
        messageInput.focus();

        // Pre-warm the Ollama model in the background so the user's first
        // real message doesn't hit a cold-start delay.
        const provParts = (state.selectedProvider || 'ollama').split('|');
        if (provParts[0] === 'ollama' && !state._preloadFired) {
            state._preloadFired = true;
            const agentId = (state.pageContext && state.pageContext.agent_id) || '';
            fetch('/ai/preload_model?provider=ollama&agent_id=' + encodeURIComponent(agentId), {
                method: 'GET',
                credentials: 'include'
            }).catch(function() {});
        }
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
        // Classify query complexity to decide PROVIDER (ollama vs grok).
        // For Ollama, we do NOT override the model — the server's _select_model_for_context
        // already picks the best installed model per agent context.
        // We only specify a model when the user manually chose one, or for Grok (where model matters).
        let effectiveProvider = state.selectedProvider || 'ollama';
        let autoTier = null;
        if (!state.userModelOverride) {
            autoTier = classifyQuery(prompt);
            effectiveProvider = autoSelectProvider(autoTier);
            // Reflect auto-selection in the dropdown UI
            const sel = document.getElementById('ai-provider');
            if (sel && sel.querySelector('option[value="' + effectiveProvider + '"]')) {
                sel.value = effectiveProvider;
            }
        }

        // Parse provider|model format (e.g. "grok|grok-3-mini" or "ollama|llama3.1:latest")
        const providerParts = effectiveProvider.split('|');
        const providerName = providerParts[0];
        // Only pass a model name for Grok (client-chosen) or explicit user overrides.
        // For Ollama without user override, let the server select the best model.
        const modelName = (state.userModelOverride || providerName === 'grok')
            ? (providerParts[1] || null)
            : null;

        // Update loading message to show which tier is being used
        if (autoTier) {
            const tierLabel = { nav: 'fast', simple: 'fast', medium: 'standard', complex: 'advanced' }[autoTier] || autoTier;
            const displayName = providerName === 'grok' ? ('Grok: ' + (providerParts[1] || 'auto')) : ('Ollama/' + tierLabel);
            if (loadingMessage) loadingMessage.innerHTML = '<span class="loading-dots">●●●</span> Thinking… <small style="opacity:0.6">(' + displayName + ')</small>';
        }

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

        // Include web search flag — send whenever checkbox is checked.
        // Server enforces role-based access and only activates it for Grok requests.
        const webSearchEl = document.getElementById('enable-web-search');
        if (webSearchEl && webSearchEl.checked) {
            requestPayload.use_search = true;
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
        
        // Provider-aware client timeout: Ollama can be slow loading a large model from disk;
        // give it 180 s (server-side is 150 s). External APIs (Grok etc.) cap at 30 s.
        const isOllama = providerName === 'ollama';
        const clientTimeoutMs = isOllama ? 180000 : 30000;
        const abortCtrl = new AbortController();
        const abortTimer = setTimeout(function() {
            abortCtrl.abort();
        }, clientTimeoutMs);

        // Progressive loading status: update the placeholder message so the user
        // knows a model is being loaded rather than assuming the page is frozen.
        let progressTimer1, progressTimer2;
        if (isOllama) {
            const loadingEl = document.getElementById('ai-loading');
            progressTimer1 = setTimeout(function() {
                if (loadingEl) loadingEl.textContent = '⏳ Loading AI model into memory…';
            }, 15000);
            progressTimer2 = setTimeout(function() {
                if (loadingEl) loadingEl.textContent = '⏳ Still loading model (first load can take ~60 s)… please wait';
            }, 45000);
        }

        fetch(config.apiEndpoints.generateResponse, {
            method: 'POST',
            credentials: 'include',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(requestPayload),
            signal: abortCtrl.signal
        })
        .then(function(response) {
            clearTimeout(abortTimer);
            clearTimeout(progressTimer1);
            clearTimeout(progressTimer2);
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

                // ── Web-search consent flow ───────────────────────────────────
                // Server found no confident answer locally and is asking for
                // permission to search the web via Grok.
                if (data.needs_web_search) {
                    statusIndicator.textContent = '💬 Escalation needed';
                    statusIndicator.className = 'chat-status';
                    const chatMessages = document.getElementById('chat-messages');
                    const consentWrapper = document.createElement('div');
                    consentWrapper.className = 'msg-wrapper msg-wrapper-ai';

                    if (data.partial_answer) {
                        const partialLabel = document.createElement('div');
                        partialLabel.className = 'msg-label';
                        partialLabel.textContent = 'AI (local)';
                        const partialEl = document.createElement('div');
                        partialEl.className = 'message ai-message';
                        partialEl.textContent = data.partial_answer;
                        consentWrapper.appendChild(partialLabel);
                        consentWrapper.appendChild(partialEl);
                    }

                    const consentLabel = document.createElement('div');
                    consentLabel.className = 'msg-label';
                    consentLabel.textContent = 'System';
                    const consentEl = document.createElement('div');
                    consentEl.className = 'message system-message';
                    consentEl.textContent = data.message || "I couldn't find a confident local answer. Search the web?";

                    const yesBtn = document.createElement('button');
                    yesBtn.className = 'chat-retry-btn';
                    yesBtn.textContent = '🔍 Yes, search the web';
                    yesBtn.style.marginRight = '6px';
                    yesBtn.onclick = function() {
                        consentWrapper.remove();
                        // Re-send with Grok web search
                        const grokModel = (state.modelTiers && state.modelTiers.grok)
                                          ? state.modelTiers.grok
                                          : 'grok|grok-3-mini';
                        state.userModelOverride = grokModel;
                        const webEl = document.getElementById('enable-web-search');
                        if (webEl) webEl.checked = true;
                        queryAI(prompt);
                        state.userModelOverride = null;
                    };

                    const noBtn = document.createElement('button');
                    noBtn.className = 'chat-retry-btn';
                    noBtn.textContent = '✕ No thanks';
                    noBtn.onclick = function() { consentWrapper.remove(); };

                    consentWrapper.appendChild(consentLabel);
                    consentWrapper.appendChild(consentEl);
                    consentWrapper.appendChild(yesBtn);
                    consentWrapper.appendChild(noBtn);
                    chatMessages.appendChild(consentWrapper);
                    chatMessages.scrollTop = chatMessages.scrollHeight;
                    return;
                }

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
                
                // Update status with provider + model name + host
                const providerParts2 = (state.selectedProvider || 'ollama').split('|');
                const provName = data.provider || providerParts2[0];
                const rawModel = data.model || providerParts2[1] || '';
                let modelLabel;
                if (provName === 'grok') {
                    modelLabel = 'Grok (xAI)' + (rawModel ? ': ' + rawModel : '');
                } else {
                    const hostLabel = data.ollama_host ? ' @' + data.ollama_host : ' (Local)';
                    modelLabel = 'Ollama' + hostLabel + (rawModel ? ': ' + rawModel : '');
                }
                state.activeModel = modelLabel;
                statusIndicator.textContent = '🟢 ' + modelLabel;
                statusIndicator.className = 'chat-status connected';
                
                // Add AI response
                addMessage(data.response, 'ai-message');
                persistMessages();

                // Append web search citations if returned
                if (data.citations && data.citations.length > 0) {
                    const citationHtml = '<div class="chat-citations"><strong>🔍 Sources:</strong><ul>'
                        + data.citations.map(function(c) {
                            const label = c.title || c.url;
                            return '<li><a href="' + c.url + '" target="_blank" rel="noopener">' + label + '</a></li>';
                          }).join('')
                        + '</ul></div>';
                    const citEl = document.createElement('div');
                    citEl.className = 'chat-message system-message';
                    citEl.innerHTML = citationHtml;
                    document.getElementById('chat-messages').appendChild(citEl);
                }
                
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

                const errText = data.error || 'Failed to get response. Please try again.';
                const isServerTimeout = /timeout|timed.out|read timeout/i.test(errText);

                const chatMessages = document.getElementById('chat-messages');
                const wrapper = document.createElement('div');
                wrapper.className = 'msg-wrapper msg-wrapper-ai';
                const label = document.createElement('div');
                label.className = 'msg-label';
                label.textContent = 'System';
                const errEl = document.createElement('div');
                errEl.className = 'message error-message';
                errEl.textContent = 'Error: ' + errText
                    + (isServerTimeout ? ' — Ollama may still be loading the model.' : '');
                wrapper.appendChild(label);
                wrapper.appendChild(errEl);
                if (isServerTimeout || isOllama) {
                    const retryBtn = document.createElement('button');
                    retryBtn.className = 'chat-retry-btn';
                    retryBtn.textContent = '↺ Try Again';
                    retryBtn.onclick = function() { wrapper.remove(); queryAI(prompt); };
                    wrapper.appendChild(retryBtn);
                }
                chatMessages.appendChild(wrapper);
                chatMessages.scrollTop = chatMessages.scrollHeight;
            }
        })
        .catch(function(error) {
            clearTimeout(abortTimer);
            clearTimeout(progressTimer1);
            clearTimeout(progressTimer2);
            const loading = document.getElementById('ai-loading');
            if (loading) loading.remove();

            console.error('Error querying AI:', error);
            statusIndicator.textContent = 'AI Error';
            statusIndicator.className = 'chat-status error';

            const isTimeout = error.name === 'AbortError';
            const msg = isTimeout
                ? 'Request timed out after ' + (clientTimeoutMs / 1000) + 's.'
                    + (isOllama ? ' Ollama may be loading a large model.' : ' The AI server may be busy.')
                : 'Network error: ' + error.message + '. Please try again.';

            // Show error with a Retry button for timeouts
            const chatMessages = document.getElementById('chat-messages');
            const wrapper = document.createElement('div');
            wrapper.className = 'msg-wrapper msg-wrapper-ai';
            const label = document.createElement('div');
            label.className = 'msg-label';
            label.textContent = 'System';
            const errEl = document.createElement('div');
            errEl.className = 'message error-message';
            errEl.textContent = msg;
            wrapper.appendChild(label);
            wrapper.appendChild(errEl);
            if (isTimeout) {
                const retryBtn = document.createElement('button');
                retryBtn.className = 'chat-retry-btn';
                retryBtn.textContent = '↺ Retry';
                retryBtn.onclick = function() {
                    wrapper.remove();
                    queryAI(prompt);
                };
                wrapper.appendChild(retryBtn);
            }
            chatMessages.appendChild(wrapper);
            chatMessages.scrollTop = chatMessages.scrollHeight;
        });
    }
    
    // Returns true for models that support chat/generate (excludes embeddings, rerankers, etc.)
    function isChatModel(id) {
        const s = id.toLowerCase();
        if (/embed|rerank|bge|nomic|clip|whisper|tts|vision(?!.*instruct)/.test(s)) return false;
        return true;
    }

    // Score an Ollama model ID by approximate parameter size (lower = smaller/faster)
    function modelSizeScore(id) {
        const s = id.toLowerCase();
        if (/tinyllama|1\.1b/.test(s))                        return 1;
        if (/phi(?!.*\d)|1b|2b|3b/.test(s))                   return 2;
        if (/7b|8b|mistral(?!.*\d{2})/.test(s))               return 3;
        if (/13b|14b|llama3\.1(?!.*\d{2})/.test(s))           return 4;
        if (/30b|34b|70b|405b|mixtral/.test(s))               return 5;
        return 3;
    }

    // Classify a user message into a complexity tier
    // Returns: 'nav' | 'simple' | 'medium' | 'complex'
    function classifyQuery(msg) {
        const m = msg.trim();
        if (NAV_RE.test(m)) return 'nav';                   // navigation command

        const lower = m.toLowerCase();
        const words = lower.split(/\s+/);

        // Research / analysis / comparison keywords → complex
        const complexRE = /\b(best|recommend|compar|why|analy|plan|strateg|manag|research|detail|comprehensive|benefit|nutrition|health|optimal|effective|difference|versus|advantage|disadvantage|explain in detail|how should|should i|pros? and cons?)\b/;
        // Simple factual / lookup → simple
        const simpleRE  = /^(what is|where is|who is|when is|how do i|can i|is there|do you|list|find me|give me)\b/;

        const hasComplex = complexRE.test(lower);
        const hasSimple  = simpleRE.test(lower) && words.length < 10;

        if (hasComplex || words.length > 18) return 'complex';
        if (hasSimple  || words.length < 7)  return 'simple';
        return 'medium';
    }

    // Pick the best provider string for a given complexity tier
    function autoSelectProvider(complexity) {
        const t = state.modelTiers;
        if (complexity === 'nav' || complexity === 'simple') {
            return t.small || t.medium || state.selectedProvider;
        }
        if (complexity === 'medium') {
            return t.medium || t.large || state.selectedProvider;
        }
        // complex: use Grok for non-guest users who have it; else largest Ollama
        if (complexity === 'complex' && t.grok && !state.isGuest) {
            return t.grok;
        }
        return t.large || t.medium || state.selectedProvider;
    }

    // Build a flat {label, url} navigation map from links embedded in the system prompt
    function buildNavigationMap() {
        const map = [];
        const prompt = (state.pageContext && state.pageContext.system_prompt) || '';
        const re = /^[ \t]*-[ \t]+(.+?):\s*(https?:\/\/[^\s]+)$/gm;
        let m;
        while ((m = re.exec(prompt)) !== null) {
            map.push({ label: m[1].trim().toLowerCase(), url: m[2].trim() });
        }
        return map;
    }

    // Try to resolve a navigation intent query to a list of {label,url} matches
    function resolveNavIntent(rawQuery) {
        const q = rawQuery
            .replace(/^(open|go to|take me to|navigate to|show me|find|visit)\s+/i, '')
            .replace(/[^\w\s]/g, ' ')
            .replace(/\s+/g, ' ')
            .trim()
            .toLowerCase();
        if (!q || q.length < 2) return null;
        const map = buildNavigationMap();
        const words = q.split(/\s+/);
        const exact  = map.filter(function(item) { return item.label === q; });
        if (exact.length) return exact;
        const starts = map.filter(function(item) { return item.label.startsWith(q) || q.startsWith(item.label); });
        if (starts.length) return starts;
        const partial = map.filter(function(item) {
            return words.every(function(w) { return item.label.includes(w); })
                || item.label.split(/\s+/).some(function(w) { return words.includes(w) && w.length > 3; });
        });
        return partial.length ? partial : null;
    }

    // Navigation command regex
    const NAV_RE = /^(open|go to|take me to|navigate to|show me|find|visit)\s+(.+)/i;

    // Function to send a message
    function sendMessage() {
        const messageInput = document.getElementById('message-input');
        const message = messageInput.value.trim();
        if (!message) return;

        // Ensure page context is ready so navigation map is populated
        if (!state.pageContext) {
            const ensureAgents = state.agentsConfig
                ? Promise.resolve(state.agentsConfig)
                : loadAgentsConfig();
            ensureAgents.then(function() {
                state.pageContext = detectPageContext();
                sendMessage();
            });
            return;
        }

        // Client-side navigation interception — no AI round-trip needed
        const navMatch = message.match(NAV_RE);
        if (navMatch) {
            const matches = resolveNavIntent(message);
            if (matches && matches.length === 1) {
                addMessage(message, 'user-message');
                messageInput.value = '';
                persistMessages();
                addMessage('Navigating to [' + matches[0].label + '](' + matches[0].url + ')', 'ai-message');
                persistMessages();
                setTimeout(function() { window.location.href = matches[0].url; }, 600);
                return;
            } else if (matches && matches.length > 1) {
                addMessage(message, 'user-message');
                messageInput.value = '';
                persistMessages();
                const listMsg = 'Multiple pages match — which one did you mean?\n'
                    + matches.slice(0, 8).map(function(m) { return '- [' + m.label + '](' + m.url + ')'; }).join('\n');
                addMessage(listMsg, 'ai-message');
                persistMessages();
                return;
            }
            // No local match — fall through to AI
        }

        addMessage(message, 'user-message');
        messageInput.value = '';
        persistMessages();
        queryAI(message);
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
        if (className === 'ai-message' && window.AIUtils && AIUtils.formatMessageContent) {
            messageElement.innerHTML = AIUtils.formatMessageContent(text);
        } else {
            messageElement.textContent = text;
        }

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
                background-color: var(--accent-color, #FF9900);
                color: #fff;
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
                background-color: #ffffff;
                border-radius: 10px;
                box-shadow: 0 4px 20px rgba(0,0,0,0.25);
                display: flex;
                flex-direction: column;
                font-family: inherit;
                z-index: 10001;
                overflow: hidden;
            }
            
            .chat-header {
                background-color: var(--accent-color, #FF9900);
                color: #fff;
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
                background: none; border: none; color: #fff;
                font-size: 15px; cursor: pointer; padding: 2px 5px;
                border-radius: 4px; opacity: 0.85; transition: opacity 0.15s, background 0.15s;
            }
            .chat-header-icon-btn:hover { opacity: 1; background: rgba(255,255,255,0.2); }

            /* History drawer */
            .widget-history-drawer {
                display: flex; flex-direction: column;
                background-color: #fafafa;
                border-bottom: 1px solid #ddd;
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
                background: none; border: none; color: #fff;
                font-size: 15px; cursor: pointer; padding: 2px 5px;
                border-radius: 4px; opacity: 0.85;
            }
            
            #close-chat {
                background: none; border: none; color: #fff;
                font-size: 18px; cursor: pointer; opacity: 0.85;
            }
            
            .chat-messages {
                flex-grow: 1;
                padding: 10px 12px;
                overflow-y: auto;
                background-color: #ffffff;
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
                background-color: #f5f5f5;
                color: #333;
                align-self: flex-start;
                margin-right: auto;
                border-bottom-left-radius: 5px;
            }
            
            .user-message {
                background-color: var(--accent-color, #FF9900);
                color: #fff;
                align-self: flex-end;
                margin-left: auto;
                border-bottom-right-radius: 5px;
            }
            
            .ai-message {
                background-color: #f0f4f8;
                color: #222;
                align-self: flex-start;
                margin-right: auto;
                border-bottom-left-radius: 5px;
                border-left: 3px solid var(--accent-color, #FF9900);
            }
            
            .ai-message.loading {
                background-color: #f0f4f8;
                color: #888;
                font-style: italic;
            }
            
            .error-message {
                background-color: #fff3f3;
                border: 1px solid #cc0000;
                color: #cc0000;
                align-self: center;
                margin: 5px auto;
                font-size: 0.9em;
            }
            
            .chat-status {
                padding: 5px 10px;
                font-size: 0.8em;
                text-align: center;
                background-color: #fafafa;
                border-top: 1px solid #ddd;
                color: #555;
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
                border-bottom: 1px solid #ddd;
                display: flex;
                align-items: center;
                gap: 10px;
                font-size: 13px;
            }
            
            .provider-selector label {
                font-weight: 600;
                color: #444;
            }
            
            .provider-selector select {
                flex-grow: 1;
                padding: 5px 10px;
                border: 1px solid #ccc;
                border-radius: 4px;
                background-color: #fff;
                color: #333;
                cursor: pointer;
            }
            
            .manage-keys-link {
                display: inline-flex;
                align-items: center;
                justify-content: center;
                width: 28px;
                height: 28px;
                background: var(--accent-color, #FF9900);
                color: #fff;
                border-radius: 4px;
                text-decoration: none;
                font-size: 14px;
                transition: opacity 0.2s;
            }
            
            .manage-keys-link:hover {
                opacity: 0.85;
                text-decoration: none;
            }
            
            .chat-input {
                padding: 10px;
                border-top: 1px solid var(--border-color);
                display: flex;
            }
            
            #message-input {
                flex-grow: 1;
                border: 1px solid #ccc;
                border-radius: 4px;
                padding: 8px;
                resize: none;
                height: 40px;
                margin-right: 8px;
                background-color: #fff;
                color: #222;
            }
            
            #send-message {
                background-color: var(--accent-color, #FF9900);
                color: #fff;
                border: none;
                border-radius: 4px;
                padding: 8px 15px;
                cursor: pointer;
                font-family: inherit;
            }
            
            #send-message:hover {
                opacity: 0.85;
            }
            
            #send-message:disabled {
                background-color: #ccc;
                color: #888;
                cursor: not-allowed;
            }

            .chat-resize-handle {
                position: absolute;
                bottom: 0;
                right: 0;
                width: 16px;
                height: 16px;
                cursor: se-resize;
                background: linear-gradient(135deg, transparent 50%, #aaa 50%);
                border-bottom-right-radius: 10px;
                opacity: 0.6;
                z-index: 10;
            }
            .chat-resize-handle:hover { opacity: 1; }

            .chat-retry-btn {
                display: block;
                margin-top: 6px;
                padding: 4px 12px;
                border: 1px solid #ccc;
                border-radius: 4px;
                background: #f5f5f5;
                color: #333;
                cursor: pointer;
                font-size: 0.85em;
                font-family: inherit;
            }
            .chat-retry-btn:hover { opacity: 0.8; }
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