/**
 * Live Chat Implementation with Context-Aware Agent Selection
 * A chat widget that connects to the server API and selects agents based on page context
 */

(function() {
    // PAGE_MODE: when true, local-chat.js binds to the /ai page's existing DOM
    // instead of creating a floating widget.  Set window.AI_CHAT_PAGE_MODE = true
    // in ai/index.tt before this script loads.
    const PAGE_MODE = !!(window.AI_CHAT_PAGE_MODE);

    // Configuration
    const config = {
        apiEndpoints: {
            generateResponse: '/ai2/chat',
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
        isDevMode: false,           // true only on local development machine
        userModelOverride: false,   // true when user manually picks a model
        modelTiers: {
            small:  null,   // fastest/smallest Ollama model
            medium: null,   // mid-size Ollama model
            large:  null,   // largest Ollama model
            grok:   null    // Grok model (premium users)
        },
        ollamaHost: null,
        supportMode: false,         // true when user is in live support chat mode
        supportConvId: null,        // conversation_id for current support chat
        supportLastMsgId: 0,        // last message id seen in support chat
        // supportPollTimer removed – SSE migration complete
        siteName: '',                // SiteName from session (e.g. 'BMaster', 'CSC', 'Shanta')
        isUnloading: false
    };
    
    window.addEventListener('beforeunload', function() {
        state.isUnloading = true;
        if (window.AI_WIDGET_POPUP) {
            try {
                localStorage.removeItem('ai_popup_active');
            } catch(e) {}
        }
    });
    
    // Per-tab nonce: generated fresh each time the script runs in a new JS context.
    // sessionStorage is tab-isolated, but tab duplication copies it.  We detect
    // duplication by writing this nonce into sessionStorage on first use; if the
    // stored nonce differs from ours the tab was duplicated and should start fresh.
    const _TAB_NONCE = Math.random().toString(36).slice(2);

    // Load persisted state from sessionStorage (or from window.AI_RESUME_CONVERSATION
    // when the widget was opened as a popup/detached window)
    function loadPersistedState() {
        try {
            // Popup windows set AI_RESUME_CONVERSATION from the URL param via the template
            if (window.AI_RESUME_CONVERSATION && !state.currentConversationId) {
                state.currentConversationId = parseInt(window.AI_RESUME_CONVERSATION);
                console.debug('Restored conversation ID from popup param:', state.currentConversationId);
                return;
            }

            // Detect duplicated tabs: if the stored nonce doesn't match ours, the
            // sessionStorage was inherited from another tab → start fresh.
            const storedNonce = sessionStorage.getItem('ai_tab_nonce');
            if (storedNonce && storedNonce !== _TAB_NONCE) {
                console.debug('[AI] Duplicated tab detected — starting fresh conversation');
                sessionStorage.removeItem('currentConversationId');
                sessionStorage.removeItem('chatMessages');
                sessionStorage.setItem('ai_tab_nonce', _TAB_NONCE);
                return;
            }
            sessionStorage.setItem('ai_tab_nonce', _TAB_NONCE);

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
                // When running as a popup widget, also write to localStorage so the
                // parent page can resume the same conversation when the popup closes.
                if (window.AI_WIDGET_POPUP) {
                    localStorage.setItem('ai_popup_conv_id', state.currentConversationId);
                }
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
            // Walk ALL direct children in order so thinking blocks stay in sequence
            const chatMessages = document.getElementById('chat-messages');
            if (!chatMessages) return;
            Array.from(chatMessages.children).forEach(function(child) {
                if (child.classList.contains('msg-wrapper')) {
                    const isUser = child.classList.contains('msg-wrapper-user');
                    const el  = child.querySelector('.message');
                    const lbl = child.querySelector('.msg-label');
                    if (!el) return;
                    items.push({
                        type:  'message',
                        role:  isUser ? 'user' : 'ai',
                        html:  el.innerHTML,
                        label: lbl ? lbl.textContent : '',
                        cls:   el.className
                    });
                } else if (child.classList.contains('ai-thinking')) {
                    // Persist thinking/trace block
                    const summary = child.querySelector('summary');
                    const steps   = Array.from(child.querySelectorAll('.ai-thinking-step'))
                                        .map(function(s) { return s.textContent; });
                    items.push({
                        type:    'thinking',
                        summary: summary ? summary.textContent : '🔍 AI Thinking',
                        steps:   steps,
                        open:    child.open || false
                    });
                }
            });
            sessionStorage.setItem('chatMessages', JSON.stringify(items.slice(-30)));
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
                if (item.type === 'thinking') {
                    const details = document.createElement('details');
                    details.className = 'ai-thinking';
                    if (item.open) details.open = true;
                    const summary = document.createElement('summary');
                    summary.textContent = item.summary || '🔍 AI Thinking';
                    const body = document.createElement('div');
                    body.className = 'ai-thinking-body';
                    (item.steps || []).forEach(function(step) {
                        const stepEl = document.createElement('div');
                        stepEl.className = 'ai-thinking-step';
                        stepEl.textContent = step;
                        body.appendChild(stepEl);
                    });
                    details.appendChild(summary);
                    details.appendChild(body);
                    chatMessages.appendChild(details);
                } else {
                    // Regular message wrapper
                    const isUser = item.role === 'user';
                    const wrapper = document.createElement('div');
                    wrapper.className = 'msg-wrapper ' + (isUser ? 'msg-wrapper-user' : 'msg-wrapper-ai');
                    const label = document.createElement('div');
                    label.className = 'msg-label';
                    label.textContent = item.label || (isUser ? 'You' : 'AI');
                    const el = document.createElement('div');
                    el.className = item.cls || ('message ' + (isUser ? 'user-message' : 'ai-message'));
                    el.innerHTML = item.html;
                    wrapper.appendChild(label);
                    wrapper.appendChild(el);
                    chatMessages.appendChild(wrapper);
                }
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
    
    // Populate the agent picker dropdown from agentsConfig, respecting local_only + isDevMode
    function populateAgentPicker() {
        var sel = document.getElementById('ai-agent-select');
        if (!sel || !state.agentsConfig || !state.agentsConfig.agents) return;
        var agents = state.agentsConfig.agents;
        // Keep the Auto option, then add one per eligible agent
        sel.innerHTML = '<option value="auto">⚡ Auto</option>';
        Object.entries(agents).forEach(function([key, agent]) {
            if (agent.local_only  && !state.isDevMode) return;
            if (agent.admin_only  && !state.isAdmin)   return;
            var opt = document.createElement('option');
            opt.value = key;
            opt.textContent = (agent.icon || '') + ' ' + (agent.display_name || key);
            sel.appendChild(opt);
        });
        // Site-name → default agent map (when no saved preference)
        var siteAgentMap = {
            'BMaster':    'beemaster',
            'ENCY':       'ency',
            'CSC':        'csc',
            'HelpDesk':   'helpdesk',
        };

        // Restore previously saved agent selection, or auto-select by site.
        // URL-based match always wins over saved preference (so navigating to /ENCY
        // always gets the ency agent even if the user last selected "coding").
        var saved = localStorage.getItem('ai_widget_agent');
        var urlAgent = selectAgentForPage();
        if (urlAgent && urlAgent.id && sel.querySelector('option[value="' + urlAgent.id + '"]')) {
            sel.value = urlAgent.id;
            _applyAgentOverride(urlAgent.id);
        } else if (saved && sel.querySelector('option[value="' + saved + '"]')) {
            sel.value = saved;
            if (saved !== 'auto') _applyAgentOverride(saved);
        } else if (state.siteName && siteAgentMap[state.siteName]) {
            var siteAgent = siteAgentMap[state.siteName];
            if (sel.querySelector('option[value="' + siteAgent + '"]')) {
                sel.value = siteAgent;
                _applyAgentOverride(siteAgent);
            }
        }
        sel.addEventListener('change', function() {
            var chosen = sel.value;
            localStorage.setItem('ai_widget_agent', chosen);
            if (chosen === 'auto') {
                state.agentOverride = null;
                state.pageContext = detectPageContext();
                _updateAgentBanner('auto');
            } else {
                _applyAgentOverride(chosen);
            }
        });
        sel.dataset.populated = '1';
    }

    function _applyAgentOverride(agentKey) {
        if (!state.agentsConfig || !state.agentsConfig.agents) return;
        var agent = state.agentsConfig.agents[agentKey];
        if (!agent) return;
        state.agentOverride = agentKey;
        state.currentAgent = agent;
        var ctx = detectPageContext() || {};
        ctx.agent_id   = agent.id;
        ctx.agent_name = agent.display_name;
        if (agent.system_prompt) ctx.system_prompt = agent.system_prompt;
        state.pageContext = ctx;
        _updateAgentBanner(agentKey);
        updatePageLabel();
    }

    function _updateAgentBanner(agentKey) {
        var banner = document.getElementById('chat-agent-banner');
        if (!banner) return;
        if (agentKey === 'template_editor') {
            banner.innerHTML = '✏️ <strong>Template Editor</strong> — Use the dedicated form to load, edit, and apply template changes: ' +
                '<a href="/ai/template_editor" target="_blank" style="color:#1a73e8;font-weight:bold;">Open Template Editor →</a>';
            banner.style.display = 'block';
        } else {
            banner.style.display = 'none';
        }
    }

    // ── _collectPageErrors ────────────────────────────────────────────────────
    // Scans the current page DOM for visible error messages and returns a
    // formatted string to prepend to coding-agent prompts.
    function _collectPageErrors() {
        var errors = [];
        var seen = {};

        var selectors = [
            '.error-message', '.alert-danger', '.alert-error',
            '#error-message', '.flash-error', '.catalyst-error',
            '.exception-title', '.exception-message',
            '[class*="error"]', '[id*="error"]'
        ];

        selectors.forEach(function(sel) {
            try {
                document.querySelectorAll(sel).forEach(function(el) {
                    var txt = (el.innerText || '').trim();
                    if (txt && txt.length > 5 && txt.length < 2000 && !seen[txt]) {
                        seen[txt] = 1;
                        errors.push(txt);
                    }
                });
            } catch(e) {}
        });

        // Also check page title for Catalyst error pages
        if (document.title && /error|exception|500|404/i.test(document.title)) {
            var bodySnippet = (document.body && document.body.innerText || '').substring(0, 800).trim();
            if (bodySnippet && !seen[bodySnippet.substring(0, 50)]) {
                errors.push('Page title: ' + document.title + '\n' + bodySnippet);
            }
        }

        if (!errors.length) return '';

        return '[PAGE ERROR DETECTED]\n' + errors.slice(0, 3).join('\n---\n') + '\n[/PAGE ERROR]';
    }

    // ── _getTemplatePathForPage ────────────────────────────────────────────────
    // Maps the current page URL to its TT2 template file path (relative to project root).
    function _getTemplatePathForPage(pathname) {
        var map = {
            '/':              'root/CSC/CSC.tt',
            '/CSC':           'root/CSC/CSC.tt',
            '/hosting':       'root/CSC/proxy_manager.tt',
            '/BMaster':       'root/BMaster/index.tt',
            '/ENCY':          'root/ENCY/index.tt',
            '/workshop':      'root/Workshops/index.tt',
            '/HelpDesk':      'root/HelpDesk/index.tt',
            '/membership':    'root/membership/index.tt',
            '/marketplace':   'root/marketplace/index.tt',
            '/shop':          'root/shop/index.tt',
            '/Documentation': 'root/Documentation/index.tt',
            '/ai':            'root/ai/index.tt',
            '/admin':         'root/admin/index.tt',
        };
        var clean = pathname.replace(/\/$/, '') || '/';
        if (map[clean]) return map[clean];
        for (var key in map) {
            if (clean.startsWith(key + '/')) return map[key];
        }
        var parts = clean.replace(/^\//, '').split('/');
        if (parts.length >= 2) {
            var ctrl = parts[0].charAt(0).toUpperCase() + parts[0].slice(1);
            return 'root/' + ctrl + '/' + parts[1].toLowerCase() + '.tt';
        } else if (parts[0]) {
            // Convention: site homepages use {Ctrl}/{Ctrl}.tt (e.g. Shanta/Shanta.tt, CSC/CSC.tt)
            // Fall back to {Ctrl}/index.tt when the controller-name variant is not in the static map
            var ctrl = parts[0].charAt(0).toUpperCase() + parts[0].slice(1);
            return 'root/' + ctrl + '/' + ctrl + '.tt';
        }
        return null;
    }

    // ── _handleReadFileRequest ─────────────────────────────────────────────────
    // Called when the AI response contains [READ_FILE: path] tokens.
    // Fetches the file content and sends it back as a follow-up context message.
    function _handleReadFileRequest(path) {
        var url = '/ai/read_file?path=' + encodeURIComponent(path) + '&limit=300';
        fetch(url, { credentials: 'include' })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (data.success) {
                    var ctx = '[FILE: ' + data.path + ' (lines ' + (data.offset + 1)
                            + '-' + (data.offset + data.lines) + ' of ' + data.total + ')]\n'
                            + '```\n' + data.content + '\n```\n[/FILE]';
                    var msgInput = document.getElementById('message-input');
                    if (msgInput) {
                        msgInput.value = ctx + '\n\n(File loaded. Please continue your analysis.)';
                    }
                } else {
                    var msgInput = document.getElementById('message-input');
                    if (msgInput) msgInput.value = '[Could not read file: ' + data.error + ']';
                }
            })
            .catch(function(e) { console.error('read_file error', e); });
    }

    // Match page URL against agent patterns and select appropriate agent
    function selectAgentForPage() {
        const pathname = window.location.pathname;
        
        if (!state.agentsConfig || !state.agentsConfig.agents) {
            console.warn('Agents config not loaded, using general agent');
            return null;
        }
        
        const agents = state.agentsConfig.agents;

        // On todo/project detail pages, pick the agent based on the todo subject text
        // rather than the URL — the subject tells us which domain the work belongs to.
        const isTodoDetail    = pathname.startsWith('/todo/details') || pathname.startsWith('/todo/view');
        const isProjectDetail = pathname.startsWith('/project/details');
        if (isTodoDetail || isProjectDetail) {
            // Gather candidate text: page <h1>, <h2>, <title>, and the first .subject / .todo-subject element
            const candidateEls = [
                document.querySelector('h1'),
                document.querySelector('h2'),
                document.querySelector('.todo-subject'),
                document.querySelector('.subject'),
                document.querySelector('.todo-title'),
                document.querySelector('[data-todo-subject]'),
            ];
            const candidateText = candidateEls
                .filter(Boolean)
                .map(function(el) { return el.textContent || el.getAttribute('data-todo-subject') || ''; })
                .join(' ')
                .toUpperCase();

            if (/\bENCY\b|HERB|BOTANICAL|CONSTITUENT|PLANT\b/.test(candidateText) && agents.ency) {
                console.debug('Agent selected from todo content: ency');
                return agents.ency;
            }
            if (/\bBEEMASTER\b|\bBMASTER\b|HIVE|APIARY|VARROA|QUEEN\b|INSPECTION/.test(candidateText) && agents.beemaster) {
                console.debug('Agent selected from todo content: beemaster');
                return agents.beemaster;
            }
            if (/\bINVENTORY\b|STOCK\b|\bSKU\b|\bBOM\b/.test(candidateText) && agents.inventory) {
                console.debug('Agent selected from todo content: inventory');
                return agents.inventory;
            }
            if (/\bHELPDESK\b|SUPPORT\b|TICKET\b/.test(candidateText) && agents.helpdesk) {
                console.debug('Agent selected from todo content: helpdesk');
                return agents.helpdesk;
            }
            // Todo/project detail with no domain match → use planning agent
            if (agents.planning) {
                console.debug('Agent selected for todo/project detail: planning');
                return agents.planning;
            }
        }
        
        // Check each agent's URL patterns
        for (const [agentKey, agent] of Object.entries(agents)) {
            if (!agent.url_patterns) continue;
            if (agent.local_only && !state.isDevMode) continue;
            
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
                return text.substring(0, 6000);
            }
        }
        // Fallback: body text
        const bodyClone = document.body.cloneNode(true);
        bodyClone.querySelectorAll(skipSelectors).forEach(function(e) { e.remove(); });
        const bodyText = bodyClone.textContent.replace(/\s+/g, ' ').trim();
        return bodyText.substring(0, 4000);
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
        // In PAGE_MODE (detached popup), honour the originating page URL so the
        // same agent and context are used as on the page the widget was on.
        let pathname = window.HELPDESK_PRESCREEN_PAGE_PATH || window.location.pathname;
        let pageTitle = window.HELPDESK_PRESCREEN_PAGE_TITLE || document.title || 'Unknown Page';
        if ((PAGE_MODE || window.AI_WIDGET_POPUP) && (state.detachedFromPath || window.AI_DETACHED_FROM_PATH)) {
            pathname  = state.detachedFromPath  || window.AI_DETACHED_FROM_PATH  || pathname;
            pageTitle = state.detachedFromTitle || window.AI_DETACHED_FROM_TITLE || pageTitle;
        }
        
        // Try to load and select agent from config
        const selectedAgent = selectAgentForPage();
        state.currentAgent = selectedAgent;
        
        let context = {
            page_path: pathname + (window.location.search || ''),
            page_title: pageTitle,
            page_url: window.AI_WIDGET_POPUP
                ? (window.location.origin + pathname)
                : window.location.href
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
            '<div class="chat-header-title-group">' +
                '<h3 id="chat-title">AI Assistant</h3>' +
                '<span id="chat-page-label" class="chat-page-label" title="Page being assisted"></span>' +
            '</div>' +
            '<div class="chat-header-buttons">' +
                '<button id="toggle-history-btn" class="chat-header-icon-btn" title="Conversation history">🕐</button>' +
                '<a id="conversations-link" class="chat-header-icon-btn" href="/ai/conversations" title="View all conversations" target="_self">📋 History</a>' +
                '<button id="new-chat" class="chat-header-icon-btn" title="New conversation">✏️</button>' +
                '<button id="voice-mode-btn" class="chat-header-icon-btn" title="Voice conversation mode — speak to AI, AI speaks back" style="display:none;">🔊</button>' +
                '<button id="dock-chat-inline" class="chat-header-icon-btn" title="Dock chat on this page">⊞</button>' +
                '<button id="detach-chat" class="chat-header-icon-btn" title="Open in separate window (move to another monitor)">⤢</button>' +
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
            '<label for="ai-agent-select" style="font-size:0.82em;color:#555;">Agent:</label>' +
            '<select id="ai-agent-select" title="Select AI agent / assistant" style="font-size:0.82em;max-width:110px;">' +
              '<option value="auto">⚡ Auto</option>' +
            '</select>' +
            '<label for="ai-provider">Model:</label>' +
            '<select id="ai-provider"><option value="ollama">Ollama (Local)</option></select>' +
            '<span id="web-search-toggle" style="display:none;margin-left:6px;" title="Enable Grok web search (uses API credits)">' +
              '<label style="cursor:pointer;font-size:0.85em;user-select:none;">' +
                '<input type="checkbox" id="enable-web-search" style="vertical-align:middle;"> 🔍 Web' +
              '</label>' +
            '</span>' +
            '<a href="/ai/manage_api_keys" target="_blank" class="manage-keys-link" title="Manage API keys">⚙️</a>';

        // Agent-specific banner (shown when a special agent needs a dedicated page)
        const agentBanner = document.createElement('div');
        agentBanner.id = 'chat-agent-banner';
        agentBanner.style.cssText = 'display:none;padding:6px 10px;background:#fffbe6;border-top:1px solid #f0c000;' +
            'border-bottom:1px solid #f0c000;font-size:0.82em;color:#555;';

        // Status indicator
        const statusIndicator = document.createElement('div');
        statusIndicator.id = 'chat-status';
        statusIndicator.className = 'chat-status';
        statusIndicator.textContent = 'AI Ready';

        // Input area
        const chatInput = document.createElement('div');
        chatInput.className = 'chat-input';
        chatInput.innerHTML =
            '<div id="chat-img-preview" style="display:none;padding:4px 0 2px;position:relative;"></div>' +
            '<div id="audio-transcribe-status" style="display:none;padding:3px 6px;font-size:0.82em;color:var(--text-color,#333);background:var(--table-header-bg,#f0f7ff);border:1px solid var(--border-color,#ddd);border-radius:4px;margin-bottom:3px;"></div>' +
            '<div id="local-audio-backups-container" style="display:none;padding:5px;border:1px solid var(--border-color,#ccc);border-radius:4px;background:var(--background-color,#fff);margin-bottom:4px;font-size:0.85em;"></div>' +
            '<div style="display:flex;gap:3px;align-items:stretch;">' +
            '<textarea id="message-input" style="flex:1;" placeholder="Type your message… (Ctrl+V to paste image)"></textarea>' +
            '<div style="display:flex;flex-direction:column;gap:3px;">' +
            '<label id="attach-image-btn" title="Attach image or upload audio file (or paste image with Ctrl+V)" style="display:none;cursor:pointer;padding:4px 8px;background:var(--button-bg,#f0f0f0);color:var(--button-text,#000);border:1px solid var(--button-border,#ccc);border-radius:4px;font-size:1.2em;user-select:none;text-align:center;">📎<input type="file" id="image-file-input" accept="image/*,audio/*,.m4a,.wav,.mp3,.ogg,.webm" style="display:none;"></label>' +
            '<label id="attach-audio-btn" title="Upload a saved audio file (.mp3, .m4a, .wav, .ogg, .webm) for transcription" style="cursor:pointer;padding:4px 8px;background:var(--button-bg,#f0f0f0);color:var(--button-text,#000);border:1px solid var(--button-border,#ccc);border-radius:4px;font-size:1.1em;user-select:none;text-align:center;" aria-label="Upload audio file">📂<input type="file" id="audio-file-input" accept="audio/*,.m4a,.wav,.mp3,.ogg,.webm" style="display:none;"></label>' +
            '<button id="mic-record-btn" title="Record voice inspection — click to start, click again to stop. No time limit." style="padding:4px 8px;background:var(--button-bg,#f0f0f0);color:var(--button-text,#000);border:1px solid var(--button-border,#ccc);border-radius:4px;font-size:1.1em;cursor:pointer;" aria-label="Record audio">🎤</button>' +
            '<button id="send-message" style="flex:1;">Send</button>' +
            '</div></div>';

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
        chatPanel.appendChild(agentBanner);
        chatPanel.appendChild(statusIndicator);
        chatPanel.appendChild(chatInput);
        chatPanel.appendChild(resizeHandle);

        // ── Populate provider dropdown ────────────────────────────────────────
        fetch('/ai2/providers', { method: 'GET', credentials: 'include' })
            .then(r => r.json())
            .then(function(data) {
                if (data.success) {
                    if (data.username)  state.username   = data.username;
                    if (data.is_admin)  state.isAdmin    = !!data.is_admin;
                    if (data.is_guest !== undefined) state.isGuest   = !!data.is_guest;
                    if (data.is_dev   !== undefined) state.isDevMode = !!data.is_dev;
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
                                    { val: 'grok|grok-4.3',               label: 'Grok 4.3 (xAI)' },
                                    { val: 'grok|grok-4.20-non-reasoning', label: 'Grok 4.20 Fast (xAI)' }
                                ];
                            grokModels.forEach(function(m) {
                                const opt = document.createElement('option');
                                opt.value = m.val; opt.textContent = m.label;
                                grp.appendChild(opt);
                            });
                            sel.appendChild(grp);
                            // Cheapest Grok for complex queries (non-guest)
                            if (!state.isGuest) {
                                state.modelTiers.grok = grokModels[0] ? grokModels[0].val : 'grok|grok-4.3';
                            }
                            // Show web search toggle for any user who has Grok access
                            // (toggle applies to Grok requests whether selected manually or via auto-routing)
                            const wst = document.getElementById('web-search-toggle');
                            if (wst) {
                                wst.style.display = 'inline';
                                wst.title = 'Enable web search for Grok requests (uses API credits)';
                            }
                        } else if (p.service === 'ollama') {
                            state.ollamaHost = p.active_host;
                            // Update the default "Ollama (Local)" option label
                            const defaultOpt = sel.querySelector('option[value="ollama"]');
                            if (defaultOpt) defaultOpt.textContent = p.name || 'Ollama (Local AI)';

                            // Admin server switcher: add optgroup if multiple servers available
                            if (p.servers && p.servers.length > 1 && data.is_admin) {
                                const svrGrp = document.createElement('optgroup');
                                svrGrp.label = 'Ollama Server';
                                p.servers.forEach(function(srv) {
                                    const opt = document.createElement('option');
                                    opt.value = 'ollama_server|' + srv.host;
                                    opt.textContent = srv.label + (srv.active ? ' ✓' : '');
                                    if (srv.active) opt.selected = false; // keep default selected
                                    svrGrp.appendChild(opt);
                                });
                                sel.appendChild(svrGrp);
                            }

                            // Build model tiers from chat-capable installed models.
                            // Exclude sub-2B toy models (tinyllama, 1.1b, etc.) from
                            // auto-selection — they produce unreliable answers.
                            if (p.models && p.models.length > 0) {
                                const chatModels = p.models.filter(function(m) { return isChatModel(m.id); });
                                if (chatModels.length > 0) {
                                    const sorted = chatModels.slice().sort(function(a, b) {
                                        return modelSizeScore(a.id) - modelSizeScore(b.id);
                                    });
                                    const usable = sorted.filter(function(m) { return modelSizeScore(m.id) >= 3; });
                                    const pool   = usable.length > 0 ? usable : sorted; // fallback if all tiny
                                    state.modelTiers.small  = 'ollama|' + pool[0].id;
                                    state.modelTiers.large  = 'ollama|' + pool[pool.length - 1].id;
                                    state.modelTiers.medium = 'ollama|' + pool[Math.floor(pool.length / 2)].id;
                                }
                            }
                        } else {
                            // Generic external provider (OpenRouter, OpenAI, Groq, ...)
                            const grp = document.createElement('optgroup');
                            grp.label = (p.name || p.service || 'External');
                            const extModels = (p.models && p.models.length > 0)
                                ? p.models
                                    .filter(function(m) { return m.id && !m.id.match(/imagine|video|embed|rerank/i); })
                                    .map(function(m) {
                                        const label = (m.label || m.id).replace(/-/g, ' ');
                                        return { val: p.service + '|' + m.id, label: label + ' (' + p.service + ')' };
                                    })
                                : [{ val: p.service + '|' + p.service, label: (p.name || p.service) + ' (external)' }];
                            extModels.forEach(function(m) {
                                const opt = document.createElement('option');
                                opt.value = m.val; opt.textContent = m.label;
                                grp.appendChild(opt);
                            });
                            sel.appendChild(grp);
                            // Expose a tier for this external provider if none set
                            if (!state.modelTiers[p.service]) {
                                state.modelTiers[p.service] = extModels[0] ? extModels[0].val : (p.service + '|' + p.service);
                            }
                        }
                    });
                }

                // Pre-warm the Ollama model at page-load time so the first real
                // message doesn't hit a cold-start delay.  Re-warm every 25 min
                // (keep_alive is 2h so this ensures the model stays in VRAM).
                function _firePreload() {
                    if ((state.selectedProvider || 'ollama').split('|')[0] !== 'ollama') return;
                    const agentId = (state.pageContext && state.pageContext.agent_id) || '';
                    fetch('/ai/preload_model?provider=ollama&agent_id=' + encodeURIComponent(agentId), {
                        method: 'GET',
                        credentials: 'include'
                    }).catch(function() {});
                }
                _firePreload();
                // Re-fire every 110 minutes to keep model warm (keep_alive is 2h)
                state._preloadTimer = setInterval(_firePreload, 110 * 60 * 1000);

                // Populate agent picker now that is_dev is known
                if (state.agentsConfig) {
                    populateAgentPicker();
                } else {
                    loadAgentsConfig().then(function() { populateAgentPicker(); });
                }

                // Show/hide image attach based on admin role
                var attachBtn = document.getElementById('attach-image-btn');
                if (attachBtn) {
                    attachBtn.style.display = state.isAdmin ? '' : 'none';
                }
            })
            .catch(function() {});

        // ── Drag to move ──────────────────────────────────────────────────────
        (function initDrag() {
            const handle = document.getElementById('chat-drag-handle');
            let dragging = false, startX, startY, origLeft, origBottom, origTop, origRight;

            handle.addEventListener('mousedown', function(e) {
                if (window.innerWidth <= 600) return;
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
                if (window.innerWidth <= 600) return;
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
            const max = 200;
            ta.addEventListener('input', function() {
                this.style.height = 'auto';
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

        // ── Image attachment helpers ──────────────────────────────────────────
        function _setPendingImage(file) {
            const reader = new FileReader();
            reader.onload = function(ev) {
                const dataUrl = ev.target.result;
                const mime = file.type || 'image/jpeg';
                const b64  = dataUrl.split(',')[1];
                state.pendingImage = { data: b64, mime: mime, dataUrl: dataUrl };
                const prev = document.getElementById('chat-img-preview');
                if (prev) {
                    prev.style.display = 'block';
                    prev.innerHTML = '<img src="' + dataUrl + '" style="max-height:80px;max-width:120px;border-radius:4px;border:1px solid #ccc;vertical-align:middle;">' +
                        ' <button type="button" title="Remove image" onclick="_clearPendingImage()" style="font-size:1em;border:none;background:none;cursor:pointer;color:#c00;">✕</button>' +
                        ' <small style="color:#666;">' + (file.name || 'image') + '</small>';
                }
            };
            reader.readAsDataURL(file);
        }
        window._clearPendingImage = function() {
            state.pendingImage = null;
            const prev = document.getElementById('chat-img-preview');
            if (prev) { prev.style.display = 'none'; prev.innerHTML = ''; }
            const fi = document.getElementById('image-file-input');
            if (fi) fi.value = '';
        };
        window._handleReadFileRequest = _handleReadFileRequest;

        // ── Other events ──────────────────────────────────────────────────────
        // Chat bubble: desktop → popup window; mobile → inline panel
        var _isMobile = /Mobi|Android|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)
            || (window.matchMedia && window.matchMedia('(pointer: coarse)').matches && window.innerWidth < 1024);
        chatButton.addEventListener('click', function() {
            if ((state._popupWindow && !state._popupWindow.closed) || localStorage.getItem('ai_popup_active') === '1') {
                detachToPopup();
            } else {
                openChatPreferred();
            }
        });
        document.getElementById('close-chat').addEventListener('click', function() { closeChat(); });
        document.getElementById('new-chat').addEventListener('click', function() { resetConversation(); });
        var dockBtn = document.getElementById('dock-chat-inline');
        if (dockBtn) {
            dockBtn.addEventListener('click', function() {
                if (window.AI_WIDGET_POPUP && window.opener && !window.opener.closed) {
                    if (window.opener.ComservAIChat && window.opener.ComservAIChat.openInline) {
                        window.opener.ComservAIChat.openInline();
                    } else if (window.opener.openChat) {
                        window.opener.openChat();
                    }
                    window.close();
                    return;
                }
                if (state._popupWindow && !state._popupWindow.closed) {
                    state._popupWindow.close();
                    state._popupWindow = null;
                }
                openChat();
            });
        }
        var detachBtn = document.getElementById('detach-chat');
        if (detachBtn) {
            if (_isMobile) {
                detachBtn.style.display = 'none';
                if (dockBtn) dockBtn.style.display = 'none';
            } else {
                detachBtn.addEventListener('click', function() {
                    if (state._popupWindow && !state._popupWindow.closed) {
                        state._popupWindow.focus();
                    } else {
                        detachToPopup();
                    }
                });
            }
        }
        document.getElementById('send-message').addEventListener('click', sendMessage);
        document.getElementById('message-input').addEventListener('keypress', function(e) {
            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
        });
        document.getElementById('message-input').addEventListener('paste', function(e) {
            if (!state.isAdmin) return;
            const items = (e.clipboardData || window.clipboardData).items;
            for (var i = 0; i < items.length; i++) {
                if (items[i].type.indexOf('image') !== -1) {
                    e.preventDefault();
                    _setPendingImage(items[i].getAsFile());
                    break;
                }
            }
        });
        document.getElementById('image-file-input').addEventListener('change', function(e) {
            if (e.target.files && e.target.files[0]) {
                const file = e.target.files[0];
                if (file.type && file.type.startsWith('audio/')) {
                    _transcribeAudioFile(file);
                } else if (file.name && /\.(mp3|m4a|wav|ogg|webm)$/i.test(file.name)) {
                    _transcribeAudioFile(file);
                } else {
                    _setPendingImage(file);
                }
                e.target.value = '';
            }
        });

        document.getElementById('audio-file-input').addEventListener('change', function(e) {
            if (e.target.files && e.target.files[0]) {
                _transcribeAudioFile(e.target.files[0]);
                e.target.value = '';
            }
        });

        (function _initMicRecorder() {
            var micBtn = document.getElementById('mic-record-btn');
            if (!micBtn) return;
            if (!window.MediaRecorder || !navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
                micBtn.addEventListener('click', function() {
                    var _statusEl = document.getElementById('audio-transcribe-status');
                    var msg = window.isSecureContext === false
                        ? '⚠️ Microphone requires HTTPS. Use the 📂 button to upload a saved audio file instead.'
                        : '⚠️ Microphone recording is not available in this browser. Use the 📂 button to upload a saved audio file instead.';
                    if (_statusEl) { _statusEl.textContent = msg; _statusEl.style.display = ''; }
                });
                return;
            }

            var _mediaRec   = null;
            var _chunks     = [];
            var _stream     = null;
            var _recTimer   = null;
            var _recStart   = null;
            var _wakeLock   = null;

            function _requestWakeLock() {
                if (navigator.wakeLock && typeof navigator.wakeLock.request === 'function') {
                    navigator.wakeLock.request('screen').then(function(lock) {
                        _wakeLock = lock;
                    }).catch(function(err) {
                        console.warn('Screen Wake Lock request failed:', err);
                    });
                }
            }

            function _releaseWakeLock() {
                if (_wakeLock) {
                    _wakeLock.release().then(function() {
                        _wakeLock = null;
                    }).catch(function(err) {
                        console.warn('Screen Wake Lock release failed:', err);
                    });
                }
            }

            document.addEventListener('visibilitychange', function() {
                if (_mediaRec && _mediaRec.state === 'recording' && document.visibilityState === 'visible') {
                    _requestWakeLock();
                }
            });

            function _fmtElapsed(ms) {
                var s = Math.floor(ms / 1000);
                var m = Math.floor(s / 60);
                s = s % 60;
                return m + ':' + (s < 10 ? '0' : '') + s;
            }

            micBtn.addEventListener('click', function() {
                if (_mediaRec && _mediaRec.state === 'recording') {
                    _mediaRec.stop();
                    _releaseWakeLock();
                    clearInterval(_recTimer);
                    _recTimer = null;
                    return;
                }
                navigator.mediaDevices.getUserMedia({ audio: true }).then(function(stream) {
                    _stream  = stream;
                    _chunks  = [];
                    var mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus') ? 'audio/webm;codecs=opus'
                                 : MediaRecorder.isTypeSupported('audio/ogg;codecs=opus')  ? 'audio/ogg;codecs=opus'
                                 : 'audio/webm';
                    _mediaRec = new MediaRecorder(stream, { mimeType: mimeType });

                    _mediaRec.ondataavailable = function(ev) {
                        if (ev.data && ev.data.size > 0) _chunks.push(ev.data);
                    };

                    _mediaRec.onstop = function() {
                        clearInterval(_recTimer);
                        _recTimer = null;
                        _releaseWakeLock();
                        stream.getTracks().forEach(function(t) { t.stop(); });
                        var blob = new Blob(_chunks, { type: _mediaRec.mimeType || 'audio/webm' });
                        var ext  = ((_mediaRec.mimeType || '').indexOf('ogg') !== -1) ? 'ogg' : 'webm';
                        var elapsed = _recStart ? _fmtElapsed(Date.now() - _recStart) : '';
                        var file = new File([blob], 'recording.' + ext, { type: blob.type });

                        var backupId = 'rec_' + Date.now() + '_' + Math.random().toString(36).substring(2, 7);
                        _saveAudioBackup(backupId, file, elapsed).then(function() {
                            _transcribeAudioFile(file, backupId);
                            _renderLocalAudioBackups();
                        }).catch(function(err) {
                            console.error('Failed to save audio backup:', err);
                            _transcribeAudioFile(file);
                        });

                        micBtn.textContent = '🎤';
                        micBtn.title = 'Record voice inspection — click to start, click again to stop. No time limit.';
                        micBtn.style.background = '';
                        var _statusEl = document.getElementById('audio-transcribe-status');
                        if (_statusEl) { _statusEl.textContent = '⏳ Recording stopped (' + elapsed + ') — uploading…'; }
                    };

                    _mediaRec.start(1000);
                    _requestWakeLock();
                    _recStart = Date.now();
                    micBtn.textContent = '⏹';
                    micBtn.title = 'Stop recording';
                    micBtn.style.background = '#ffd0d0';

                    var _statusEl = document.getElementById('audio-transcribe-status');
                    if (_statusEl) { _statusEl.textContent = '🔴 Recording 0:00 — click ⏹ to stop (no time limit)'; _statusEl.style.display = ''; }

                    _recTimer = setInterval(function() {
                        var el = document.getElementById('audio-transcribe-status');
                        if (el && _recStart) {
                            el.textContent = '🔴 Recording ' + _fmtElapsed(Date.now() - _recStart) + ' — click ⏹ to stop (no time limit)';
                        }
                    }, 1000);
                }).catch(function(err) {
                    var _statusEl = document.getElementById('audio-transcribe-status');
                    if (_statusEl) { _statusEl.textContent = '⚠️ Microphone access denied: ' + err.message; _statusEl.style.display = ''; }
                });
            });
        })();

        // ── Voice Conversation Mode ────────────────────────────────────────────
        // Full hands-free loop: user speaks → auto-sent to AI → AI response read aloud
        // → listening restarts.
        //
        // STT strategy (in priority order):
        //   1. Web Speech API  — Chrome/Edge/Safari (streaming, instant)
        //   2. VAD + Whisper   — Firefox and any browser without SpeechRecognition
        //                        Uses AudioContext to detect speech, records via
        //                        MediaRecorder, uploads to /ai/transcribe (our server).
        //                        No audio leaves to third-party servers. 1-3s delay.
        // TTS: speechSynthesis — all browsers.
        (function() {
            var _SpeechRec = window.SpeechRecognition || window.webkitSpeechRecognition;
            var _hasTTS    = !!(window.speechSynthesis);
            var _hasVAD    = !!(window.AudioContext || window.webkitAudioContext) && !!(window.MediaRecorder) && !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
            var _voiceBtn  = document.getElementById('voice-mode-btn');
            if (!_voiceBtn) return;

            if (_hasTTS || _SpeechRec || _hasVAD) { _voiceBtn.style.display = ''; }

            var _voiceActive = false;
            var _recog       = null;
            var _ttsSpeaking = false;
            var _voiceStatus = document.getElementById('audio-transcribe-status');

            var _vadStream   = null;
            var _vadCtx      = null;
            var _vadRec      = null;
            var _vadChunks   = [];
            var _vadSpeaking = false;
            var _vadSilTimer = null;
            var _vadRafId    = null;

            var VAD_SPEAK_THRESH  = 18;
            var VAD_SILENCE_MS    = 1400;
            var VAD_MIN_SPEECH_MS = 300;
            var _vadSpeakStart    = 0;

            function _setVoiceStatus(msg) {
                if (_voiceStatus) { _voiceStatus.textContent = msg; _voiceStatus.style.display = msg ? '' : 'none'; }
            }

            function _speak(text) {
                if (!_hasTTS || !_voiceActive) return;
                window.speechSynthesis.cancel();
                var clean = text
                    .replace(/\[ACTION:[^\]]*\]/gi, '')
                    .replace(/#{1,6}\s*/g, '')
                    .replace(/\*\*([^*]+)\*\*/g, '$1')
                    .replace(/\*([^*]+)\*/g, '$1')
                    .replace(/`[^`]+`/g, function(m){ return m.replace(/`/g,''); })
                    .replace(/https?:\/\/\S+/g, '')
                    .trim();
                if (!clean) { _startListening(); return; }
                _ttsSpeaking = true;
                _setVoiceStatus('🔈 Speaking…');
                var utter = new window.SpeechSynthesisUtterance(clean);
                utter.lang  = 'en-US';
                utter.rate  = 1.05;
                utter.pitch = 1.0;
                utter.onend  = function() { _ttsSpeaking = false; if (_voiceActive) { _setVoiceStatus(''); _startListening(); } };
                utter.onerror = function() { _ttsSpeaking = false; if (_voiceActive) { _setVoiceStatus(''); _startListening(); } };
                window.speechSynthesis.speak(utter);
            }

            state._speakResponse = _speak;

            function _stopVAD() {
                if (_vadRafId) { cancelAnimationFrame(_vadRafId); _vadRafId = null; }
                if (_vadSilTimer) { clearTimeout(_vadSilTimer); _vadSilTimer = null; }
                if (_vadRec && _vadRec.state !== 'inactive') { try { _vadRec.stop(); } catch(e){} }
                if (_vadStream) { _vadStream.getTracks().forEach(function(t){ t.stop(); }); _vadStream = null; }
                if (_vadCtx) { try { _vadCtx.close(); } catch(e){} _vadCtx = null; }
                _vadRec = null; _vadChunks = []; _vadSpeaking = false;
            }

            function _uploadVADBlob(blob) {
                if (!blob || blob.size < 1000) { _startListening(); return; }
                _setVoiceStatus('⏳ Transcribing speech…');
                var ext = (blob.type.indexOf('ogg') !== -1) ? 'ogg' : 'webm';
                var file = new File([blob], 'voice.' + ext, { type: blob.type });
                var fd = new FormData();
                fd.append('audio', file, file.name);
                fd.append('diarize', '0');
                fetch('/ai/transcribe', { method: 'POST', credentials: 'include', body: fd })
                .then(function(r){ return r.json(); })
                .then(function(data) {
                    if (!_voiceActive) return;
                    var txt = (data.transcript || '').trim();
                    if (!txt) { _setVoiceStatus('👂 Nothing heard — listening…'); _startListening(); return; }
                    var inputEl = document.getElementById('message-input');
                    if (inputEl) inputEl.value = txt;
                    _setVoiceStatus('📤 Sending: "' + txt.substring(0, 50) + (txt.length > 50 ? '…' : '') + '"');
                    sendMessage();
                })
                .catch(function() {
                    if (_voiceActive) { _setVoiceStatus('⚠️ Transcription failed — retrying…'); setTimeout(_startListening, 1500); }
                });
            }

            function _startVAD() {
                if (!_voiceActive) return;
                _setVoiceStatus('👂 Listening… (speak now)');
                navigator.mediaDevices.getUserMedia({ audio: true }).then(function(stream) {
                    if (!_voiceActive) { stream.getTracks().forEach(function(t){ t.stop(); }); return; }
                    _vadStream  = stream;
                    _vadChunks  = [];
                    _vadSpeaking = false;
                    var ACtx = window.AudioContext || window.webkitAudioContext;
                    _vadCtx = new ACtx();
                    var source   = _vadCtx.createMediaStreamSource(stream);
                    var analyser = _vadCtx.createAnalyser();
                    analyser.fftSize = 512;
                    source.connect(analyser);
                    var buf = new Uint8Array(analyser.fftSize);
                    var mimeType = MediaRecorder.isTypeSupported('audio/webm;codecs=opus') ? 'audio/webm;codecs=opus'
                                 : MediaRecorder.isTypeSupported('audio/ogg;codecs=opus')  ? 'audio/ogg;codecs=opus'
                                 : 'audio/webm';
                    _vadRec = new MediaRecorder(stream, { mimeType: mimeType });
                    _vadRec.ondataavailable = function(ev) { if (ev.data && ev.data.size > 0) _vadChunks.push(ev.data); };
                    _vadRec.onstop = function() {
                        var blob = new Blob(_vadChunks, { type: _vadRec.mimeType || 'audio/webm' });
                        _vadChunks = [];
                        _uploadVADBlob(blob);
                    };
                    function _tick() {
                        if (!_voiceActive) { _stopVAD(); return; }
                        analyser.getByteTimeDomainData(buf);
                        var rms = 0;
                        for (var i = 0; i < buf.length; i++) { var d = (buf[i] - 128); rms += d * d; }
                        rms = Math.sqrt(rms / buf.length);
                        if (rms > VAD_SPEAK_THRESH) {
                            if (!_vadSpeaking) {
                                _vadSpeaking = true;
                                _vadSpeakStart = Date.now();
                                _vadChunks = [];
                                _vadRec.start(100);
                                _setVoiceStatus('🔴 Recording…');
                            }
                            if (_vadSilTimer) { clearTimeout(_vadSilTimer); _vadSilTimer = null; }
                        } else if (_vadSpeaking) {
                            if (!_vadSilTimer) {
                                _vadSilTimer = setTimeout(function() {
                                    _vadSilTimer = null;
                                    if (!_vadSpeaking) return;
                                    _vadSpeaking = false;
                                    var dur = Date.now() - _vadSpeakStart;
                                    if (dur < VAD_MIN_SPEECH_MS) {
                                        _vadRec.stop();
                                        _vadChunks = [];
                                        _setVoiceStatus('👂 Listening… (speak now)');
                                        _vadRec = new MediaRecorder(stream, { mimeType: mimeType });
                                        _vadRec.ondataavailable = function(ev){ if (ev.data && ev.data.size > 0) _vadChunks.push(ev.data); };
                                        _vadRec.onstop = function(){ var blob = new Blob(_vadChunks, { type: _vadRec.mimeType || 'audio/webm' }); _vadChunks = []; _uploadVADBlob(blob); };
                                    } else {
                                        _vadRec.stop();
                                    }
                                }, VAD_SILENCE_MS);
                            }
                        }
                        _vadRafId = requestAnimationFrame(_tick);
                    }
                    _vadRafId = requestAnimationFrame(_tick);
                }).catch(function(err) {
                    _setVoiceStatus('⚠️ Microphone access denied: ' + err.message);
                });
            }

            function _startSpeechRec() {
                if (!_voiceActive) return;
                if (_recog) { try { _recog.abort(); } catch(e){} }
                _recog = new _SpeechRec();
                _recog.lang = 'en-US';
                _recog.continuous = false;
                _recog.interimResults = true;
                _recog.maxAlternatives = 1;
                var _inputEl = document.getElementById('message-input');
                _setVoiceStatus('👂 Listening… (speak now)');
                _recog.onresult = function(ev) {
                    var interim = '', fin = '';
                    for (var i = ev.resultIndex; i < ev.results.length; i++) {
                        var t = ev.results[i][0].transcript;
                        if (ev.results[i].isFinal) { fin += t; } else { interim += t; }
                    }
                    if (_inputEl) _inputEl.value = fin || interim;
                };
                _recog.onend = function() {
                    var txt = _inputEl ? (_inputEl.value || '').trim() : '';
                    if (txt && _voiceActive) {
                        _setVoiceStatus('📤 Sending: "' + txt.substring(0, 50) + (txt.length > 50 ? '…' : '') + '"');
                        sendMessage();
                    } else if (_voiceActive) {
                        _setVoiceStatus('👂 Listening… (nothing heard, trying again)');
                        setTimeout(_startSpeechRec, 800);
                    }
                };
                _recog.onerror = function(ev) {
                    if (ev.error === 'no-speech' && _voiceActive) { setTimeout(_startSpeechRec, 600); }
                    else if (ev.error !== 'aborted' && _voiceActive) {
                        _setVoiceStatus('⚠️ Voice recognition error: ' + ev.error);
                        setTimeout(_startSpeechRec, 2000);
                    }
                };
                try { _recog.start(); } catch(e) {}
            }

            function _startListening() {
                if (!_voiceActive) return;
                if (_SpeechRec) { _startSpeechRec(); } else { _startVAD(); }
            }

            function _stopVoiceMode() {
                _voiceActive = false;
                window.speechSynthesis.cancel();
                if (_recog) { try { _recog.abort(); } catch(e){} _recog = null; }
                _stopVAD();
                _voiceBtn.textContent = '🔊';
                _voiceBtn.style.background = '';
                _voiceBtn.title = 'Voice conversation mode — speak to AI, AI speaks back';
                _setVoiceStatus('');
            }

            _voiceBtn.addEventListener('click', function() {
                if (_voiceActive) { _stopVoiceMode(); return; }
                if (!_SpeechRec && !_hasVAD) {
                    if (!_hasTTS) { alert('Your browser does not support voice features. Please use Chrome, Edge, Safari, or Firefox.'); return; }
                }
                _voiceActive = true;
                _voiceBtn.textContent = '🔇';
                _voiceBtn.style.background = '#d0ffd0';
                _voiceBtn.title = 'Voice mode ON — click to stop';
                _startListening();
            });

            document.getElementById('close-chat').addEventListener('click', function() {
                if (_voiceActive) _stopVoiceMode();
            }, true);
        })();

        document.getElementById('ai-provider').addEventListener('change', function(e) {
            const selectedVal = e.target.value;
            const parts = selectedVal.split('|');
            const isGrok         = parts[0] === 'grok';
            const isServerSwitch = parts[0] === 'ollama_server';

            if (isServerSwitch) {
                // Switch Ollama host — call /ai/set_host then revert selector to 'ollama'
                const newHost = parts[1] || '';
                const sel = document.getElementById('ai-provider');
                const statusEl = document.getElementById('chat-status');
                if (statusEl) { statusEl.textContent = '⏳ Switching to ' + newHost + '…'; statusEl.className = 'chat-status processing'; }
                fetch('/ai/set_host', {
                    method: 'POST',
                    credentials: 'include',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ host: newHost })
                })
                .then(function(r) { return r.json(); })
                .then(function(result) {
                    if (result.success) {
                        state.ollamaHost = newHost;
                        if (statusEl) { statusEl.textContent = '✅ Ollama server: ' + newHost; statusEl.className = 'chat-status connected'; }
                        // Update active marker in optgroup
                        if (sel) {
                            Array.from(sel.options).forEach(function(o) {
                                if (o.value.startsWith('ollama_server|')) {
                                    o.textContent = o.textContent.replace(' ✓', '');
                                    if (o.value === 'ollama_server|' + newHost) o.textContent += ' ✓';
                                }
                            });
                            sel.value = 'ollama'; // revert to primary option
                        }
                    } else {
                        if (statusEl) { statusEl.textContent = '⚠️ Server switch failed'; statusEl.className = 'chat-status error'; }
                        if (sel) sel.value = 'ollama';
                    }
                })
                .catch(function() {
                    if (statusEl) { statusEl.textContent = '⚠️ Server switch failed'; statusEl.className = 'chat-status error'; }
                    if (sel) sel.value = 'ollama';
                });
                return; // don't update selectedProvider
            }

            state.selectedProvider = selectedVal;
            state.userModelOverride = true;   // user chose manually — disable auto-select
            let modelDisplay;
            if (isGrok) {
                modelDisplay = 'Grok (xAI)' + (parts[1] ? ': ' + parts[1] : '');
            } else {
                const host = state.ollamaHost || '';
                const isLocalHost = !host || host === 'localhost' || host === '127.0.0.1' || host === '0.0.0.0' || host === '::1';
                modelDisplay = (isLocalHost ? 'Ollama (Local)' : 'Ollama (Remote)') + (parts[1] ? ': ' + parts[1] : '');
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
        const _si = document.getElementById('chat-status');
        const statusIndicator = _si || { textContent: '' };
        
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
                
                // Add conversation messages (with thinking traces for admin users)
                data.messages.forEach(msg => {
                    const className = msg.role === 'user' ? 'user-message' : 'ai-message';
                    // Render thinking trace BEFORE the message content (for AI messages with traces)
                    if (msg.role === 'assistant' && msg.thinking_trace && msg.thinking_trace.length > 0 && state.isAdmin) {
                        var isErrTrace = msg.thinking_trace.some(function(s) { return s && s.indexOf('FAILED') !== -1; });
                        var traceEl = document.createElement('details');
                        traceEl.className = 'ai-thinking' + (isErrTrace ? '' : '');
                        traceEl.open = false;
                        var traceSummary = document.createElement('summary');
                        traceSummary.textContent = (isErrTrace ? '⚠️ AI Thinking — Error Trace' : '🔍 AI Thinking')
                            + ' (' + msg.thinking_trace.length + ' steps)';
                        var traceBody = document.createElement('div');
                        traceBody.className = 'ai-thinking-body';
                        msg.thinking_trace.forEach(function(step) {
                            var stepEl = document.createElement('div');
                            stepEl.className = 'ai-thinking-step';
                            stepEl.textContent = step;
                            traceBody.appendChild(stepEl);
                        });
                        traceEl.appendChild(traceSummary);
                        traceEl.appendChild(traceBody);
                        chatMessages.appendChild(traceEl);
                    }
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
        return fetch('/ai2/providers', {
            method: 'GET',
            credentials: 'include'
        })
        .then(response => response.json())
        .then(data => {
            if (!data.success) return;

            if (data.username)              state.username   = data.username;
            if (data.is_admin !== undefined) state.isAdmin   = !!data.is_admin;
            if (data.is_guest !== undefined) state.isGuest   = !!data.is_guest;
            if (data.is_dev   !== undefined) state.isDevMode = !!data.is_dev;

            // Hide provider selector and history button for guests / non-admins
            if (data.is_guest || !data.can_access_history) {
                const selectorBar = document.querySelector('.provider-selector');
                if (selectorBar) selectorBar.style.display = 'none';
                const histBtn = document.getElementById('toggle-history-btn');
                if (histBtn) histBtn.style.display = 'none';
                const convLink = document.getElementById('conversations-link');
                if (convLink) convLink.style.display = 'none';
                // Clear any stale conversation ID left from a previous login session
                state.currentConversationId = null;
                sessionStorage.removeItem('currentConversationId');
                // For guests: still populate modelTiers from available Ollama models
                // so query auto-tier selection works correctly.
                if (data.providers) {
                    data.providers.forEach(function(p) {
                        if (p.service === 'ollama' && p.models && p.models.length > 0) {
                            const chatModels = p.models.filter(function(m) { return isChatModel(m.id); });
                            if (chatModels.length > 0) {
                                const sorted = chatModels.slice().sort(function(a, b) {
                                    return modelSizeScore(a.id) - modelSizeScore(b.id);
                                });
                                const usable = sorted.filter(function(m) { return modelSizeScore(m.id) >= 3; });
                                const pool   = usable.length > 0 ? usable : sorted;
                                state.modelTiers.small  = 'ollama|' + pool[0].id;
                                state.modelTiers.large  = 'ollama|' + pool[pool.length - 1].id;
                                state.modelTiers.medium = 'ollama|' + pool[Math.floor(pool.length / 2)].id;
                            }
                        }
                    });
                }
                return;
            }

            if (!data.providers || !data.providers.length) return;

            const providerSelect = document.getElementById('ai-provider');
            if (!providerSelect) return;
            providerSelect.innerHTML = '';

            data.providers.forEach(function(p) {
                if (p.service === 'ollama') {
                    state.ollamaHost = p.active_host;
                    const grp = document.createElement('optgroup');
                    const host = p.active_host || '';
                    const isLocalHost = !host || host === 'localhost' || host === '127.0.0.1' || host === '0.0.0.0' || host === '::1';
                    grp.label = isLocalHost ? 'Ollama (Local)' : 'Ollama (Remote: ' + host + ')';
                    if (p.models && p.models.length > 0) {
                        // Build model tiers from chat-capable models only, sorted by size.
                        // Exclude sub-2B toy models from auto-selection.
                        const chatModels = p.models.filter(function(m) { return isChatModel(m.id); });
                        if (chatModels.length > 0) {
                            const sorted = chatModels.slice().sort(function(a, b) {
                                return modelSizeScore(a.id) - modelSizeScore(b.id);
                            });
                            const usable = sorted.filter(function(m) { return modelSizeScore(m.id) >= 3; });
                            const pool   = usable.length > 0 ? usable : sorted;
                            state.modelTiers.small  = 'ollama|' + pool[0].id;
                            state.modelTiers.large  = 'ollama|' + pool[pool.length - 1].id;
                            state.modelTiers.medium = 'ollama|' + pool[Math.floor(pool.length / 2)].id;
                        }
                        // Only show usable (≥3B) models in dropdown; hide toy models
                        const displayModels = chatModels.filter(function(m) { return modelSizeScore(m.id) >= 3; });
                        const listModels = displayModels.length > 0 ? displayModels : chatModels;
                        listModels.forEach(function(m) {
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
                            { val: 'grok|grok-4.3',               label: 'Grok 4.3' },
                            { val: 'grok|grok-4.20-non-reasoning', label: 'Grok 4.20 Fast' }
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

            // Auto-correct stale selection: if previously selected model was removed,
            // reset to the first available option so the user doesn't silently use a
            // model that no longer exists on the server.
            if (state.selectedProvider && state.selectedProvider !== 'ollama') {
                const allOpts = Array.from(providerSelect.options);
                const stillExists = allOpts.some(function(o) {
                    return o.value === state.selectedProvider;
                });
                if (!stillExists && allOpts.length > 0) {
                    state.selectedProvider = allOpts[0].value;
                    providerSelect.value   = allOpts[0].value;
                    state.userModelOverride = false;
                    console.warn('Previously selected model no longer available; reset to', allOpts[0].value);
                }
            }

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
    
    // Open chat in a separate browser popup window — the user can drag it anywhere on
    // the screen or to a second monitor.  Uses /ai/widget (no site nav/header/footer).
    // Falls back to the inline panel if the browser blocks popups.
    function detachToPopup() {
        // If a popup is already open, bring it to front and return
        if (state._popupWindow && !state._popupWindow.closed) {
            state._popupWindow.focus();
            return;
        }

        const convId = state.currentConversationId;
        const params = [];
        if (convId) params.push('resume=' + encodeURIComponent(convId));
        params.push('from_path='  + encodeURIComponent(window.location.pathname));
        params.push('from_title=' + encodeURIComponent(document.title || ''));
        const url = '/ai/widget' + (params.length ? '?' + params.join('&') : '');

        // Position popup at bottom-right of the current screen, near where the widget sits
        const popW = 430, popH = 700;
        const screenRight  = window.screenX + window.outerWidth;
        const screenBottom = window.screenY + window.outerHeight;
        const popLeft = Math.max(window.screenX, screenRight  - popW - 24);
        const popTop  = Math.max(window.screenY, screenBottom - popH - 60);

        const popup = window.open(url, 'ai-chat-popup',
            'width=' + popW + ',height=' + popH + ',left=' + popLeft + ',top=' + popTop +
            ',resizable=yes,menubar=no,toolbar=no,location=no,status=no');

        if (popup) {
            state._popupWindow = popup;
            try {
                localStorage.setItem('ai_popup_active', '1');
                sessionStorage.setItem('ai_chat_open', 'popup');
            } catch(e) {}
            // Close the inline chat panel so it doesn't stay open on the parent window
            closeChat();
            // Mark the chat button as "popup active" so the user knows where the chat is
            const chatButton = document.getElementById('chat-button');
            if (chatButton) {
                chatButton.classList.add('popup-active');
                chatButton.title = 'AI chat is open in a separate window — click to bring to front';
            }
            const _pollPopup = setInterval(function() {
                if (popup.closed) {
                    clearInterval(_pollPopup);
                    state._popupWindow = null;
                    if (chatButton) {
                        chatButton.classList.remove('popup-active');
                        chatButton.title = 'Open AI assistant';
                    }
                    // Resume the conversation the user had in the popup
                    try {
                        const popupConvId = localStorage.getItem('ai_popup_conv_id');
                        if (popupConvId) {
                            state.currentConversationId = parseInt(popupConvId, 10);
                            sessionStorage.setItem('currentConversationId', popupConvId);
                            localStorage.removeItem('ai_popup_conv_id');
                            persistConversationId();
                        }
                    } catch(e) {}
                }
            }, 1000);
        } else {
            // Popup blocked — fall back to inline panel
            const _siD = document.getElementById('chat-status');
            if (_siD) _siD.textContent = 'Popups blocked — enable popups for this site to allow the moveable chat window.';
            openChat();
        }
    }

    // Update the page label in the widget header to show what page is being assisted.
    // Shows: [Site] · Page Title · agent badge  — all in one readable line.
    function updatePageLabel() {
        const labelEl = document.getElementById('chat-page-label');
        if (!labelEl) return;

        const ctx = state.pageContext;
        let pagePath = (ctx && ctx.page_path) || window.location.pathname;
        if (window.AI_WIDGET_POPUP) {
            pagePath = window.AI_DETACHED_FROM_PATH || pagePath;
        }

        // Human-readable page title: prefer document.title, fall back to last path segment
        let pageTitle = '';
        try {
            pageTitle = (window.AI_WIDGET_POPUP ? (window.AI_DETACHED_FROM_TITLE || '') : document.title) || '';
            pageTitle = pageTitle.replace(/\s*[|\-–—]\s*.*$/, '').trim(); // strip site suffix
        } catch(e) {}
        if (!pageTitle) {
            pageTitle = pagePath.split('/').filter(Boolean).pop() || '/';
        }
        // Truncate long titles
        if (pageTitle.length > 32) pageTitle = pageTitle.slice(0, 30) + '…';

        // Site name badge
        const site = state.siteName || '';

        // Active agent label
        const agentLabel = (state.currentAgent && (state.currentAgent.display_name || state.currentAgent.id)) || '';

        // Build label HTML
        let html = '';
        if (site) html += '<span class="chat-ctx-badge chat-ctx-site" title="Site">' + _escH(site) + '</span> ';
        html += '<span class="chat-ctx-page" title="' + _escH('Page: ' + pagePath) + '">' + _escH(pageTitle) + '</span>';
        if (agentLabel) html += ' <span class="chat-ctx-badge chat-ctx-agent" title="Agent">' + _escH(agentLabel) + '</span>';

        labelEl.innerHTML = html;
    }

    function _escH(s) {
        return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
    }

    // ── Form Fill Button ─────────────────────────────────────────────────────
    // When the page has fillable form fields, adds a "🪄 Fill Form" button
    // next to the Send button. User types description in the normal message
    // input, then clicks Fill Form — AI fills the form fields directly.
    function injectFormFillStrip() {
        if (document.getElementById('lc-ff-btn')) return;
        if (typeof window._getPageFormFields !== 'function') return;
        const fields = window._getPageFormFields();
        if (!fields || fields.length === 0) return;

        const sendBtn = document.getElementById('send-message');
        if (!sendBtn) return;

        // Build field description for the AI system prompt
        const fieldDesc = fields.map(function(f) {
            if (f.type === 'radio' && f.options) return f.name + ' (one of: ' + f.options.join(', ') + ')';
            if (f.tagName === 'select') return f.name + ' (' + (f.label || 'select') + ')';
            return f.name + (f.label && f.label !== f.name ? ' (' + f.label + ')' : '');
        }).join(', ');

        const ffBtn = document.createElement('button');
        ffBtn.id = 'lc-ff-btn';
        ffBtn.textContent = '🪄 Fill Form';
        ffBtn.title = 'Describe what to fill in the message box, then click here to fill the form with AI';
        ffBtn.style.cssText = 'padding:4px 8px;background:#f0c000;color:#333;border:none;border-radius:4px;' +
            'cursor:pointer;font-size:.8em;font-weight:bold;white-space:nowrap;flex-shrink:0;';

        // Insert after Send button
        sendBtn.parentNode.insertBefore(ffBtn, sendBtn.nextSibling);

        ffBtn.addEventListener('click', function() {
            const msgInput = document.getElementById('message-input');
            const desc = (msgInput ? msgInput.value : '').trim();
            if (!desc) {
                alert('Type a description of what to fill in the message box first, then click Fill Form.');
                if (msgInput) msgInput.focus();
                return;
            }
            ffBtn.disabled = true; ffBtn.textContent = '⏳';

            // Detect if form has contact/company fields — if so, enable web search
            // so the AI can look up real-world information (address, phone, email, etc.)
            var contactFieldRE = /phone|email|address|contact|url|website|city|postal|zip/i;
            var hasContactFields = fields.some(function(f) {
                return contactFieldRE.test(f.name) || contactFieldRE.test(f.label || '');
            });
            var useSearch = hasContactFields ? 1 : 0;

            const SYSTEM = 'You fill in a web form. The page is "' + document.title + '". ' +
                (useSearch ? 'If web search results are provided above, use them to find accurate real-world information (address, phone, email, etc.) for the entity described. ' : '') +
                'Return ONLY a raw JSON object. Keys must exactly match the HTML field name attributes: ' + fieldDesc + '. ' +
                'Values must be plain strings or numbers. No markdown, no code fences, no explanation — only the JSON object.';

            const selProvider = document.getElementById('ai-provider');
            const provider = (selProvider && selProvider.value) || 'ollama';

            fetch('/ai/generate', {
                method: 'POST', credentials: 'include',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ prompt: desc, system: SYSTEM, provider: provider, skip_role_prompt: true, use_search: useSearch })
            })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                ffBtn.disabled = false; ffBtn.textContent = '🪄 Fill Form';
                if (!data.success) { alert('AI error: ' + (data.error || 'unknown')); return; }
                const raw = (data.response || '').trim();
                const js = raw.indexOf('{'), je = raw.lastIndexOf('}');
                if (js === -1) { alert('AI returned no JSON. Try rephrasing your description.'); return; }
                let parsed;
                try { parsed = JSON.parse(raw.substring(js, je + 1)); }
                catch(e) { alert('JSON parse error: ' + e.message + '\n\nAI said:\n' + raw.substring(0, 300)); return; }
                let filled = 0;
                Object.keys(parsed).forEach(function(k) {
                    if (window._applyFieldValue && window._applyFieldValue(k, parsed[k])) filled++;
                });
                // Show brief success in status bar
                const si = document.getElementById('chat-status');
                if (si) { si.textContent = '✅ Filled ' + filled + ' form field(s) — review and save.'; }
                // Clear message input
                if (msgInput) msgInput.value = '';
            })
            .catch(function(e) { ffBtn.disabled = false; ffBtn.textContent = '🪄 Fill Form'; alert('Request failed: ' + e); });
        });
    }

    // Prefer detached popup on desktop (same as code editor); inline dock on mobile or when popups blocked.
    function openChatPreferred() {
        if (window.AI_WIDGET_POPUP) {
            openChat();
            return;
        }
        var _mobile = /Mobi|Android|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)
            || (window.matchMedia && window.matchMedia('(pointer: coarse)').matches && window.innerWidth < 1024);
        if (_mobile) {
            openChat();
        } else {
            detachToPopup();
        }
    }

    // Open chat panel (inline dock on the current page)
    function openChat() {
        const chatPanel = document.getElementById('chat-panel');
        const chatButton = document.getElementById('chat-button');
        
        if (chatPanel) chatPanel.style.display = 'flex';
        if (chatButton) chatButton.style.display = 'none';
        state.isOpen = true;
        
        try {
            sessionStorage.setItem('ai_chat_open', 'inline');
        } catch(e) {}

        // Update chat header with selected agent info and current page
        const chatHeader = document.querySelector('.chat-header h3');
        if (state.pageContext && state.pageContext.agent_name) {
            chatHeader.textContent = state.pageContext.agent_name;
        } else if (state.currentAgent && state.currentAgent.display_name) {
            chatHeader.textContent = state.currentAgent.display_name;
        }
        updatePageLabel();

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

        // Inject form-fill strip if the page has fillable form fields
        injectFormFillStrip();
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
        const _si2 = document.getElementById('chat-status');
        if (_si2) {
            _si2.textContent = 'AI Ready - New Conversation';
            _si2.className = 'chat-status connected';
        }
        
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
        
        if (chatPanel) chatPanel.style.display = 'none';
        if (chatButton) chatButton.style.display = 'flex';
        state.isOpen = false;
        
        try {
            sessionStorage.removeItem('ai_chat_open');
        } catch(e) {}
    }
    
    // Function to query AI and get response
    function queryAI(prompt, imageData) {
        try {
            sessionStorage.setItem('ai_pending_query', JSON.stringify({
                prompt: prompt,
                imageData: imageData || null,
                timestamp: Date.now()
            }));
        } catch(e) {}

        const _siQ = document.getElementById('chat-status');
        const statusIndicator = _siQ || { textContent: '', className: '' };
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
                var effectivePrompt = prompt;

                if (state.pageContext && state.pageContext.agent_id === 'coding') {
                    var pageErrors = _collectPageErrors();
                    if (pageErrors && !prompt.toLowerCase().includes('[page error')) {
                        effectivePrompt = pageErrors + '\n\n' + prompt;
                    }
                }

                if (state.pageContext && state.pageContext.agent_id === 'template_editor'
                        && !prompt.includes('[FILE:')) {
                    var tplPath = _getTemplatePathForPage(window.location.pathname);
                    if (tplPath) {
                        fetch('/ai/read_file?path=' + encodeURIComponent(tplPath) + '&limit=500',
                              { credentials: 'include' })
                            .then(function(r) { return r.json(); })
                            .then(function(data) {
                                if (data.success) {
                                    var fileBlock = '[FILE: ' + data.path + ']\n```\n'
                                                  + data.content + '\n```\n[/FILE]\n\n';
                                    sendAIRequest(fileBlock + effectivePrompt,
                                                  statusIndicator, loadingMessage, imageData);
                                } else {
                                    sendAIRequest(effectivePrompt, statusIndicator, loadingMessage, imageData);
                                }
                            })
                            .catch(function() {
                                sendAIRequest(effectivePrompt, statusIndicator, loadingMessage, imageData);
                            });
                        return;
                    }
                }

                sendAIRequest(effectivePrompt, statusIndicator, loadingMessage, imageData);
            });
        }).catch(function(error) {
            console.error('Failed to load agents config:', error);
            if (!state.pageContext) {
                state.pageContext = detectPageContext();
            }
            sendAIRequest(prompt, statusIndicator, loadingMessage, imageData);
        });
    }
    
    // Helper function to send AI request after context is ready
    function sendAIRequest(prompt, statusIndicator, loadingMessage, imageData) {
        const _agentId = (state.pageContext && state.pageContext.agent_id) || '';
        let _agentSys = (state.pageContext && state.pageContext.system_prompt) || '';

        // Classify query complexity to decide PROVIDER (ollama vs grok).
        // For Ollama, we do NOT override the model — the server's _select_model_for_context
        // already picks the best installed model per agent context.
        // We only specify a model when the user manually chose one, or for Grok (where model matters).
        let effectiveProvider = state.selectedProvider || 'ollama';
        let autoTier = null;
        if (!state.userModelOverride) {
            autoTier = classifyQuery(prompt);
            effectiveProvider = autoSelectProvider(autoTier);
            // Accounting agent always uses local Ollama — financial data stays on-device.
            // Override only when the user has NOT manually selected a provider.
            if (_agentId === 'accounting' && effectiveProvider && effectiveProvider.startsWith('grok')) {
                effectiveProvider = state.modelTiers.large || state.modelTiers.medium || state.modelTiers.small || 'ollama';
            }
            // Reflect auto-selection in the dropdown UI
            const sel = document.getElementById('ai-provider');
            if (sel && sel.querySelector('option[value="' + effectiveProvider + '"]')) {
                sel.value = effectiveProvider;
            }
        }

        // Parse provider|model format (e.g. "grok|grok-mini" or "ollama|llama3.1:latest")
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

        // ENCY agent: inject navigate_and_fill instruction when user asks to add a constituent or fix unresolved term.
        if (state.pageContext.agent_id === 'ency') {
            const _pu3 = prompt.toUpperCase();
            const _encyCTIntent = /ADD.*CONSTITUENT|FIX.*CONSTITUENT|ADD.*TERM|FIX.*TERM|UNRESOLVED.*TERM|RESOLVE.*TERM|CREATE.*CONSTITUENT|ADD.*GLOSSARY|FIX.*GLOSSARY/.test(_pu3)
                || /\bCONSTITUENT\b.*\bADD\b|\bTERM\b.*\bADD\b|\bFIX\b.*\bENCY\b/.test(_pu3);
            if (_encyCTIntent) {
                state.pageContext.system_prompt = (state.pageContext.system_prompt || '') + '\n\n## CRITICAL ENCY ACTION RULE\nThe user wants to add a missing constituent or fix an unresolved term. READ the injected todo/DB data carefully to find the term name, then emit this action on its own line:\n[ACTION: {"action": "navigate_and_fill", "url": "/ENCY/Constituent/add", "fields": {"name": "TERM_NAME_FROM_TODO_DATA", "found_in_herbs": "HERB_IF_KNOWN"}}]\nDo NOT ask the user what the term name is — it is in the injected data. After the ACTION line, confirm the term you are adding.';
            }
        }

        // When accounting agent is active AND the prompt looks like a pasted bill,
        // inject the navigate_and_fill instruction so Grok emits the ACTION block.
        const _looksLikeBill = /\$\s*[\d,]+\.\d{2}|[\d]+\.?\d*\s*(?:USD|CAD|EUR|GBP)/i.test(prompt)
            && /Payment|Invoice|Receipt|Bill|invoice\s+number|invoice\s+date/i.test(prompt);
        const _looksLikeDeposit = /\$\s*[\d,]+\.\d{2}/.test(prompt)
            && /Amount\s+Deposited|Account\s+(?:Balance|Refill)|Refill\s+Convenience|Reference\s+No|account\s+refill|funds.*account|adding.*funds/i.test(prompt);
        const _explicitFormRequest = /open.*invoice.*form|file.*form|open.*form|open.*supplier|file.*invoice/i.test(prompt);
        if (_agentId === 'accounting' && (_looksLikeBill || _looksLikeDeposit || _explicitFormRequest)) {
            const _depositNote = _looksLikeDeposit && !_looksLikeBill
                ? '\n\nNOTE: This appears to be a DEPOSIT/REFILL confirmation email (money paid TO a supplier account, e.g. PayPal reseller credit). Treat the "Amount Deposited" as unit_cost_0 (the main payment), and any "Convenience Charge" as a separate second line item (description_0 and unit_cost_1). Use "Prepaid Hosting / Account Refill" as description_0 if no clearer description is shown.'
                : '';
            _agentSys = (_agentSys || '') + '\n\n## CRITICAL INVOICE ACTION RULE\nThe user has pasted a bill, payment receipt, or deposit confirmation email. You MUST respond by emitting this action on its own line — do NOT give manual step-by-step instructions:\n[ACTION: {"action": "navigate_and_fill", "url": "/Inventory/invoice/new", "fields": {"invoice_number": "REFERENCE_OR_INV_NO", "invoice_date": "YYYY-MM-DD", "notes": "SUPPLIER payment/deposit REFERENCE DATE", "unit_cost_0": "MAIN_AMOUNT", "quantity_0": "1", "description_0": "SERVICE DESCRIPTION"}}]\nReplace all placeholders with values parsed from the pasted text. Only add auto_pay_method if it explicitly says "Auto Pay". If a convenience/service fee is shown as a separate amount, add a second line (unit_cost_1, description_1, quantity_1). After the ACTION line, tell the user: (a) which supplier name to select in the dropdown, and (b) if that supplier does not exist yet, open /Inventory/supplier/add first.' + _depositNote;
        }

        // ENCY agent: inject navigate_and_fill instruction when user asks to add a constituent or fix unresolved term.
        if (_agentId === 'ency') {
            const _pu3 = prompt.toUpperCase();
            const _encyCTIntent = /ADD.*CONSTITUENT|FIX.*CONSTITUENT|ADD.*TERM|FIX.*TERM|UNRESOLVED.*TERM|RESOLVE.*TERM|CREATE.*CONSTITUENT|ADD.*GLOSSARY|FIX.*GLOSSARY/.test(_pu3)
                || /\bCONSTITUENT\b.*\bADD\b|\bTERM\b.*\bADD\b|\bFIX\b.*\bENCY\b/.test(_pu3);
            if (_encyCTIntent) {
                _agentSys = (_agentSys || '') + '\n\n## CRITICAL ENCY ACTION RULE\nThe user wants to add a missing constituent or fix an unresolved term. READ the injected todo/DB data carefully to find the term name, then emit this action on its own line:\n[ACTION: {"action": "navigate_and_fill", "url": "/ENCY/Constituent/add", "fields": {"name": "TERM_NAME_FROM_TODO_DATA", "found_in_herbs": "HERB_IF_KNOWN"}}]\nDo NOT ask the user what the term name is — it is in the injected data. After the ACTION line, confirm the term you are adding.';
            }
        }
        // Client-side fast path: open the correct accounting form without an AI round-trip.
        // _looksLikeDeposit → always fires (any agent) — opens /Accounting/transfer/new
        // _looksLikeBill / _enterIntent → only fires for accounting agent — opens /Inventory/invoice/new
        const _isDepositFastPath = _looksLikeDeposit;
        if (_isDepositFastPath || _agentId === 'accounting') {
            const _pu2 = prompt.toUpperCase();
            const _enterIntent = _agentId === 'accounting'
                && (/ENTER.*INVOICE|ENTER.*BILL|ADD.*INVOICE|RECORD.*INVOICE|CREATE.*INVOICE|PUT.*ACCOUNT|ENTER.*IT\b|ADD.*IT\b|RECORD.*IT\b|OPEN.*INVOICE.*FORM|FILE.*FORM|OPEN.*FORM|FILE.*INVOICE/.test(_pu2)
                    || /^(ENTER|ADD|RECORD|POST|CREATE|OPEN|FILE)\s+(THE\s+)?(INVOICE|BILL|PAYMENT|IT|FORM)\b/.test(_pu2));
            if (_enterIntent || _looksLikeBill || _looksLikeDeposit) {
                const _chatMsgs = document.getElementById('chat-messages');
                let _billText = prompt;
                if (_chatMsgs) {
                    _chatMsgs.querySelectorAll('.message').forEach(function(el) {
                        _billText += ' ' + (el.textContent || '');
                    });
                }
                const _nfFields = {};
                // Deposit email: use "Amount Deposited" as main amount
                const _depositAmtM = _billText.match(/Amount\s+Deposited[:\s]+\$?\s*([\d,]+\.?\d{0,2})/i);
                const _feeAmtM = _billText.match(/(?:Refill\s+Convenience\s+Charge|Convenience\s+(?:Fee|Charge)|Service\s+(?:Fee|Charge))[:\s]+\$?\s*([\d,]+\.?\d{0,2})/i);
                if (_depositAmtM) {
                    _nfFields.unit_cost_0 = _depositAmtM[1].replace(/,/g, '');
                    _nfFields.description_0 = 'Prepaid account refill';
                    _nfFields.quantity_0 = '1';
                    if (_feeAmtM) {
                        _nfFields.unit_cost_1 = _feeAmtM[1].replace(/,/g, '');
                        _nfFields.description_1 = 'Refill convenience charge';
                        _nfFields.quantity_1 = '1';
                    }
                } else {
                    const _amtM = _billText.match(/\$\s*([\d,]+\.?\d{0,2})/) || _billText.match(/([\d]+\.?\d{0,2})\s*(?:USD|CAD|EUR)/i);
                    if (_amtM) _nfFields.unit_cost_0 = _amtM[1].replace(/,/g, '');
                    _nfFields.description_0 = 'Service charge';
                    _nfFields.quantity_0 = '1';
                }
                const _dateM = _billText.match(/(\d{4})-(\d{2})-(\d{2})/)
                    || _billText.match(/(\w+)\s+(\d{1,2})\s+(\d{4})\s+\d+:\d+/i)
                    || _billText.match(/(\d{2})\/(\d{2})\/(\d{4})/);
                if (_dateM) {
                    if (_dateM[0].includes('-')) {
                        _nfFields.invoice_date = _dateM[0];
                    } else if (/^\d{2}\//.test(_dateM[0])) {
                        _nfFields.invoice_date = _dateM[3] + '-' + _dateM[1] + '-' + _dateM[2];
                    } else {
                        const _months = {Jan:'01',Feb:'02',Mar:'03',Apr:'04',May:'05',Jun:'06',Jul:'07',Aug:'08',Sep:'09',Oct:'10',Nov:'11',Dec:'12'};
                        const _mo = _months[_dateM[1]] || '01';
                        _nfFields.invoice_date = _dateM[3] + '-' + _mo + '-' + (_dateM[2].length === 1 ? '0' : '') + _dateM[2];
                    }
                }
                const _invNumM = _billText.match(/Reference\s+No[:\s]+([A-Z0-9\-]+)/i)
                    || _billText.match(/Invoice\s+[Nn]umber[:\s]+([A-Z0-9\-]+)/i)
                    || _billText.match(/Payment\s+Number[:\s]+([A-Z0-9]+)/i);
                if (_invNumM) _nfFields.invoice_number = _invNumM[1];
                if (/Auto\s*Pay/i.test(_billText)) {
                    const _methodM = _billText.match(/Payment\s+Method[:\s]+(\w+)/i);
                    _nfFields.auto_pay = '1';
                    _nfFields.auto_pay_method = (_methodM ? _methodM[1] : 'Visa') + ' Auto Pay';
                }
                const _supplierM = _billText.match(/HostGator|PayPal|Freedom Mobile|Rogers|Bell|Telus|Shaw|Koodo|Fido|Videotron|SaskTel|MTS|Eastlink|OpenAI|Anthropic|Google|Microsoft|AWS|Azure|Cloudflare|GitHub|Stripe|Mailgun|Twilio|eNom|GoDaddy|Namecheap|Hover|Tucows|WHC|Domain\.com/i);
                const _supplierName = _supplierM ? _supplierM[0] : 'Supplier';
                const _billedToM = _billText.match(/Billed\s+To[:\s]+([^\n\r]+)/i);
                const _billedTo = _billedToM ? ' (' + _billedToM[1].trim() + ')' : '';
                if (!_nfFields.notes) {
                    _nfFields.notes = _supplierName
                        + (_depositAmtM ? ' account refill' : ' invoice')
                        + _billedTo
                        + (_nfFields.invoice_number ? ' #' + _nfFields.invoice_number : '')
                        + (_nfFields.invoice_date ? ' ' + _nfFields.invoice_date : '');
                }
                if (_nfFields.unit_cost_0) {
                    const _isDeposit = !!_depositAmtM;
                    if (_isDeposit) {
                        const _tf = {
                            amount:     _nfFields.unit_cost_0,
                            post_date:  _nfFields.invoice_date || '',
                            reference:  _nfFields.invoice_number || '',
                            notes:      _nfFields.notes || '',
                            fee_amount: _nfFields.unit_cost_1 || '',
                            entry_type: 'prepaid_topup',
                        };
                        const _qs = Object.keys(_tf).filter(k => _tf[k]).map(k => encodeURIComponent(k) + '=' + encodeURIComponent(_tf[k])).join('&');
                        executeAIAction({ action: 'navigate_and_fill', url: '/Accounting/transfer/new?' + _qs, fields: _tf });
                    } else {
                        executeAIAction({ action: 'navigate_and_fill', url: '/Inventory/invoice/new', fields: _nfFields });
                    }
                    const _wAcc = document.createElement('div');
                    _wAcc.className = 'msg-wrapper msg-wrapper-ai';
                    const _lblAcc = document.createElement('div');
                    _lblAcc.className = 'msg-label';
                    _lblAcc.textContent = 'Accounting Agent';
                    const _elAcc = document.createElement('div');
                    _elAcc.className = 'message ai-message';
                    const _supplierHint = _isDeposit
                        ? ' Select <strong>prepaid_topup</strong> transaction type and choose the correct From/To accounts.'
                        : (_supplierName !== 'Supplier'
                            ? ' Select <strong>' + _supplierName + '</strong> as the supplier'
                                + ' (add at <a href="/Inventory/supplier/add?popup=1" target="_blank">/Inventory/supplier/add</a> if missing).'
                            : ' Select the supplier in the dropdown (add if missing).');
                    _elAcc.innerHTML = '\uD83D\uDCCB '
                        + (_isDeposit ? 'Deposit/refill transfer' : 'Invoice')
                        + ' form opened and pre-filled — verify the amounts, then save.'
                        + _supplierHint
                        + '<br><small>'
                        + (_isDeposit ? 'Deposit: $' : 'Amount: $') + _nfFields.unit_cost_0
                        + (_nfFields.unit_cost_1 ? ' + fee: $' + _nfFields.unit_cost_1 : '')
                        + (_nfFields.invoice_date ? ' | Date: ' + _nfFields.invoice_date : '')
                        + (_nfFields.invoice_number ? ' | Ref: ' + _nfFields.invoice_number : '')
                        + '</small>';
                    _wAcc.appendChild(_lblAcc);
                    _wAcc.appendChild(_elAcc);
                    if (_chatMsgs) { _chatMsgs.appendChild(_wAcc); _chatMsgs.scrollTop = _chatMsgs.scrollHeight; }
                    if (_enterIntent || _looksLikeDeposit) {
                        loadingMessage.remove();
                        statusIndicator.textContent = _isDeposit ? '\uD83D\uDFE2 Transfer form opened' : '\uD83D\uDFE2 Invoice form opened';
                        statusIndicator.className = 'chat-status connected';
                        return;
                    }
                }
            }
        }

        // ENCY section navigation fast path — no AI round-trip needed for common section requests
        if (_agentId === 'ency' || (state.pageContext.page_path || '').startsWith('/ENCY')) {
            const _pu5 = prompt.toUpperCase().replace(/['']/g, '');
            if (/\b(OPEN|SHOW|LIST|BROWSE|GO TO|TAKE ME TO|DISPLAY|VIEW)\b/.test(_pu5)) {
                var _encyNavUrl = null;
                var _encyNavLabel = null;
                if (/\b(HERB|HERBS|PLANT|PLANTS|BOTANICAL)\b/.test(_pu5) && !/DETAIL|EDIT|ADD|CREATE/.test(_pu5)) {
                    _encyNavUrl = '/ENCY/herbs'; _encyNavLabel = 'Herbs List';
                } else if (/\bCONSTIT/.test(_pu5) && !/DETAIL|EDIT|ADD|CREATE/.test(_pu5)) {
                    _encyNavUrl = '/ENCY/Constituent'; _encyNavLabel = 'Constituent List';
                } else if (/\bGLOSSARY\b/.test(_pu5)) {
                    _encyNavUrl = '/ENCY/glossary'; _encyNavLabel = 'Glossary';
                } else if (/\bDISEASE/.test(_pu5)) {
                    _encyNavUrl = '/ENCY/diseases'; _encyNavLabel = 'Diseases List';
                } else if (/\bSYMPTOM/.test(_pu5)) {
                    _encyNavUrl = '/ENCY/symptoms'; _encyNavLabel = 'Symptoms List';
                } else if (/\bFORMULA|RECIPE/.test(_pu5)) {
                    _encyNavUrl = '/ENCY/formula'; _encyNavLabel = 'Formulas / Recipes';
                } else if (/\bINSECT/.test(_pu5)) {
                    _encyNavUrl = '/ENCY/insects'; _encyNavLabel = 'Insects';
                } else if (/\bANIMAL/.test(_pu5)) {
                    _encyNavUrl = '/ENCY/animals'; _encyNavLabel = 'Animals';
                } else if (/\bPOLLINATOR|BEE\s*PASTURE|FORAGE/.test(_pu5)) {
                    _encyNavUrl = '/ENCY/BeePastureView'; _encyNavLabel = 'Bee Pasture / Pollinators';
                }
                if (_encyNavUrl) {
                    loadingMessage.remove();
                    statusIndicator.textContent = 'Opening ' + _encyNavLabel + '\u2026';
                    statusIndicator.className = 'chat-status connected';
                    executeAIAction({ action: 'navigate', url: _encyNavUrl });
                    const _nw = document.createElement('div');
                    _nw.className = 'msg-wrapper msg-wrapper-ai';
                    const _nlbl = document.createElement('div');
                    _nlbl.className = 'msg-label';
                    _nlbl.textContent = 'ENCY Agent';
                    const _nel = document.createElement('div');
                    _nel.className = 'message ai-message';
                    _nel.innerHTML = 'Opening <strong>' + _encyNavLabel + '</strong> in a new tab.';
                    _nw.appendChild(_nlbl);
                    _nw.appendChild(_nel);
                    const _ncm = document.getElementById('chat-messages');
                    if (_ncm) { _ncm.appendChild(_nw); _ncm.scrollTop = _ncm.scrollHeight; }
                    return;
                }
            }
        }

        // ENCY fast path: navigate to constituent#N page or add form directly.
        if (_agentId === 'ency') {
            const _pu4 = prompt.toUpperCase();
            const _encyFastIntent = /FIX.*CONSTITUENT|UNRESOLVED.*TERM|RESOLVE.*TERM|ADD.*CONSTITUENT|CREATE.*CONSTITUENT|ADDING.*CONSTITUENT/.test(_pu4)
                || /\bCONSTITUENT\b/.test(_pu4);
            if (_encyFastIntent) {
                const _chatMsgs2 = document.getElementById('chat-messages');
                let _encyText = prompt;
                if (_chatMsgs2) {
                    _chatMsgs2.querySelectorAll('.message').forEach(function(el) {
                        _encyText += ' ' + (el.textContent || '');
                    });
                }
                const _cidM = _encyText.match(/constituent\s*#\s*(\d+)/i) || _encyText.match(/constituent\s+id\s*[:=]?\s*(\d+)/i);
                if (_cidM) {
                    const _cid = _cidM[1];
                    loadingMessage.remove();
                    statusIndicator.textContent = 'Opening constituent #' + _cid + '\u2026';
                    statusIndicator.className = 'chat-status connected';
                    executeAIAction({ action: 'navigate', url: '/ENCY/Constituent/' + _cid });
                    const _w2 = document.createElement('div');
                    _w2.className = 'msg-wrapper msg-wrapper-ai';
                    const _lbl2 = document.createElement('div');
                    _lbl2.className = 'msg-label';
                    _lbl2.textContent = 'ENCY Agent';
                    const _el2 = document.createElement('div');
                    _el2.className = 'message ai-message';
                    _el2.innerHTML = 'Opening <strong>Constituent #' + _cid + '</strong> so you can see which term is unresolved. '
                        + 'Once you identify the missing term, ask me to "add constituent [name]" and I will open the add form pre-filled.';
                    _w2.appendChild(_lbl2);
                    _w2.appendChild(_el2);
                    if (_chatMsgs2) { _chatMsgs2.appendChild(_w2); _chatMsgs2.scrollTop = _chatMsgs2.scrollHeight; }
                    return;
                }
            }
        }

        // ENCY fast path: when ENCY agent is active and the prompt or chat history mentions
        // "Unresolved term in constituent#N", navigate directly to that constituent's page.
        // When adding a named constituent, navigate to the add form pre-filled.
        if (_agentId === 'ency') {
            const _pu4 = prompt.toUpperCase();
            const _encyFastIntent = /FIX.*CONSTITUENT|UNRESOLVED.*TERM|RESOLVE.*TERM|ADD.*CONSTITUENT|CREATE.*CONSTITUENT|ADDING.*CONSTITUENT/.test(_pu4)
                || /\bCONSTITUENT\b/.test(_pu4);
            if (_encyFastIntent) {
                const _chatMsgs2 = document.getElementById('chat-messages');
                let _encyText = prompt;
                if (_chatMsgs2) {
                    _chatMsgs2.querySelectorAll('.message').forEach(function(el) {
                        _encyText += ' ' + (el.textContent || '');
                    });
                }
                const _cidM = _encyText.match(/constituent\s*#\s*(\d+)/i) || _encyText.match(/constituent\s+id\s*[:=]?\s*(\d+)/i);
                if (_cidM) {
                    const _cid = _cidM[1];
                    loadingMessage.remove();
                    statusIndicator.textContent = 'Opening constituent #' + _cid + '…';
                    statusIndicator.className = 'chat-status connected';
                    executeAIAction({ action: 'navigate', url: '/ENCY/Constituent/' + _cid });
                    const _w2 = document.createElement('div');
                    _w2.className = 'msg-wrapper msg-wrapper-ai';
                    const _lbl2 = document.createElement('div');
                    _lbl2.className = 'msg-label';
                    _lbl2.textContent = 'ENCY Agent';
                    const _el2 = document.createElement('div');
                    _el2.className = 'message ai-message';
                    _el2.innerHTML = 'Opening <strong>Constituent #' + _cid + '</strong> so you can see which term is unresolved. '
                        + 'Once you identify the missing term, ask me to "add constituent [name]" and I will open the add form pre-filled.';
                    _w2.appendChild(_lbl2);
                    _w2.appendChild(_el2);
                    if (_chatMsgs2) { _chatMsgs2.appendChild(_w2); _chatMsgs2.scrollTop = _chatMsgs2.scrollHeight; }
                    return;
                }
            }
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
            agent_name: state.pageContext.agent_name,
            page_content: extractPageContent(),
            // Send pre-extracted links too (in addition to raw content). Server will also parse content
            // as a fallback. This helps the AI immediately learn about new links / new .tt-backed pages
            // visible to the user ("searching the links on the page").
            page_links: (typeof extractPageLinks === 'function' ? extractPageLinks() : [])
        };

        // Include image data if present (for Grok vision models)
        if (imageData && imageData.data) {
            requestPayload.image_data = imageData.data;
            requestPayload.image_mime = imageData.mime || 'image/jpeg';
        }
        
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

        // Link audio/transcript files from the most recent voice recording.
        // These are set by _transcribeAudioFile() after a successful transcription.
        // Sent once with the first message after a recording, then cleared.
        if (state.lastAudioFileId) {
            requestPayload.audio_file_id = state.lastAudioFileId;
            state.lastAudioFileId = null;
        }
        if (state.lastTranscriptFileId) {
            requestPayload.transcript_file_id = state.lastTranscriptFileId;
            state.lastTranscriptFileId = null;
        }

        // Build conversation history from visible messages (exclude current user msg
        // which was just appended to the DOM before queryAI() was called).
        // Send last 4 prior messages (2 exchanges) as multi-turn context.
        // Keeping history short is critical: CPU Ollama prefill at ~46 tok/s means
        // 7000 tokens = 152s, hitting the timeout.  Target: <3000 tokens total input.
        (function buildHistory() {
            const allWrappers = Array.from(
                document.querySelectorAll('#chat-messages .msg-wrapper')
            );
            // The last wrapper is the current user message — exclude it
            const priorWrappers = allWrappers.slice(0, -1);
            const historyMsgs = [];
            priorWrappers.forEach(function(w) {
                const isUser = w.classList.contains('msg-wrapper-user');
                const el = w.querySelector('.message');
                if (!el) return;
                const content = el.textContent.trim();
                if (!content || content === '\u2014 Previous conversation \u2014') return;
                // Truncate each history message to 500 chars to avoid bloating context
                historyMsgs.push({
                    role: isUser ? 'user' : 'assistant',
                    content: content.length > 500 ? content.substring(0, 500) + '…' : content
                });
            });
            if (historyMsgs.length > 0) {
                requestPayload.history = historyMsgs.slice(-4);
                console.debug('Sending history:', requestPayload.history.length, 'prior messages');
            }
        })();
        
        console.debug('Sending AI request with agent:', state.pageContext.agent_id, requestPayload);

        // Show a live pre-send thinking block so users can see what the system is doing
        // while the model is loading/responding.  It is removed when the real server
        // thinking trace arrives (success or error).
        const chatMessages2 = document.getElementById('chat-messages');
        const liveThinkEl = document.createElement('details');
        liveThinkEl.className = 'ai-thinking ai-thinking-live';
        liveThinkEl.open = state.isAdmin;   // auto-open for admins only
        const liveSum = document.createElement('summary');
        liveSum.textContent = '⏳ Building request…';
        const liveBody = document.createElement('div');
        liveBody.className = 'ai-thinking-body';

        // Helper — append a step to the live block and scroll
        function _liveStep(emoji, label, detail) {
            var s = document.createElement('div');
            s.className = 'ai-thinking-step';
            s.textContent = (emoji ? emoji + ' ' : '') + label + (detail ? '\n' + detail : '');
            liveBody.appendChild(s);
            if (chatMessages2) chatMessages2.scrollTop = chatMessages2.scrollHeight;
            return s;
        }
        // Helper — update the last step's text (for polling updates)
        function _updateLiveStep(stepEl, text) {
            if (stepEl) stepEl.textContent = text;
            if (chatMessages2) chatMessages2.scrollTop = chatMessages2.scrollHeight;
        }

        var tierLabel2 = autoTier ? ({ nav: 'fast', simple: 'fast', medium: 'standard', complex: 'advanced' }[autoTier] || autoTier) : 'auto';

        _liveStep('🧑', 'User: ' + (state.username || 'You') + ' | Role: ' + (state.isAdmin ? 'admin' : 'user'));
        _liveStep('📍', 'Page: ' + (state.pageContext.page_path || window.location.pathname));
        _liveStep('🤖', 'Provider: ' + providerName + (modelName ? ' / ' + modelName : '') + ' | Tier: ' + tierLabel2);
        _liveStep('📝', 'Prompt (' + prompt.length + ' chars):\n' + prompt.substring(0, 200) + (prompt.length > 200 ? '…' : ''));

        // Show page content extract
        if (requestPayload.page_content) {
            _liveStep('📄', 'Page content extracted (' + requestPayload.page_content.length + ' chars):',
                requestPayload.page_content.substring(0, 400) + (requestPayload.page_content.length > 400 ? '\n…[truncated]' : ''));
        } else {
            _liveStep('📄', 'No page content extracted');
        }

        // Show each history message
        if (requestPayload.history && requestPayload.history.length > 0) {
            _liveStep('💬', 'Sending ' + requestPayload.history.length + ' history messages:');
            requestPayload.history.forEach(function(msg, i) {
                var preview = (msg.content || '').substring(0, 150);
                if ((msg.content || '').length > 150) preview += '…';
                _liveStep('  ↳', '[' + (msg.role || '?') + '] ' + preview);
            });
        } else {
            _liveStep('💬', 'No conversation history (first message)');
        }

        // Estimate total size
        var totalChars = (requestPayload.page_content || '').length
            + (requestPayload.history || []).reduce(function(s, m) { return s + (m.content || '').length; }, 0)
            + prompt.length;
        _liveStep('📊', 'Estimated input: ~' + totalChars + ' chars (~' + Math.round(totalChars/4) + ' tokens)');
        _liveStep('🚀', 'Sending to ' + (providerName || 'AI') + '…');

        var liveWaitStep = _liveStep('⏳', 'Waiting for model response…');

        liveThinkEl.appendChild(liveSum);
        liveThinkEl.appendChild(liveBody);
        if (chatMessages2) {
            chatMessages2.appendChild(liveThinkEl);
            chatMessages2.scrollTop = chatMessages2.scrollHeight;
        }

        // Declare isOllama early so it can be used in both the progress poller and timeout logic
        const isOllama = providerName === 'ollama';

        // Poll /ai/chat_progress every 3 s to pick up server-side trace steps
        // (DB lookups, model selection, etc.) while Ollama is generating.
        var _pollSteps = {};   // deduplicate by step text
        var _progressPoller = null;
        if (state.isAdmin && isOllama) {
            _progressPoller = setInterval(function() {
                fetch('/ai/chat_progress', { credentials: 'include' })
                .then(function(r) { return r.ok ? r.json() : null; })
                .then(function(d) {
                    if (!d || !d.steps) return;
                    d.steps.forEach(function(step) {
                        if (_pollSteps[step]) return;
                        _pollSteps[step] = true;
                        _liveStep('🔄', step);
                    });
                    if (d.done) {
                        clearInterval(_progressPoller);
                        _progressPoller = null;
                    }
                })
                .catch(function() {});
            }, 3000);
        }

        // Provider-aware client timeout:
        //   Ollama: 660 s (server-side is 600 s for cold starts, 300 s warm — give extra buffer)
        //   Grok:   90 s (server-side is 120 s — complex audit/analysis queries need time)
        const clientTimeoutMs = isOllama ? 660000 : 90000;
        const abortCtrl = new AbortController();
        state.currentAbortCtrl = abortCtrl;   // expose for cancel button
        const abortTimer = setTimeout(function() {
            abortCtrl.abort();
        }, clientTimeoutMs);

        // Add a Cancel button to the loading message so the user can abort
        // a slow cold-start without the page feeling frozen.
        const loadingEl2 = document.getElementById('ai-loading');
        if (loadingEl2) {
            const cancelBtn = document.createElement('button');
            cancelBtn.type = 'button';
            cancelBtn.id = 'ai-cancel-btn';
            cancelBtn.className = 'chat-retry-btn';
            cancelBtn.style.cssText = 'margin-left:10px;font-size:0.8em;vertical-align:middle;';
            cancelBtn.textContent = '✕ Cancel';
            cancelBtn.addEventListener('click', function() {
                abortCtrl.abort();
                cancelBtn.disabled = true;
                cancelBtn.textContent = 'Cancelling…';
            });
            loadingEl2.appendChild(cancelBtn);
        }

        // Progressive status updates so the user knows what is happening, not just
        // a frozen spinner.  Timings reflect real CPU-Ollama inference speeds.
        let progressTimer1, progressTimer2, progressTimer3, progressTimer4;
        if (isOllama) {
            const loadingEl = document.getElementById('ai-loading');
            const _setLoadTxt = function(txt) {
                if (loadingEl && loadingEl.firstChild) loadingEl.firstChild.textContent = txt;
            };
            progressTimer1 = setTimeout(function() { _setLoadTxt('⏳ Processing your request…'); },      10000);
            progressTimer2 = setTimeout(function() { _setLoadTxt('⏳ Model is generating response… (60–120 s warm / up to 5 min cold start)'); }, 30000);
            progressTimer3 = setTimeout(function() { _setLoadTxt('⏳ Still working… model may be loading from disk on first use — please wait'); }, 90000);
            progressTimer4 = setTimeout(function() { _setLoadTxt('⏳ Almost there… CPU inference is slow for large inputs (up to 10 min cold start)'); }, 300000);
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
            clearTimeout(progressTimer3);
            clearTimeout(progressTimer4);
            if (_progressPoller) { clearInterval(_progressPoller); _progressPoller = null; }
            state.currentAbortCtrl = null;
            return response.text().then(function(text) {
                try {
                    return JSON.parse(text);
                } catch(e) {
                    throw new Error('Server returned non-JSON response (HTTP ' + response.status + '). The server may have crashed — check logs.');
                }
            });
        })
        .then(data => {
            try {
                sessionStorage.removeItem('ai_pending_query');
            } catch(e) {}

            // Remove loading message and live pre-send thinking block
            const loading = document.getElementById('ai-loading');
            if (loading) loading.remove();
            liveThinkEl.remove();

            if (!data) {
                throw new Error('AI server returned an empty response. Please try again.');
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
                                          : 'grok|grok-4.3';
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
                    // Notify /ai page sidebar via bridge
                    if (PAGE_MODE && window.AIChatPageBridge && window.AIChatPageBridge.onConversationIdChange) {
                        window.AIChatPageBridge.onConversationIdChange(data.conversation_id);
                    }
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
                
                // Render thinking/trace block BEFORE the response so context is visible first.
                // Always open so users can see the AI's reasoning process.
                console.debug('[AI thinking] success data.thinking:', data.thinking);
                if (data.thinking && data.thinking.length > 0) {
                    const thinkingEl = document.createElement('details');
                    thinkingEl.className = 'ai-thinking';
                    thinkingEl.open = true;
                    const summary = document.createElement('summary');
                    summary.textContent = '🔍 AI Thinking (' + data.thinking.length + ' steps)';
                    const body = document.createElement('div');
                    body.className = 'ai-thinking-body';
                    data.thinking.forEach(function(step) {
                        const stepEl = document.createElement('div');
                        stepEl.className = 'ai-thinking-step';
                        stepEl.textContent = step;
                        body.appendChild(stepEl);
                    });
                    thinkingEl.appendChild(summary);
                    thinkingEl.appendChild(body);
                    const chatMessages = document.getElementById('chat-messages');
                    chatMessages.appendChild(thinkingEl);
                    chatMessages.scrollTop = chatMessages.scrollHeight;
                }

                // Add AI response — strip any embedded [ACTION: ...] and [SUPPORT_NEEDED] before display
                const { cleanText: _rawClean, actions } = extractActions(data.response || '');
                const _needsSupport = (typeof _detectSupportNeeded === 'function')
                    ? _detectSupportNeeded(_rawClean)
                    : /\[SUPPORT_NEEDED\]/i.test(_rawClean);
                const cleanText = _stripSupportTag(_rawClean).replace(/https?:\/\/(?:example\.com|localhost(?::\d+)?)(\/[^\s"')\]>]*)/g, '$1');
                addMessage(cleanText, 'ai-message');

                // Voice mode: read the AI response aloud, then restart listening
                if (state._speakResponse) { state._speakResponse(cleanText); }

                if (_needsSupport && !state.supportMode) {
                    _showEscalationButtons();
                }

                persistMessages();

                // Coding agent: intercept [READ_FILE: path] requests automatically
                if (state.pageContext && state.pageContext.agent_id === 'coding') {
                    var rfMatch = cleanText.match(/\[READ_FILE:\s*([^\]]+)\]/i);
                    if (rfMatch) {
                        _handleReadFileRequest(rfMatch[1].trim());
                    }
                }

                // Execute any in-app actions the AI embedded
                if (actions.length > 0) {
                    actions.forEach(function(actionObj) {
                        executeAIAction(actionObj);
                    });
                }

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
                    retryBtn.onclick = function() {
                        // Remove the thinking block that immediately follows this wrapper (if any)
                        var nextEl = wrapper.nextElementSibling;
                        if (nextEl && nextEl.classList.contains('ai-thinking')) nextEl.remove();
                        persistMessages();
                        wrapper.remove();
                        queryAI(prompt);
                    };
                    wrapper.appendChild(retryBtn);
                }
                chatMessages.appendChild(wrapper);

                // Show thinking trace even on error for diagnostics.
                // Always open on error so admins see it without needing to click.
                console.debug('[AI thinking] data.thinking:', data.thinking);
                if (data.thinking && data.thinking.length > 0) {
                    const errThinkingEl = document.createElement('details');
                    errThinkingEl.className = 'ai-thinking';
                    errThinkingEl.open = true;
                    const summary = document.createElement('summary');
                    summary.textContent = '⚠️ AI Thinking — Error Trace (' + data.thinking.length + ' steps)';
                    const body = document.createElement('div');
                    body.className = 'ai-thinking-body';
                    data.thinking.forEach(function(step) {
                        const stepEl = document.createElement('div');
                        stepEl.className = 'ai-thinking-step';
                        stepEl.textContent = step;
                        body.appendChild(stepEl);
                    });
                    errThinkingEl.appendChild(summary);
                    errThinkingEl.appendChild(body);
                    chatMessages.appendChild(errThinkingEl);
                }

                persistMessages();  // save error + thinking into session history
                chatMessages.scrollTop = chatMessages.scrollHeight;
            }
        })
        .catch(function(error) {
            clearTimeout(abortTimer);
            clearTimeout(progressTimer1);
            clearTimeout(progressTimer2);
            clearTimeout(progressTimer3);
            clearTimeout(progressTimer4);
            if (_progressPoller) { clearInterval(_progressPoller); _progressPoller = null; }
            const loading = document.getElementById('ai-loading');
            if (loading) loading.remove();

            // Suppress error reporting if the page is currently unloading/navigating away
            if (state.isUnloading) {
                console.debug('[AI] Fetch aborted due to page unload/navigation — suppressing error reporting');
                return;
            }

            // Clear the pending query if it's a real failure, not an unload/navigation
            try {
                sessionStorage.removeItem('ai_pending_query');
            } catch(e) {}

            console.error('Error querying AI:', error);
            statusIndicator.textContent = 'AI Error';
            statusIndicator.className = 'chat-status error';

            const isTimeout = error.name === 'AbortError';
            const ollamaTimeout = isTimeout && isOllama;
            const msg = isTimeout
                ? 'Request timed out after ' + (clientTimeoutMs / 1000) + 's.'
                    + (ollamaTimeout
                        ? ' The local Ollama model is overloaded or too large for the current hardware. Try switching to a cloud provider (Grok) for instant responses.'
                        : ' The AI server may be busy.')
                : 'Network error: ' + error.message + '. Please try again.';

            _liveStep('❌', (isTimeout ? 'Client timed out after ' + (clientTimeoutMs/1000) + 's' : 'Network error: ' + error.message));
            liveSum.textContent = '⚠️ AI Thinking — ' + (isTimeout ? 'Timeout' : 'Network Error')
                + ' Trace (' + liveBody.children.length + ' steps)';
            liveThinkEl.className = 'ai-thinking';
            liveThinkEl.open = true;

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

            function _doRetry(switchProvider) {
                persistMessages();
                liveThinkEl.remove();
                var nextEl = wrapper.nextElementSibling;
                if (nextEl && nextEl.classList.contains('ai-thinking')) nextEl.remove();
                wrapper.remove();
                if (switchProvider) {
                    var sel = document.getElementById('provider-select');
                    if (sel) {
                        sel.value = switchProvider;
                        sel.dispatchEvent(new Event('change'));
                    }
                }
                queryAI(prompt);
            }

            const retryBtn = document.createElement('button');
            retryBtn.className = 'chat-retry-btn';
            retryBtn.textContent = '↺ Retry Ollama';
            retryBtn.onclick = function() { _doRetry(null); };
            wrapper.appendChild(retryBtn);

            if (ollamaTimeout) {
                var switchGrokBtn = document.createElement('button');
                switchGrokBtn.className = 'chat-retry-btn';
                switchGrokBtn.style.cssText = 'margin-left:8px;background:#1a1a2e;color:#fff;';
                switchGrokBtn.textContent = '⚡ Switch to Grok';
                switchGrokBtn.onclick = function() { _doRetry('grok'); };
                wrapper.appendChild(switchGrokBtn);
            }

            chatMessages.appendChild(wrapper);
            persistMessages();
            chatMessages.scrollTop = chatMessages.scrollHeight;
        });
    }
    


    // Returns true for models that support chat/generate (excludes embeddings, rerankers, etc.)
    function isChatModel(id) {
        const s = id.toLowerCase();
        // Exclude embedding/reranker/vision-only models
        if (/embed|rerank|bge|nomic|clip|whisper|tts|vision(?!.*instruct)/.test(s)) return false;
        // :cloud models (Ollama-routed cloud) are chat-capable — include them
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
        if (/kimi-k2|kimi/.test(s))                            return 6;
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

    // Static FAQ fast-path — instant canned answers for common support questions.
    // These fire BEFORE any AI call, so the user gets an immediate response.
    // Each entry: { match: RegExp, answer: string (markdown supported) }
    var STATIC_FAQ = [
        {
            match: /\b(create|make|get|open|set.?up)\b.{0,20}\baccount\b|\bsign.?up\b|\bregister\b|\bhow.{0,20}\bjoin\b|\bnew.{0,10}\buser\b/i,
            answer: 'You can create your own account using our self-registration process.\n\nSee the **[User Registration Guide](/Documentation/UserRegistrationGuide)** for step-by-step instructions.\n\nIf you have trouble or need an account set up by an administrator, [submit a HelpDesk ticket](/HelpDesk).',
        },
        {
            match: /\b(reset|forgot|forgotten|lost|change)\b.{0,15}\bpassword\b|\bpassword.{0,15}\b(reset|forgot|change|lost)\b/i,
            answer: 'To reset your password, click **Forgot Password** on the login page. A reset link will be emailed to your registered address.\n\nIf you no longer have access to that email, [submit a HelpDesk ticket](/HelpDesk) and an administrator can reset it for you.',
        },
        {
            match: /\bhow.{0,20}\blog.{0,5}(in|out)\b|\bsign.{0,5}(in|out)\b|\bcannot.{0,10}log.{0,5}in\b|\bcan.?t.{0,10}log.{0,5}in\b/i,
            answer: 'To log in, enter your username and password on the [login page](/login). Your username is usually your email address.\n\nIf you are having trouble logging in, try **Forgot Password** on the login page or [submit a HelpDesk ticket](/HelpDesk).',
        },
        {
            match: /\bhow.{0,25}\b(report|submit|log|file).{0,15}\b(bug|error|issue|problem|ticket)\b|\bhow.{0,20}\bget.{0,10}\bhelp\b/i,
            answer: 'To report a problem or get help:\n\n1. [Submit a HelpDesk ticket](/HelpDesk) — include what you were doing and any error message you saw.\n2. Or use this chat — describe the issue and I can help diagnose it.',
        },
        {
            match: /\bwhat.{0,20}\b(this|site|system|application|app|platform)\b|\bwhat (is|does).{0,20}\b(comserv|bmaster|beemaster|ency)\b/i,
            answer: 'This is **Comserv** — a multi-site community platform. Depending on your site it includes:\n\n- **BeeMaster** — apiary and beekeeping management\n- **ENCY** — herbal and plant encyclopedia\n- **HelpDesk** — support tickets\n- **Planning** — project and todo management\n- **Workshops** — local event listings\n\nAsk me anything about the features available on your site.',
        },
        {
            match: /\bcontact.{0,20}\b(support|admin|administrator|someone|staff|team)\b|\bhow.{0,20}\b(contact|reach|talk to|speak to).{0,20}\b(support|admin|help)\b/i,
            answer: 'To contact support, [submit a HelpDesk ticket](/HelpDesk). An administrator will respond as soon as possible.\n\nYou can also continue this chat — I can answer most questions right here.',
        },
    ];

    // Content-based agent keyword overrides.
    // When a prompt clearly targets a different domain than the current page agent,
    // the agent is switched automatically — no need to navigate to the right page first.
    // Format: { agentId, pattern }  — first match wins.
    var AGENT_KEYWORD_OVERRIDES = [
        {
            agentId: 'accounting',
            pattern: /\b(accounts payable|accounts receivable|supplier bill|purchase order)\b|open.*invoice.*form|file.*invoice|enter.*bill|record.*invoice/i,
        },
        {
            agentId: 'helpdesk',
            pattern: /\b(helpdesk|help desk|submit.*ticket|create.*ticket|report.*error|report.*bug|report.*issue)\b|how do i report/i,
        },
    ];

    // Concept synonym groups for smarter nav resolution.
    // When resolveNavIntent cannot match a query via STATIC_NAV label matching, it falls
    // back to these concept groups so that "medicinal plants" → /ENCY/herbs etc.
    // Each entry: { url, concepts[] }  — concepts are lowercase strings to match against query.
    var NAV_CONCEPT_GROUPS = [
        { url: '/ENCY/glossary',         concepts: ['terminology', 'dictionary', 'vocab', 'vocabulary', 'definitions', 'define', 'look up term', 'beekeeping terms', 'herbal terms'] },
        { url: '/ENCY/herbs',            concepts: ['medicinal plants', 'herb database', 'plant database', 'botanical list', 'herbal list', 'flora', 'herb search'] },
        { url: '/ENCY/diseases',         concepts: ['conditions', 'ailments', 'health conditions', 'bee diseases', 'hive diseases', 'disorders', 'bee conditions'] },
        { url: '/ENCY/BeePastureView',   concepts: ['nectar plants', 'pollen plants', 'bee garden', 'foraging plants', 'bee friendly plants', 'melliferous', 'pasture plants', 'pollinator garden'] },
        { url: '/ENCY/symptoms',         concepts: ['signs', 'hive symptoms', 'bee symptoms', 'warning signs', 'colony symptoms'] },
        { url: '/ENCY/Constituent',      concepts: ['active compounds', 'chemical constituents', 'phytochemicals', 'active ingredients'] },
        { url: '/ENCY/formula',          concepts: ['remedy', 'remedies', 'preparation', 'preparations', 'compound formula', 'herbal recipe'] },
        { url: '/Inventory/invoice/new', concepts: ['new invoice', 'add invoice', 'create invoice', 'log bill', 'record bill', 'enter bill', 'new bill'] },
        { url: '/HelpDesk',              concepts: ['get help', 'support system', 'contact support', 'tech support', 'it support'] },
        { url: '/BMaster',              concepts: ['beekeeping home', 'bee management', 'beemaster', 'bee master home'] },
        { url: '/Apiary/HiveManagement', concepts: ['manage hives', 'my hives', 'hive list', 'hive overview'] },
    ];

    // Static nav entries always available regardless of current page links.
    // Keyed by label (lowercase) → path. Merged into the nav map at build time.
    // The origin is prepended at runtime so they work on any host.
    var STATIC_NAV = [
        { label: 'ai conversations',           url: '/ai/conversations' },
        { label: 'ai conversations / chat history', url: '/ai/conversations' },
        { label: 'conversations',              url: '/ai/conversations' },
        { label: 'chat history',               url: '/ai/conversations' },
        { label: 'ai chat',                    url: '/ai' },
        { label: 'ai',                         url: '/ai' },
        { label: 'manage api keys',            url: '/ai/manage_api_keys' },
        { label: 'api keys',                   url: '/ai/manage_api_keys' },
        { label: 'manage ai models',           url: '/ai/models' },
        { label: 'ai models',                  url: '/ai/models' },
        { label: 'models',                     url: '/ai/models' },
        { label: 'helpdesk',                   url: '/HelpDesk' },
        { label: 'help desk',                  url: '/HelpDesk' },
        { label: 'submit a ticket',            url: '/HelpDesk/ticket/new' },
        { label: 'todo list',                  url: '/todo' },
        { label: 'todos',                      url: '/todo' },
        { label: 'projects',                   url: '/project' },
        { label: 'daily plan',                 url: '/planning/daily' },
        { label: 'documentation',              url: '/Documentation' },
        { label: 'encyclopedia',               url: '/ENCY' },
        { label: 'ency',                       url: '/ENCY' },
        { label: 'admin',                      url: '/admin' },
        { label: 'admin dashboard',            url: '/admin' },
        { label: 'schema compare',             url: '/admin/schema_compare' },
        { label: 'schema comparison',          url: '/admin/schema_compare' },
        { label: 'schema_compare',             url: '/admin/schema_compare' },
        { label: 'compare schema',             url: '/admin/schema_compare' },
        { label: 'admin users',                url: '/admin/users' },
        { label: 'users',                      url: '/admin/users' },
        { label: 'admin logs',                 url: '/admin/logs' },
        { label: 'logs',                       url: '/admin/logs' },
        { label: 'system info',                url: '/admin/system_info' },
        { label: 'admin settings',             url: '/admin/settings' },
        { label: 'settings',                   url: '/admin/settings' },
        { label: 'docker containers',          url: '/admin/docker-containers' },
        { label: 'docker',                     url: '/admin/docker-containers' },
        { label: 'security scan',              url: '/admin/security-scan' },
        { label: 'link crawler',               url: '/admin/security-scan' },
        { label: 'crawler',                    url: '/admin/security-scan' },
        { label: 'link checker',               url: '/admin/security-scan' },
        { label: 'check links',                url: '/admin/security-scan' },
        { label: 'broken links',               url: '/admin/security-scan' },
        { label: 'git pull',                   url: '/admin/git_pull' },
        { label: 'planning admin',             url: '/admin/planning' },
        { label: 'workshops',                  url: '/workshop' },
        { label: 'membership',                 url: '/membership' },
        { label: 'navigation',                 url: '/navigation/manage_links' },
        { label: 'manage navigation',          url: '/navigation/manage_links' },
        { label: 'manage links',               url: '/navigation/manage_links' },
        { label: 'home',                       url: '/' },
        { label: 'main menu',                  url: '/' },
        { label: 'bmaster',                    url: '/BMaster' },
        { label: 'beemaster',                  url: '/BMaster' },
        { label: 'bee master',                 url: '/BMaster' },
        { label: 'beekeeping',                 url: '/BMaster' },
        { label: 'apiary',                     url: '/Apiary' },
        { label: 'apiary overview',            url: '/Apiary' },
        { label: 'hive management',            url: '/Apiary/HiveManagement' },
        { label: 'hives',                      url: '/Apiary/HiveManagement' },
        { label: 'queen rearing',              url: '/Apiary/QueenRearing' },
        { label: 'queens',                     url: '/Apiary/QueenRearing' },
        { label: 'bee health',                 url: '/Apiary/BeeHealth' },
        { label: 'bee forage',                 url: '/ENCY/BeePastureView' },
        { label: 'bee pasture',                url: '/ENCY/BeePastureView' },
        { label: 'forage plants',              url: '/ENCY/BeePastureView' },
        { label: 'forage',                     url: '/ENCY/BeePastureView' },
        { label: 'pollinator plants',          url: '/ENCY/BeePastureView' },
        { label: 'pollinators',                url: '/ENCY/BeePastureView' },
        { label: 'bee pasture view',           url: '/ENCY/BeePastureView' },
        { label: 'herbs',                      url: '/ENCY/herbs' },
        { label: 'herbs list',                 url: '/ENCY/herbs' },
        { label: 'herb list',                  url: '/ENCY/herbs' },
        { label: 'plant list',                 url: '/ENCY/herbs' },
        { label: 'plants',                     url: '/ENCY/herbs' },
        { label: 'botanical names',            url: '/ENCY/BotanicalNameView' },
        { label: 'glossary',                   url: '/ENCY/glossary' },
        { label: 'beekeeping glossary',        url: '/ENCY/glossary' },
        { label: 'terms',                      url: '/ENCY/glossary' },
        { label: 'diseases',                   url: '/ENCY/diseases' },
        { label: 'diseases list',              url: '/ENCY/diseases' },
        { label: 'bee diseases',               url: '/ENCY/diseases' },
        { label: 'symptoms',                   url: '/ENCY/symptoms' },
        { label: 'symptoms list',              url: '/ENCY/symptoms' },
        { label: 'constituents',               url: '/ENCY/Constituent' },
        { label: 'constituent list',           url: '/ENCY/Constituent' },
        { label: 'formulas',                   url: '/ENCY/formula' },
        { label: 'recipes',                    url: '/ENCY/formula' },
        { label: 'insects',                    url: '/ENCY/insects' },
        { label: 'animals',                    url: '/ENCY/animals' },
        { label: 'therapeutic actions',        url: '/ENCY/therapeutic_actions' },
        { label: 'drug herb interactions',     url: '/ENCY/drug_herb_interactions' },
        { label: 'herb interactions',          url: '/ENCY/drug_herb_interactions' },
    ];

    // Build a flat {label, url} navigation map from:
    //   1. Static core routes (STATIC_NAV above)
    //   2. Links extracted from the agent system_prompt, matching both:
    //      - Absolute: "  - Label: https://host/path"
    //      - Relative: "  - Label: /path/to/page"   (agent nav-guide style)
    function buildNavigationMap() {
        const origin = window.location.origin;
        const map = STATIC_NAV.map(function(e) {
            return { label: e.label, url: origin + e.url };
        });
        const prompt = (state.pageContext && state.pageContext.system_prompt) || '';
        const reAbs = /^[ \t]*(?:-[ \t]+)?(.+?):\s*(https?:\/\/[^\s]+)$/gm;
        const reRel = /^[ \t]*-[ \t]+(.+?):\s*(\/[^\s(→,]+)/gm;
        let m;
        while ((m = reAbs.exec(prompt)) !== null) {
            const label = m[1].trim().toLowerCase();
            const url   = m[2].trim();
            if (label.length > 80 || /^\[/.test(label)) continue;
            if (!map.some(function(e) { return e.label === label; })) {
                map.push({ label, url });
            }
        }
        while ((m = reRel.exec(prompt)) !== null) {
            const label = m[1].trim().toLowerCase();
            const url   = origin + m[2].trim().replace(/\s.*$/, '');
            if (label.length > 80 || /^\[/.test(label) || /^(step|pass|when|if|for|do|use|note|the|a |an |this|it |your|their|all|any|each|always|never|only|also)/.test(label)) continue;
            if (!map.some(function(e) { return e.label === label; })) {
                map.push({ label, url });
            }
        }

        // 3. Extract all links (<a> elements with href) on the current page DOM (or window.opener if popup)
        try {
            const targetDoc = (window.AI_WIDGET_POPUP && window.opener && !window.opener.closed)
                ? window.opener.document
                : document;
            if (targetDoc) {
                targetDoc.querySelectorAll('a[href]').forEach(function(el) {
                    const href = el.getAttribute('href');
                    if (!href) return;
                    const trimmedHref = href.trim();
                    if (!trimmedHref || trimmedHref.startsWith('#') || /^(javascript|mailto|tel|sms):/i.test(trimmedHref)) return;
                    
                    const label = (el.textContent || el.innerText || '').trim().replace(/\s+/g, ' ').toLowerCase();
                    if (!label || label.length < 2 || label.length > 80) return;
                    if (/^(step|pass|when|if|for|do|use|note|the|a |an |this|it |your|their|all|any|each|always|never|only|also)/.test(label)) return;
                    
                    try {
                        const urlObj = new URL(trimmedHref, targetDoc.baseURI || window.location.href);
                        const resolvedUrl = urlObj.href;
                        if (!map.some(function(e) { return e.label === label; })) {
                            map.push({ label: label, url: resolvedUrl });
                        }
                    } catch(urlErr) {
                        // ignore malformed URLs
                    }
                });
            }
        } catch(docErr) {
            // ignore security/permission issues when accessing window.opener
        }

        return map;
    }

    // Levenshtein edit distance for typo tolerance
    function _editDist(a, b) {
        if (a === b) return 0;
        if (!a.length) return b.length;
        if (!b.length) return a.length;
        var prev = Array.from({ length: b.length + 1 }, function(_, i) { return i; });
        for (var i = 0; i < a.length; i++) {
            var curr = [i + 1];
            for (var j = 0; j < b.length; j++) {
                curr.push(Math.min(
                    curr[j] + 1,
                    prev[j + 1] + 1,
                    prev[j] + (a[i] === b[j] ? 0 : 1)
                ));
            }
            prev = curr;
        }
        return prev[b.length];
    }

    // Returns true if word `w` fuzzy-matches any word in `labelWords`
    // Threshold: 1 edit for words 4-5 chars, 2 edits for 6+ chars
    function _fuzzyWordMatch(w, labelWords) {
        if (w.length < 3) return false;
        var maxDist = w.length >= 6 ? 2 : 1;
        return labelWords.some(function(lw) {
            return lw.length >= 3 && _editDist(w, lw) <= maxDist;
        });
    }

    // Try to resolve a navigation intent query to a list of {label,url} matches
    function resolveNavIntent(rawQuery) {
        const q = rawQuery
            .replace(/^(goto|go to|open|take me to|navigate to|visit|switch to|switch|bring me to|load|browse|display|show me the|show me|take me to the|go to the)\s*/i, '')
            .replace(/^(the|a|an)\s+/i, '')
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
        if (partial.length) return partial;
        // Typo-tolerant fallback: fuzzy match each query word against label words
        const fuzzy = map.filter(function(item) {
            const labelWords = item.label.split(/\s+/);
            return words.filter(function(w) { return w.length >= 3; })
                .some(function(w) { return _fuzzyWordMatch(w, labelWords); });
        });
        if (fuzzy.length) return fuzzy;
        // Concept synonym fallback: match query against NAV_CONCEPT_GROUPS synonyms.
        // Catches natural-language phrases like "medicinal plants", "nectar plants", etc.
        const _origin3 = window.location.origin;
        for (var _cgi = 0; _cgi < NAV_CONCEPT_GROUPS.length; _cgi++) {
            const _cg = NAV_CONCEPT_GROUPS[_cgi];
            const _matched = _cg.concepts.some(function(c) {
                return q === c || q.includes(c) || c.includes(q);
            });
            if (_matched) return [{ label: _cg.concepts[0], url: _origin3 + _cg.url }];
        }
        return null;
    }

    // Navigation command regex — explicit nav keywords (voice-friendly: "open X", "go to X", etc.)
    // NOTE: "show me" and "find" are intentionally excluded — they are question/display words
    // that should be answered by the AI, not treated as navigation commands.
    const NAV_RE = /^(open|go to|take me to|navigate to|visit|switch to|switch|bring me to|load|browse|display|show me the|take me to the|go to the)\s+(.+)/i;

    // Helper: handle a resolved navigation match — announce and navigate
    function _executeNavMatch(message, messageInput, matches) {
        addMessage(message, 'user-message');
        messageInput.value = '';
        persistMessages();
        if (matches.length === 1) {
            addMessage('Navigating to [' + matches[0].label + '](' + matches[0].url + ')', 'ai-message');
            persistMessages();
            setTimeout(function() {
                if (window.AI_WIDGET_POPUP && window.opener && !window.opener.closed) {
                    window.opener.location.href = matches[0].url;
                } else {
                    window.location.href = matches[0].url;
                }
            }, 600);
        } else {
            const listMsg = 'Multiple pages match — which one did you mean?\n'
                + matches.slice(0, 8).map(function(m) { return '- [' + m.label + '](' + m.url + ')'; }).join('\n');
            addMessage(listMsg, 'ai-message');
            persistMessages();
        }
        return true;
    }

    // ── Support Chat ──────────────────────────────────────────────────────────

    function _showEscalationButtons(afterEl) {
        var strip = document.createElement('div');
        strip.className = 'support-escalation-strip';
        strip.style.cssText = 'display:flex;gap:8px;flex-wrap:wrap;padding:6px 10px 4px;border-top:1px solid #e0e0e0;margin-top:4px;';
        strip.innerHTML =
            '<span style="font-size:.82em;color:#666;align-self:center;">Need more help?</span>'
          + '<button class="chat-action-btn" onclick="(function(){'
          + '  var _s=window.__aiChatSupportFns;if(_s)_s.ticket();'
          + '})();" style="font-size:.8em;padding:4px 10px;background:#eee;border:1px solid #ccc;border-radius:4px;cursor:pointer;">📋 Create Ticket</button>'
          + '<button class="chat-action-btn" onclick="(function(){'
          + '  var _s=window.__aiChatSupportFns;if(_s)_s.startChat();'
          + '})();" style="font-size:.8em;padding:4px 10px;background:#1a6bb5;color:#fff;border:none;border-radius:4px;cursor:pointer;">💬 Chat with Support</button>';
        var container = document.getElementById('chat-messages');
        if (container) { container.appendChild(strip); container.scrollTop = container.scrollHeight; }
    }

    function _detectSupportNeeded(text) {
        if (/\[SUPPORT_NEEDED\]/i.test(text)) return true;
        var phrases = [
            /i\s+(don'?t|do not|cannot|can'?t)\s+(have|access|provide|help|answer|assist)/i,
            /outside\s+(my|the AI'?s?)\s+(capabilities|knowledge|scope|ability)/i,
            /please\s+contact\s+support/i,
            /you\s+('?ll?\s+)?need\s+to\s+contact/i,
            /i\s+am\s+unable\s+to\s+assist/i,
        ];
        return phrases.some(function(re) { return re.test(text); });
    }

    function _stripSupportTag(text) {
        return text.replace(/\[SUPPORT_NEEDED\]\s*/gi, '').trim();
    }


    function _enterSupportMode(convId, lastMsgId, ticketNumber) {
        state.supportMode   = true;
        state.supportConvId = convId;
        state.supportLastMsgId = lastMsgId || 0;
        // SSE replaces the old heartbeat + polling timers
        _startChatSSE();
        var header = document.getElementById('chat-header');
        if (header) {
            header.style.background = '#1a6bb5';
            header.textContent = '💬 Live Support Chat';
        }
        var placeholder = document.getElementById('message-input');
        if (placeholder) placeholder.placeholder = 'Describe your issue here…';
        var guidance = '✅ **An administrator has been notified and will join shortly.**\n\n'
            + 'Please describe your issue below — include any error messages, what you were doing, and what you expected to happen.\n\n'
            + 'If no admin responds within a few minutes you can [create a support ticket](/HelpDesk/ticket/new) instead.';
        _addSupportSystemMsg(guidance);
        _startSupportPolling();
    }

    function _exitSupportMode() {
        state.supportMode   = false;
        state.supportConvId = null;
        state.supportLastMsgId = 0;
        var header = document.getElementById('chat-header');
        if (header) { header.style.background = ''; header.textContent = state.currentAgent ? (state.currentAgent.display_name || 'AI Assistant') : 'AI Assistant'; }
        var placeholder = document.getElementById('message-input');
        if (placeholder) placeholder.placeholder = 'Type a message…';
    }

    function _addSupportSystemMsg(text) {
        var el = document.createElement('div');
        el.className = 'message system-message';
        el.style.cssText = 'background:#e8f0fe;border:1px solid #acc;padding:8px 14px;border-radius:6px;font-size:.85em;color:#1a3a6b;margin:4px 0;line-height:1.5;';
        var html = text
            .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
            .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
            .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" style="color:#1a6bb5;">$1</a>')
            .replace(/\n\n/g, '<br><br>')
            .replace(/\n/g, '<br>');
        el.innerHTML = html;
        var container = document.getElementById('chat-messages');
        if (container) { container.appendChild(el); container.scrollTop = container.scrollHeight; }
    }

    function _showNoAdminMessage() {
        el.className = 'message system-message';
        el.style.cssText = 'background:#fff3cd;border:1px solid #ffc107;padding:10px 14px;border-radius:6px;font-size:.85em;color:#664d03;margin:4px 0;line-height:1.6;';
        el.innerHTML = '⚠️ <strong>No administrator is currently logged in.</strong><br>'
            + 'You can submit a support ticket and an admin will respond when available:<br>'
            + '<button onclick="(function(){var _s=window.__aiChatSupportFns;if(_s)_s.ticket();})()" '
            + 'style="margin-top:8px;padding:6px 14px;background:#1a6bb5;color:#fff;border:none;border-radius:4px;cursor:pointer;font-size:.88em;">📋 Create Support Ticket</button>';
        var container = document.getElementById('chat-messages');
        if (container) { container.appendChild(el); container.scrollTop = container.scrollHeight; }
    }

    function _initSupportChat(contextMsg) {
        _addSupportSystemMsg('⏳ Checking admin availability…');
        fetch('/chat/check_admin_online', { credentials: 'include' })
        .then(function(r) { return r.json(); })
        .then(function(presence) {
            console.log('[Chat] check_admin_online:', presence);
            if (!presence.online) {
                _showNoAdminMessage();
                return;
            }
            var _rawTitle = (document.title || '').replace(/https?:\/\/[^\s|:]+[:|]?\s*/g, '').replace(/\s*[:|]\s*$/, '').trim();
            var _chatTitle = 'Support Chat — ' + (_rawTitle || window.location.pathname);
            var body = new URLSearchParams({
                message: contextMsg || 'User requested live support',
                agent_type: 'support',
                title: _chatTitle
            });
            fetch('/chat/send_message', { method: 'POST', credentials: 'include', body: body })
            .then(function(r) { return r.json(); })
            .then(function(d) {
                if (d.success && d.conversation_id) {
                    state.supportLastMsgId = d.message_id || 0;
                    _enterSupportMode(d.conversation_id, d.message_id);
                } else {
                    _addSupportSystemMsg('❌ Could not connect to support. Please try creating a ticket.');
                }
            })
            .catch(function() {
                _addSupportSystemMsg('❌ Network error. Please try again.');
            });
        })
        .catch(function() {
            _addSupportSystemMsg('❌ Could not check admin status. Please try again.');
        });
    }

    function _createTicketFromSupport() {
        var msgs = [];
        document.querySelectorAll('#chat-messages .user-message, #chat-messages .ai-message').forEach(function(el) {
            var role = el.classList.contains('user-message') ? 'You' : 'AI';
            msgs.push(role + ': ' + el.textContent.trim());
        });
        var subject = 'Support request — ' + (document.title || window.location.pathname);
        var description = 'Chat transcript from AI widget:\n\n' + msgs.slice(-10).join('\n\n').slice(0, 1000);
        var params = new URLSearchParams({ subject: subject, description: description, category: 'support', priority: 'normal', from_chat: '1' });
        const ticketUrl = '/HelpDesk/ticket/new?' + params.toString();
        if (window.AI_WIDGET_POPUP && window.opener && !window.opener.closed) {
            window.opener.location.href = ticketUrl;
        } else {
            window.location.href = ticketUrl;
        }
    }

    window.__aiChatSupportFns = {
        ticket:    _createTicketFromSupport,
        startChat: function() {
            var lastUserMsg = '';
            document.querySelectorAll('#chat-messages .user-message').forEach(function(el) { lastUserMsg = el.textContent; });
            _initSupportChat(lastUserMsg.slice(-200) || 'User requested live support');
        },
        exit:      _exitSupportMode
    };

    // ─────────────────────────────────────────────────────────────────────────

    // Function to send a message
    function sendMessage() {
        const messageInput = document.getElementById('message-input');
        const message = messageInput.value.trim();
        if (!message && !state.pendingImage) return;

        // Support chat mode: route message to Chat controller, not AI
        if (state.supportMode && state.supportConvId) {
            messageInput.value = '';
            addMessage(message, 'user-message');
            var _spBody = new URLSearchParams({
                message: message,
                conversation_id: state.supportConvId,
                agent_type: 'support'
            });
            fetch('/chat/send_message', { method: 'POST', credentials: 'include', body: _spBody })
            .then(function(r) { return r.json(); })
            .then(function(d) {
                if (d.success && d.message_id > state.supportLastMsgId) {
                    state.supportLastMsgId = d.message_id;
                }
            })
            .catch(function() {});
            return;
        }

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

        // Early keyword interceptor: daily log actions bypass all AI routing
        {
            const _lcMsg = message.toLowerCase().trim().replace(/[!.]+$/, '').replace(/\s+/g, ' ');
            const _isMorning = /^(good morning|start day|begin day|start of day)$/.test(_lcMsg);
            const _isNight   = /^(good night|end day|finish day|end of day)$/.test(_lcMsg);
            if (_isMorning || _isNight) {
                const _action = _isMorning ? 'start' : 'end';
                messageInput.value = '';
                addMessage(message, 'user-message');
                const _chatMsgs = document.getElementById('chat-messages');
                const _loadEl = document.createElement('div');
                _loadEl.className = 'message ai-message';
                _loadEl.textContent = '⏳ ' + (_isMorning ? 'Starting your day…' : 'Closing your day…');
                if (_chatMsgs) { _chatMsgs.appendChild(_loadEl); _chatMsgs.scrollTop = _chatMsgs.scrollHeight; }
                fetch('/ai/daily_log', {
                    method: 'POST', credentials: 'include',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: 'action=' + encodeURIComponent(_action)
                })
                .then(function(r) { return r.json(); })
                .then(function(d) {
                    if (_loadEl && _loadEl.parentNode) _loadEl.parentNode.removeChild(_loadEl);
                    var resp = d.response || d.error || (_isMorning ? 'Day started.' : 'Day closed.');
                    addMessage(resp, 'ai-message');
                    if (d.success && window.location.pathname.includes('/planning/daily')) {
                        setTimeout(function() { window.location.reload(); }, 800);
                    }
                })
                .catch(function(e) {
                    if (_loadEl && _loadEl.parentNode) _loadEl.parentNode.removeChild(_loadEl);
                    addMessage('❌ Request failed: ' + e, 'ai-message');
                });
                return;
            }
        }

        // Template editor agent: open the dedicated form page with the file + request pre-loaded
        if (state.pageContext && state.pageContext.agent_id === 'template_editor' && message) {
            var tplPath = _getTemplatePathForPage(window.location.pathname);
            var params = new URLSearchParams();
            if (tplPath) params.set('file', tplPath);
            params.set('request', message);
            messageInput.value = '';
            window.open('/ai/template_editor?' + params.toString(), '_blank');
            return;
        }

        // Content-based agent override: if the prompt clearly targets a different domain
        // (e.g. "open the invoice form" from BMaster), switch to the correct agent before
        // any fast-path or AI call — so the right system prompt and logic apply.
        if (state.agentsConfig && state.agentsConfig.agents && message) {
            const _curAgentId = (state.pageContext && state.pageContext.agent_id) || '';
            for (var _ovIdx = 0; _ovIdx < AGENT_KEYWORD_OVERRIDES.length; _ovIdx++) {
                const _ovRule = AGENT_KEYWORD_OVERRIDES[_ovIdx];
                if (_curAgentId !== _ovRule.agentId && _ovRule.pattern.test(message)) {
                    const _ovAgent = state.agentsConfig.agents[_ovRule.agentId];
                    if (_ovAgent && _ovAgent.system_prompt) {
                        state.pageContext = Object.assign({}, state.pageContext || {}, {
                            agent_id: _ovRule.agentId,
                            system_prompt: _ovAgent.system_prompt,
                            display_name: _ovAgent.display_name || _ovRule.agentId,
                        });
                        const _siOv = document.getElementById('chat-status');
                        if (_siOv) {
                            _siOv.textContent = 'Using ' + (_ovAgent.display_name || _ovRule.agentId) + ' agent\u2026';
                            _siOv.className = 'chat-status connected';
                        }
                    }
                    break;
                }
            }
        }

        // ENCY agent: let the ENCY fast path inside sendAIRequest handle section navigation.
        // Skip resolveNavIntent entirely so it cannot misfire on words like "list".
        const _smAgentId = (state.pageContext && state.pageContext.agent_id) || '';
        const _isEncyNav = (_smAgentId === 'ency' || (state.pageContext && (state.pageContext.page_path || '').startsWith('/ENCY')))
            && message && /\b(OPEN|SHOW|LIST|BROWSE|GO TO|TAKE ME TO|DISPLAY|VIEW)\b/i.test(message)
            && /\b(HERB|HERBS|PLANT|PLANTS|BOTANICAL|CONSTIT|GLOSSARY|DISEASE|SYMPTOM|FORMULA|RECIPE|INSECT|ANIMAL|POLLINATOR|FORAGE|BEE)\b/i.test(message);

        // Client-side navigation interception — no AI round-trip needed (skip if image-only)
        // 1. Explicit nav keyword: "open X", "go to X", "switch to X", etc.
        const navMatch = !_isEncyNav && message && message.match(NAV_RE);
        if (navMatch) {
            const matches = resolveNavIntent(message);
            if (matches && matches.length >= 1) {
                _executeNavMatch(message, messageInput, matches);
                return;
            }
            // No local match — fall through to AI
        }

        // 2. Bare page-name navigation (voice-control ready): short message (≤5 words)
        //    that resolves to EXACTLY ONE navigation entry with high confidence.
        //    Prevents accidental interception of regular questions.
        const wordCount = message ? message.trim().split(/\s+/).length : 0;
        if (message && wordCount <= 5) {
            const bareMatches = resolveNavIntent(message);
            if (bareMatches && bareMatches.length === 1) {
                // Only auto-navigate on an exact or strong label match — not a loose partial
                const normalised = message.replace(/[^\w\s]/g, ' ').replace(/\s+/g, ' ').trim().toLowerCase();
                const lbl = bareMatches[0].label;
                if (lbl === normalised || lbl.startsWith(normalised) || normalised.startsWith(lbl.split(/\s+/).slice(0, 2).join(' '))) {
                    _executeNavMatch(message, messageInput, bareMatches);
                    return;
                }
            }
        }

        // Direct live-chat trigger — user explicitly wants a human, skip AI entirely.
        var DIRECT_SUPPORT_RE = /\b(chat|talk|speak|connect|transfer|escalate)\b.{0,25}\b(admin|administrator|support|agent|human|person|someone|staff|live)\b|\b(live|human|real)\s*(chat|support|agent|help)\b|\bi\s*(want|need|d like|would like).{0,20}\b(chat|talk|speak).{0,15}\b(admin|support|human|person|live)\b/i;
        if (message && !state.pendingImage && DIRECT_SUPPORT_RE.test(message)) {
            addMessage(message ? _escapeHtml(message) : '', 'user-message', true);
            messageInput.value = '';
            persistMessages();
            var _lastCtx = '';
            document.querySelectorAll('#chat-messages .user-message, #chat-messages .ai-message').forEach(function(el) {
                _lastCtx = el.textContent.trim();
            });
            _initSupportChat(_lastCtx.slice(-300) || message);
            return;
        }

        // FAQ fast-path: instant canned answer for common support questions.
        // Fires before queryAI so the user never waits on Ollama for trivial questions.
        if (message && !state.pendingImage) {
            for (var _fqi = 0; _fqi < STATIC_FAQ.length; _fqi++) {
                if (STATIC_FAQ[_fqi].match.test(message)) {
                    addMessage(message ? _escapeHtml(message) : '', 'user-message', true);
                    messageInput.value = '';
                    persistMessages();
                    addMessage(STATIC_FAQ[_fqi].answer, 'ai-message');
                    persistMessages();
                    _showEscalationButtons(null);
                    return;
                }
            }
        }

        // Build display message (text + optional thumbnail)
        let displayHtml = message ? _escapeHtml(message) : '';
        if (state.pendingImage) {
            displayHtml += (displayHtml ? '<br>' : '') +
                '<img src="' + state.pendingImage.dataUrl + '" style="max-height:120px;max-width:160px;border-radius:4px;margin-top:4px;display:block;">';
        }
        addMessage(displayHtml, 'user-message', true);
        messageInput.value = '';
        const imgForRequest = state.pendingImage || null;
        window._clearPendingImage();
        persistMessages();
        queryAI(message || '(image attached)', imgForRequest);
    }

    function _escapeHtml(s) {
        return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }
    
    // Function to add a message to the chat with sender label
    // Extract [ACTION: {...}] blocks from AI response text.
    // Returns { cleanText, actions[] } where cleanText has the blocks removed.
    function extractActions(text) {
        const actions = [];
        const cleanText = text.replace(/\[ACTION:\s*(\{[\s\S]*?\})\]/g, function(match, jsonStr) {
            try {
                const obj = JSON.parse(jsonStr);
                if (obj && obj.action) actions.push(obj);
            } catch(e) {
                console.warn('AI action JSON parse error:', e, jsonStr);
            }
            return '';
        }).trim();
        return { cleanText, actions };
    }

    // Fill form fields in the current page (or window.opener if popup).
    // actionObj.fields is a plain object: { fieldName: value, ... }
    // For checkboxes pass boolean/0/1; selects and inputs accept string values.
    function _executeFillForm(actionObj) {
        const chatMessages = document.getElementById('chat-messages');
        const fields = actionObj.fields || {};

        // When the chat is running in a detached popup window the form lives in the
        // opener page — try that first, fall back to the current document.
        const targetDoc = (window.AI_WIDGET_POPUP && window.opener && !window.opener.closed)
            ? window.opener.document
            : document;

        const filled = [];
        const missed = [];

        Object.keys(fields).forEach(function(fieldName) {
            const value = fields[fieldName];

            // Multi-checkbox group: multiple checkboxes sharing this name
            const allCheckboxes = Array.from(
                targetDoc.querySelectorAll('input[type="checkbox"][name="' + fieldName + '"]')
            );
            if (allCheckboxes.length > 1) {
                const strVal = Array.isArray(value)
                    ? value.join('; ')
                    : (value !== null && typeof value === 'object')
                        ? Object.values(value).join('; ')
                        : String(value || '');
                const selected = strVal.split(/[;,]/).map(function(s) { return s.trim().toLowerCase(); }).filter(Boolean);
                allCheckboxes.forEach(function(cb) {
                    const cbVal = cb.value.toLowerCase();
                    cb.checked = selected.some(function(s) { return cbVal === s || cbVal.indexOf(s) !== -1 || s.indexOf(cbVal) !== -1; });
                    cb.dispatchEvent(new Event('change', { bubbles: true }));
                });
                filled.push(fieldName);
                return;
            }

            // Try by name first, then by id
            let el = targetDoc.querySelector('[name="' + fieldName + '"]')
                  || targetDoc.getElementById(fieldName);

            if (!el) {
                missed.push(fieldName);
                return;
            }

            const tag  = el.tagName.toLowerCase();
            const type = (el.getAttribute('type') || '').toLowerCase();

            if (type === 'checkbox') {
                el.checked = !!(value === true || value === 1 || value === '1' || value === 'true');
            } else if (tag === 'select') {
                el.value = String(value);
                // Fallback: try case-insensitive match on option text
                if (!el.value || el.value !== String(value)) {
                    Array.from(el.options).forEach(function(opt) {
                        if (opt.text.toLowerCase() === String(value).toLowerCase()) {
                            el.value = opt.value;
                        }
                    });
                }
            } else {
                var strVal;
                if (Array.isArray(value)) {
                    strVal = value.join('; ');
                } else if (value !== null && typeof value === 'object') {
                    strVal = Object.values(value).join('; ');
                } else {
                    strVal = value !== null && value !== undefined ? String(value) : '';
                }
                el.value = strVal;
            }

            // Fire change/input events so any JS listeners react
            el.dispatchEvent(new Event('input',  { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            filled.push(fieldName);
        });

        const wrapper = document.createElement('div');
        wrapper.className = 'msg-wrapper msg-wrapper-ai';
        const lbl = document.createElement('div');
        lbl.className = 'msg-label';
        lbl.textContent = 'System';
        const el2 = document.createElement('div');
        el2.className = 'message system-message';
        let msg = '';
        if (filled.length)  msg += '✅ Filled: ' + filled.join(', ') + '.';
        if (missed.length)  msg += '\n⚠️ Not found: ' + missed.join(', ') + '.';
        if (!filled.length && !missed.length) msg = '⚠️ No fields specified.';
        el2.textContent = msg.trim();
        wrapper.appendChild(lbl);
        wrapper.appendChild(el2);
        chatMessages.appendChild(wrapper);
        chatMessages.scrollTop = chatMessages.scrollHeight;
    }

    // ── Local Audio Backup Store (IndexedDB) ───────────────────────────────────
    const dbName = 'AudioInspectionBackupDB';
    const storeName = 'recordings';

    function _openAudioDB() {
        return new Promise((resolve, reject) => {
            const request = indexedDB.open(dbName, 1);
            request.onerror = (e) => reject(e.target.error);
            request.onsuccess = (e) => resolve(e.target.result);
            request.onupgradeneeded = (e) => {
                const db = e.target.result;
                if (!db.objectStoreNames.contains(storeName)) {
                    db.createObjectStore(storeName, { keyPath: 'id' });
                }
            };
        });
    }

    async function _saveAudioBackup(id, file, elapsed) {
        try {
            const db = await _openAudioDB();
            const tx = db.transaction(storeName, 'readwrite');
            const store = tx.objectStore(storeName);
            const record = {
                id: id,
                fileName: file.name,
                type: file.type,
                blob: file,
                elapsed: elapsed,
                timestamp: Date.now(),
                status: 'pending'
            };
            store.put(record);
            return new Promise((resolve, reject) => {
                tx.oncomplete = () => resolve(record);
                tx.onerror = (e) => reject(e.target.error);
            });
        } catch (err) {
            console.error('Failed to save local audio backup:', err);
        }
    }

    async function _getAudioBackup(id) {
        try {
            const db = await _openAudioDB();
            const tx = db.transaction(storeName, 'readonly');
            const store = tx.objectStore(storeName);
            const req = store.get(id);
            return new Promise((resolve, reject) => {
                req.onsuccess = () => resolve(req.result);
                req.onerror = (e) => reject(e.target.error);
            });
        } catch (err) {
            console.error('Failed to get local audio backup:', err);
        }
    }

    async function _updateAudioBackupStatus(id, status) {
        try {
            const db = await _openAudioDB();
            const tx = db.transaction(storeName, 'readwrite');
            const store = tx.objectStore(storeName);
            const req = store.get(id);
            req.onsuccess = () => {
                const record = req.result;
                if (record) {
                    record.status = status;
                    store.put(record);
                }
            };
            return new Promise((resolve) => {
                tx.oncomplete = () => resolve();
            });
        } catch (err) {
            console.error('Failed to update local audio backup status:', err);
        }
    }

    async function _deleteAudioBackup(id) {
        try {
            const db = await _openAudioDB();
            const tx = db.transaction(storeName, 'readwrite');
            const store = tx.objectStore(storeName);
            store.delete(id);
            return new Promise((resolve) => {
                tx.oncomplete = () => resolve();
            });
        } catch (err) {
            console.error('Failed to delete local audio backup:', err);
        }
    }

    async function _listAudioBackups() {
        try {
            const db = await _openAudioDB();
            const tx = db.transaction(storeName, 'readonly');
            const store = tx.objectStore(storeName);
            const req = store.getAll();
            return new Promise((resolve, reject) => {
                req.onsuccess = () => resolve(req.result || []);
                req.onerror = (e) => reject(e.target.error);
            });
        } catch (err) {
            console.error('Failed to list local audio backups:', err);
            return [];
        }
    }

    async function _cleanupOldAudioBackups() {
        try {
            const backups = await _listAudioBackups();
            const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000; // 7 days
            for (const b of backups) {
                if (b.timestamp < cutoff || b.status === 'uploaded') {
                    await _deleteAudioBackup(b.id);
                }
            }
        } catch (e) {
            console.error('Failed to cleanup old audio backups:', e);
        }
    }

    async function _renderLocalAudioBackups() {
        const container = document.getElementById('local-audio-backups-container');
        if (!container) return;

        const backups = await _listAudioBackups();
        const pending = backups.filter(b => b.status !== 'uploaded');

        if (pending.length === 0) {
            container.style.display = 'none';
            container.innerHTML = '';
            return;
        }

        container.style.display = 'block';
        container.innerHTML = '<div style="font-weight:bold;margin-bottom:5px;border-bottom:1px solid var(--border-color,#ddd);padding-bottom:3px;display:flex;justify-content:space-between;align-items:center;">' +
            '<span>⚠️ Unsent Voice Recordings (' + pending.length + ')</span>' +
            '<button id="close-backups-btn" style="background:none;border:none;cursor:pointer;font-size:1.1em;padding:0;color:var(--text-muted-color,#888);">×</button>' +
            '</div>';

        // Add close button listener
        container.querySelector('#close-backups-btn').addEventListener('click', () => {
            container.style.display = 'none';
        });

        const listDiv = document.createElement('div');
        listDiv.style.cssText = 'max-height:120px;overflow-y:auto;display:flex;flex-direction:column;gap:4px;';

        pending.forEach(b => {
            const item = document.createElement('div');
            item.style.cssText = 'display:flex;align-items:center;justify-content:space-between;gap:6px;padding:3px;background:var(--table-header-bg,#f9f9f9);border-radius:3px;border:1px solid var(--border-color,#eee);';

            const dateStr = new Date(b.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) + ' (' + b.elapsed + ')';
            
            const info = document.createElement('span');
            info.style.cssText = 'white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:1;font-size:0.9em;';
            info.textContent = dateStr;
            item.appendChild(info);

            const btnGroup = document.createElement('div');
            btnGroup.style.cssText = 'display:flex;gap:3px;';

            // Retry button
            const retryBtn = document.createElement('button');
            retryBtn.textContent = 'Retry';
            retryBtn.title = 'Retry upload and transcription';
            retryBtn.style.cssText = 'padding:2px 5px;font-size:0.8em;cursor:pointer;background:#0077cc;color:#fff;border:none;border-radius:3px;';
            retryBtn.addEventListener('click', async () => {
                retryBtn.disabled = true;
                retryBtn.textContent = '...';
                _transcribeAudioFile(b.blob, b.id);
            });
            btnGroup.appendChild(retryBtn);

            // Download/Save button
            const dlBtn = document.createElement('button');
            dlBtn.textContent = 'Save';
            dlBtn.title = 'Download raw audio file to your device';
            dlBtn.style.cssText = 'padding:2px 5px;font-size:0.8em;cursor:pointer;background:#28a745;color:#fff;border:none;border-radius:3px;';
            dlBtn.addEventListener('click', () => {
                const url = URL.createObjectURL(b.blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = b.fileName;
                document.body.appendChild(a);
                a.click();
                document.body.removeChild(a);
                URL.revokeObjectURL(url);
            });
            btnGroup.appendChild(dlBtn);

            // Delete button
            const delBtn = document.createElement('button');
            delBtn.textContent = 'Delete';
            delBtn.title = 'Remove local backup';
            delBtn.style.cssText = 'padding:2px 5px;font-size:0.8em;cursor:pointer;background:#dc3545;color:#fff;border:none;border-radius:3px;';
            delBtn.addEventListener('click', async () => {
                if (confirm('Delete this local recording?')) {
                    await _deleteAudioBackup(b.id);
                    _renderLocalAudioBackups();
                }
            });
            btnGroup.appendChild(delBtn);

            item.appendChild(btnGroup);
            listDiv.appendChild(item);
        });

        container.appendChild(listDiv);
    }

    // ── _transcribeAudioFile ───────────────────────────────────────────────────
    // Upload an audio File object to /ai/transcribe, show progress, and on success
    // populate the chat input with the transcript so the user can review + send.
    function _transcribeAudioFile(file, backupId) {
        var statusEl  = document.getElementById('audio-transcribe-status');
        var inputEl   = document.getElementById('message-input');
        var sendBtn   = document.getElementById('send-message');

        if (!file) return;

        var sizeMB = (file.size / 1048576).toFixed(1);
        if (statusEl) { statusEl.textContent = '⏳ Uploading ' + (file.name || 'recording') + ' (' + sizeMB + ' MB)…'; statusEl.style.display = ''; }
        if (sendBtn) sendBtn.disabled = true;

        var formData = new FormData();
        formData.append('audio', file, file.name || 'recording.webm');
        formData.append('diarize', '1');
        formData.append('num_speakers', '2');

        function _handleTranscriptResult(data) {
            if (sendBtn) sendBtn.disabled = false;
            if (!data.success) {
                if (statusEl) { statusEl.textContent = '⚠️ Transcription failed: ' + (data.error || 'unknown error'); }
                if (backupId) {
                    _updateAudioBackupStatus(backupId, 'failed').then(_renderLocalAudioBackups);
                }
                return;
            }
            var transcript = (data.transcript || '').trim();
            if (!transcript) {
                if (statusEl) { statusEl.textContent = '⚠️ Empty transcript returned.'; }
                if (backupId) {
                    _updateAudioBackupStatus(backupId, 'failed').then(_renderLocalAudioBackups);
                }
                return;
            }
            if (data.audio_file_id)      { state.lastAudioFileId      = data.audio_file_id; }
            if (data.transcript_file_id) { state.lastTranscriptFileId = data.transcript_file_id; }
            if (data.segments && data.segments.length) { state.lastSegments = data.segments; }

            var displayText = transcript;
            if (data.diarized && data.segments && data.segments.length) {
                var lines = [];
                var lastSpeaker = null;
                data.segments.forEach(function(seg) {
                    var spk = seg.speaker || 'SPEAKER_0';
                    var label = spk === 'SPEAKER_0' ? 'Instructor' : spk === 'SPEAKER_1' ? 'Student' : spk;
                    var mins = Math.floor((seg.start || 0) / 60);
                    var secs = Math.round((seg.start || 0) % 60);
                    var ts = '[' + mins + ':' + (secs < 10 ? '0' : '') + secs + ']';
                    if (spk !== lastSpeaker) {
                        lines.push('\n' + label + ' ' + ts + ': ' + (seg.text || '').trim());
                        lastSpeaker = spk;
                    } else {
                        lines.push((seg.text || '').trim());
                    }
                });
                displayText = lines.join(' ').trim();
            }

            if (inputEl) {
                inputEl.value = displayText;
                inputEl.style.height = 'auto';
                inputEl.style.height = Math.min(inputEl.scrollHeight, 200) + 'px';
                inputEl.style.overflowY = inputEl.scrollHeight > 200 ? 'auto' : 'hidden';
                inputEl.dispatchEvent(new Event('input', { bubbles: true }));
                inputEl.focus();
            }
            var diarizedNote = data.diarized ? ' (speakers separated)' : '';
            if (statusEl) {
                statusEl.textContent = '✅ Transcript ready (model: ' + (data.model_used || 'base') + diarizedNote + ') — review and press Send';
                setTimeout(function() { if (statusEl) statusEl.style.display = 'none'; }, 10000);
            }
            addMessage('🎤 Voice transcript received (' + (data.model_used || 'base') + diarizedNote + ')', 'system-message');

            if (backupId) {
                _deleteAudioBackup(backupId).then(_renderLocalAudioBackups);
            }
        }

        function _pollTranscribeStatus(jobId, attempt) {
            attempt = attempt || 0;
            if (attempt > 120) {
                if (sendBtn) sendBtn.disabled = false;
                if (statusEl) { statusEl.textContent = '⚠️ Transcription timed out after 10 minutes. Try a shorter recording.'; }
                if (backupId) {
                    _updateAudioBackupStatus(backupId, 'failed').then(_renderLocalAudioBackups);
                }
                return;
            }
            var elapsed = Math.round(attempt * 5);
            if (statusEl) { statusEl.textContent = '⏳ Transcribing… (' + elapsed + 's elapsed, checking every 5s)'; }
            setTimeout(function() {
                fetch('/ai/transcribe_status?job_id=' + encodeURIComponent(jobId), {
                    credentials: 'include'
                })
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    if (data.status === 'processing') {
                        _pollTranscribeStatus(jobId, attempt + 1);
                    } else {
                        _handleTranscriptResult(data);
                    }
                })
                .catch(function() {
                    _pollTranscribeStatus(jobId, attempt + 1);
                });
            }, 5000);
        }

        fetch('/ai/transcribe', {
            method: 'POST',
            credentials: 'include',
            body: formData
        })
        .then(function(r) {
            if (!r.ok && r.status === 403) throw new Error('Login required — please sign in to use voice transcription.');
            if (!r.ok && r.status === 503) throw new Error('Whisper not installed on server. Run: pip install openai-whisper in Comserv/whisper_venv');
            return r.text().then(function(txt) {
                try { return JSON.parse(txt); }
                catch(e) { throw new Error('Server returned unexpected response (HTTP ' + r.status + '). The server may be restarting — please try again in a moment.'); }
            });
        })
        .then(function(data) {
            if (!data.success) {
                if (sendBtn) sendBtn.disabled = false;
                if (statusEl) { statusEl.textContent = '⚠️ Transcription failed: ' + (data.error || 'unknown error'); }
                if (backupId) {
                    _updateAudioBackupStatus(backupId, 'failed').then(_renderLocalAudioBackups);
                }
                return;
            }
            if (data.job_id) {
                if (statusEl) { statusEl.textContent = '⏳ Transcription started (job ' + data.job_id + ') — checking progress…'; }
                _pollTranscribeStatus(data.job_id, 1);
            } else {
                _handleTranscriptResult(data);
            }
        })
        .catch(function(err) {
            if (sendBtn) sendBtn.disabled = false;
            if (statusEl) { statusEl.textContent = '⚠️ Upload failed: ' + err.message; }
            if (backupId) {
                _updateAudioBackupStatus(backupId, 'failed').then(_renderLocalAudioBackups);
            }
        });
    }

    function _makeWizardForm(fields, onConfirm) {
        var form = document.createElement('form');
        form.onsubmit = function(e) { e.preventDefault(); onConfirm(form); };
        fields.forEach(function(f) {
            var row = document.createElement('div');
            row.style.cssText = 'margin:4px 0;display:flex;gap:6px;align-items:center;';
            var label = document.createElement('label');
            label.textContent = f.label;
            label.style.cssText = 'width:160px;font-size:12px;color:var(--text-color,#555);flex-shrink:0;';
            var input = document.createElement('input');
            input.name = f.name;
            input.value = f.value !== undefined ? f.value : '';
            input.type = f.type || 'text';
            input.style.cssText = 'flex:1;padding:4px 6px;border:1px solid var(--button-border,#ccc);border-radius:4px;font-size:13px;background:var(--background-color,#fff);color:var(--text-color,#222);';
            if (f.required) input.required = true;
            row.appendChild(label);
            row.appendChild(input);
            form.appendChild(row);
        });
        return form;
    }

    function _postWizardAction(actionName, params, msgEl) {
        msgEl.textContent = '⏳ Saving…';
        fetch('/ai/action', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: actionName, params: params })
        })
        .then(function(r) { return r.json(); })
        .then(function(result) {
            if (result.success) {
                msgEl.innerHTML = '✅ ' + (result.message || 'Saved') +
                    (result.url ? ' <a href="' + result.url + '" target="_blank" style="color:#0077cc;font-weight:bold;">View →</a>' : '');
            } else {
                msgEl.textContent = '⚠️ ' + (result.error || 'Save failed');
            }
        })
        .catch(function(e) { msgEl.textContent = '⚠️ Request failed: ' + e.message; });
    }

    function _openSimpleWizard(title, fields, actionName, extraParams) {
        var chatMessages = document.getElementById('chat-messages');
        if (!chatMessages) return;
        var id = 'ai-' + actionName + '-wizard';
        var existing = document.getElementById(id);
        if (existing) existing.remove();

        var wrapper = document.createElement('div');
        wrapper.id = id;
        wrapper.className = 'msg-wrapper msg-wrapper-ai';
        wrapper.style.cssText = 'margin:8px 0;';

        var card = document.createElement('div');
        card.className = 'message system-message';
        card.style.cssText = 'background:var(--table-header-bg,#f9f9f9);border:1px solid var(--border-color,#ddd);border-radius:8px;padding:12px;max-width:520px;color:var(--text-color,#222);';

        var heading = document.createElement('div');
        heading.textContent = title;
        heading.style.cssText = 'font-weight:bold;font-size:14px;margin-bottom:8px;';
        card.appendChild(heading);

        var msgEl = document.createElement('div');
        msgEl.style.cssText = 'font-size:12px;color:#666;margin-top:6px;';

        var form = _makeWizardForm(fields, function(f) {
            var params = Object.assign({}, extraParams || {}, { wizard_confirmed: 1 });
            fields.forEach(function(fd) {
                var inp = f.elements[fd.name];
                if (inp) params[fd.name] = inp.value;
            });
            _postWizardAction(actionName, params, msgEl);
        });
        card.appendChild(form);

        var btnRow = document.createElement('div');
        btnRow.style.cssText = 'margin-top:8px;display:flex;gap:8px;';
        var saveBtn = document.createElement('button');
        saveBtn.textContent = 'Save';
        saveBtn.type = 'submit';
        saveBtn.style.cssText = 'background:var(--button-bg,#f2f2f2);color:var(--button-text,#000);border:1px solid var(--button-border,#ccc);border-radius:4px;padding:6px 16px;cursor:pointer;font-size:13px;';
        saveBtn.onclick = function() { form.requestSubmit ? form.requestSubmit() : form.submit(); };
        var cancelBtn = document.createElement('button');
        cancelBtn.textContent = 'Cancel';
        cancelBtn.type = 'button';
        cancelBtn.style.cssText = 'background:var(--button-bg,#f2f2f2);color:var(--button-text,#000);border:1px solid var(--button-border,#ccc);border-radius:4px;padding:6px 12px;cursor:pointer;font-size:13px;';
        cancelBtn.onclick = function() { wrapper.remove(); };
        btnRow.appendChild(saveBtn);
        btnRow.appendChild(cancelBtn);
        card.appendChild(btnRow);
        card.appendChild(msgEl);
        wrapper.appendChild(card);
        chatMessages.appendChild(wrapper);
        chatMessages.scrollTop = chatMessages.scrollHeight;
    }

    function openYardWizard(prefill) {
        _openSimpleWizard('🏡 Create Yard', [
            { name: 'yard_name',       label: 'Yard Name *',      value: prefill.yard_name  || '', required: true },
            { name: 'yard_code',       label: 'Yard Code *',      value: prefill.yard_code  || '', required: true },
            { name: 'yard_size',       label: 'Capacity (hives)', value: prefill.yard_size  || 10, type: 'number' },
            { name: 'total_yard_size', label: 'Total Size (hives)',value: prefill.total_yard_size || 10, type: 'number' },
            { name: 'notes',           label: 'Notes',            value: prefill.notes      || '' },
        ], 'create_yard', {});
    }

    function openHiveWizard(prefill) {
        _openSimpleWizard('🐝 Register Hive', [
            { name: 'hive_number', label: 'Hive Number *', value: prefill.hive_number || '', required: true },
            { name: 'yard_id',     label: 'Yard ID *',     value: prefill.yard_id    || '', required: true, type: 'number' },
            { name: 'queen_code',  label: 'Queen Code',    value: prefill.queen_code || '' },
            { name: 'notes',       label: 'Notes',         value: prefill.notes      || '' },
        ], 'create_hive', {});
    }

    function openQueenWizard(prefill) {
        _openSimpleWizard('👑 Record Queen', [
            { name: 'tag_number',    label: 'Tag / Number',   value: prefill.tag_number    || '' },
            { name: 'color_marking', label: 'Colour Marking', value: prefill.color_marking || '' },
            { name: 'birth_date',    label: 'Birth Date',     value: prefill.birth_date    || '', type: 'date' },
            { name: 'breed',         label: 'Breed',          value: prefill.breed         || 'unknown' },
            { name: 'mating_status', label: 'Mating Status',  value: prefill.mating_status || 'mated' },
            { name: 'health_status', label: 'Health Status',  value: prefill.health_status || 'healthy' },
            { name: 'notes',         label: 'Notes',          value: prefill.notes         || '' },
        ], 'create_queen', { hive_id: prefill.hive_id || undefined });
    }

    // ── openInspectionWizard ───────────────────────────────────────────────────
    // Renders an inline inspection review form pre-filled with AI-extracted data.
    // User can edit all fields before confirming; on confirm sends create_inspection.
    function openInspectionWizard(prefill) {
        var chatMessages = document.getElementById('chat-messages');
        if (!chatMessages) return;

        var existing = document.getElementById('ai-inspection-wizard');
        if (existing) existing.remove();

        var wrapper = document.createElement('div');
        wrapper.className = 'msg-wrapper msg-wrapper-ai';
        wrapper.id = 'ai-inspection-wizard';

        var lbl = document.createElement('div');
        lbl.className = 'msg-label';
        lbl.textContent = 'Hive Inspection Review';

        var box = document.createElement('div');
        box.className = 'message system-message';
        box.style.cssText = 'padding:12px;max-width:520px;font-size:0.88em;';

        var p = prefill || {};
        var qs_yes = p.queen_seen        ? 'checked' : '';
        var qm_yes = p.queen_marked      ? 'checked' : '';
        var eg_yes = p.eggs_seen         ? 'checked' : '';
        var lv_yes = p.larvae_seen       ? 'checked' : '';
        var cb_yes = p.capped_brood_seen ? 'checked' : '';
        var fd_yes = p.feeding_done      ? 'checked' : '';
        var today  = new Date().toISOString().slice(0, 10);

        var popOpts = ['', 'very_strong', 'strong', 'moderate', 'weak', 'very_weak'].map(function(v) {
            var sel = (p.population_estimate || '') === v ? ' selected' : '';
            var lbl2 = v ? v.replace(/_/g, ' ') : '— select —';
            return '<option value="' + v + '"' + sel + '>' + lbl2 + '</option>';
        }).join('');
        var tempOpts = ['calm', 'moderate', 'aggressive', 'very_aggressive'].map(function(v) {
            var sel = (p.temperament || 'calm') === v ? ' selected' : '';
            return '<option value="' + v + '"' + sel + '>' + v.replace(/_/g, ' ') + '</option>';
        }).join('');
        var statusOpts = ['excellent', 'good', 'fair', 'poor', 'critical'].map(function(v) {
            var sel = (p.overall_status || 'good') === v ? ' selected' : '';
            return '<option value="' + v + '"' + sel + '>' + v + '</option>';
        }).join('');

        var inpStyle = 'width:100%;box-sizing:border-box;padding:3px 5px;border:1px solid var(--button-border,#ccc);border-radius:3px;background:var(--background-color,#fff);color:var(--text-color,#222);';
        var selStyle = 'width:100%;padding:3px;border:1px solid var(--button-border,#ccc);border-radius:3px;background:var(--background-color,#fff);color:var(--text-color,#222);';
        var lblStyle = 'font-weight:600;display:block;font-size:0.85em;color:var(--text-color,#333);';

        box.innerHTML =
            '<strong style="font-size:1.05em;color:var(--text-color,#222)">🐝 Review Hive Inspection</strong>' +
            '<p style="margin:4px 0 8px;color:var(--text-color,#555);font-size:0.9em">Review AI-extracted data below, edit any fields, then click Save.</p>' +
            '<form id="ai-insp-form" style="display:flex;flex-direction:column;gap:5px;">' +
                '<div style="display:grid;grid-template-columns:1fr 1fr;gap:5px;">' +
                    '<div><label style="' + lblStyle + '">Hive ID *</label><input name="hive_id" type="number" required value="' + (p.hive_id || '') + '" style="' + inpStyle + '"></div>' +
                    '<div><label style="' + lblStyle + '">Date *</label><input name="inspection_date" type="date" required value="' + (p.inspection_date || today) + '" style="' + inpStyle + '"></div>' +
                    '<div><label style="' + lblStyle + '">Population</label><select name="population_estimate" style="' + selStyle + '">' + popOpts + '</select></div>' +
                    '<div><label style="' + lblStyle + '">Temperament</label><select name="temperament" style="' + selStyle + '">' + tempOpts + '</select></div>' +
                    '<div><label style="' + lblStyle + '">Overall Status</label><select name="overall_status" style="' + selStyle + '">' + statusOpts + '</select></div>' +
                    '<div><label style="' + lblStyle + '">Weather</label><input name="weather_conditions" type="text" value="' + (p.weather_conditions || '') + '" placeholder="sunny, cloudy…" style="' + inpStyle + '"></div>' +
                    '<div><label style="' + lblStyle + '">Temperature (°C)</label><input name="temperature" type="number" step="0.5" value="' + (p.temperature != null ? p.temperature : '') + '" style="' + inpStyle + '"></div>' +
                    '<div><label style="' + lblStyle + '">Inspector</label><input name="inspector" type="text" value="' + (p.inspector || '') + '" style="' + inpStyle + '"></div>' +
                '</div>' +
                '<div style="display:flex;flex-wrap:wrap;gap:8px;margin:4px 0;color:var(--text-color,#333);">' +
                    '<label><input type="checkbox" name="queen_seen" ' + qs_yes + '> Queen seen</label>' +
                    '<label><input type="checkbox" name="queen_marked" ' + qm_yes + '> Queen marked</label>' +
                    '<label><input type="checkbox" name="eggs_seen" ' + eg_yes + '> Eggs</label>' +
                    '<label><input type="checkbox" name="larvae_seen" ' + lv_yes + '> Larvae</label>' +
                    '<label><input type="checkbox" name="capped_brood_seen" ' + cb_yes + '> Capped brood</label>' +
                    '<label><input type="checkbox" name="feeding_done" ' + fd_yes + '> Feeding done</label>' +
                '</div>' +
                '<div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:5px;">' +
                    '<div><label style="' + lblStyle + '">Swarm cells</label><input name="swarm_cells" type="number" min="0" value="' + (p.swarm_cells || 0) + '" style="' + inpStyle + '"></div>' +
                    '<div><label style="' + lblStyle + '">Queen cells</label><input name="queen_cells" type="number" min="0" value="' + (p.queen_cells || 0) + '" style="' + inpStyle + '"></div>' +
                    '<div><label style="' + lblStyle + '">Supersedure</label><input name="supersedure_cells" type="number" min="0" value="' + (p.supersedure_cells || 0) + '" style="' + inpStyle + '"></div>' +
                '</div>' +
                '<div><label style="' + lblStyle + '">General notes</label><textarea name="general_notes" rows="3" style="' + inpStyle + 'resize:vertical;">' + (p.general_notes || '') + '</textarea></div>' +
                '<div><label style="' + lblStyle + '">Action required</label><textarea name="action_required" rows="2" style="' + inpStyle + 'resize:vertical;">' + (p.action_required || '') + '</textarea></div>' +
                '<div><label style="' + lblStyle + '">Feed type</label><input name="feed_type" type="text" value="' + (p.feed_type || '') + '" placeholder="syrup, fondant…" style="' + inpStyle + '"></div>' +
                '<div><label style="' + lblStyle + '">Feed amount</label><input name="feed_amount" type="text" value="' + (p.feed_amount || '') + '" placeholder="1L, 500g…" style="' + inpStyle + '"></div>' +
                '<div id="ai-insp-status" style="display:none;font-style:italic;font-size:0.85em;color:var(--text-color,#555);"></div>' +
                '<div style="display:flex;gap:8px;margin-top:4px;">' +
                    '<button type="submit" style="padding:5px 14px;background:var(--button-bg,#0077cc);color:var(--button-text,#000);border:1px solid var(--button-border,#ccc);border-radius:4px;cursor:pointer;font-size:.88em">Save Inspection</button>' +
                    '<button type="button" id="ai-insp-cancel" style="padding:5px 10px;border:1px solid var(--button-border,#ccc);border-radius:4px;cursor:pointer;font-size:.88em;background:var(--button-bg,#f2f2f2);color:var(--button-text,#000)">Cancel</button>' +
                '</div>' +
            '</form>';

        wrapper.appendChild(lbl);
        wrapper.appendChild(box);
        chatMessages.appendChild(wrapper);
        chatMessages.scrollTop = chatMessages.scrollHeight;

        document.getElementById('ai-insp-cancel').addEventListener('click', function() {
            wrapper.remove();
        });

        document.getElementById('ai-insp-form').addEventListener('submit', function(e) {
            e.preventDefault();
            var fd = new FormData(e.target);
            var confirmed = { box_details: p.box_details || [] };
            fd.forEach(function(val, key) { confirmed[key] = val; });
            confirmed.queen_seen        = e.target.queen_seen.checked        ? 1 : 0;
            confirmed.queen_marked      = e.target.queen_marked.checked      ? 1 : 0;
            confirmed.eggs_seen         = e.target.eggs_seen.checked         ? 1 : 0;
            confirmed.larvae_seen       = e.target.larvae_seen.checked       ? 1 : 0;
            confirmed.capped_brood_seen = e.target.capped_brood_seen.checked ? 1 : 0;
            confirmed.feeding_done      = e.target.feeding_done.checked      ? 1 : 0;
            confirmed.swarm_cells       = parseInt(confirmed.swarm_cells, 10) || 0;
            confirmed.queen_cells       = parseInt(confirmed.queen_cells, 10) || 0;
            confirmed.supersedure_cells = parseInt(confirmed.supersedure_cells, 10) || 0;

            var statusDiv = document.getElementById('ai-insp-status');
            if (statusDiv) { statusDiv.textContent = 'Saving…'; statusDiv.style.display = ''; }
            e.target.querySelector('[type=submit]').disabled = true;

            executeAIAction({ action: 'create_inspection', params: confirmed });

            setTimeout(function() { wrapper.remove(); }, 1500);
        });
    }

    // Project creation wizard — renders an inline form in the chat window.
    // Submitted data is sent to /ai/action as a create_project ACTION.
    function openProjectWizard(prefillTitle) {
        const chatMessages = document.getElementById('chat-messages');
        if (!chatMessages) return;

        const existing = document.getElementById('ai-project-wizard');
        if (existing) existing.remove();

        const wrapper = document.createElement('div');
        wrapper.className = 'msg-wrapper msg-wrapper-ai';
        wrapper.id = 'ai-project-wizard';

        const lbl = document.createElement('div');
        lbl.className = 'msg-label';
        lbl.textContent = 'Planning Agent';

        const box = document.createElement('div');
        box.className = 'message system-message';
        box.style.cssText = 'padding:12px;max-width:480px;';

        const DEPS = [
            ['inventory',   'Inventory tracking'],
            ['billing',     'Billing / payments'],
            ['email',       'Email notifications'],
            ['calendar',    'Calendar / bookings'],
            ['helpdesk',    'HelpDesk / support'],
            ['api',         'External API'],
            ['schema',      'New DB tables needed'],
            ['ai',          'AI / Chat integration'],
        ];

        box.innerHTML =
            '<strong style="font-size:1.05em">📋 New Project Wizard</strong>' +
            '<form id="ai-wizard-form" style="margin-top:8px;display:flex;flex-direction:column;gap:6px;">' +
                '<label style="font-size:.85em;font-weight:600">Project name</label>' +
                '<input id="wiz-name" type="text" required style="padding:4px 6px;border:1px solid #ccc;border-radius:4px;" value="' + (prefillTitle || '').replace(/"/g, '&quot;') + '">' +
                '<label style="font-size:.85em;font-weight:600">Description</label>' +
                '<textarea id="wiz-desc" rows="2" style="padding:4px 6px;border:1px solid #ccc;border-radius:4px;resize:vertical;"></textarea>' +
                '<label style="font-size:.85em;font-weight:600">Due date</label>' +
                '<input id="wiz-due" type="date" style="padding:4px 6px;border:1px solid #ccc;border-radius:4px;">' +
                '<label style="font-size:.85em;font-weight:600">Dependencies needed (check all that apply)</label>' +
                '<div id="wiz-deps" style="display:flex;flex-wrap:wrap;gap:4px 12px;">' +
                    DEPS.map(function(d) {
                        return '<label style="font-size:.82em"><input type="checkbox" name="dep" value="' + d[0] + '" style="margin-right:3px">' + d[1] + '</label>';
                    }).join('') +
                '</div>' +
                '<div style="display:flex;gap:8px;margin-top:4px;">' +
                    '<button type="submit" style="padding:5px 14px;background:var(--button-bg,#f2f2f2);color:var(--button-text,#000);border:1px solid var(--button-border,#ccc);border-radius:4px;cursor:pointer;font-size:.85em">Create Project</button>' +
                    '<button type="button" id="wiz-cancel" style="padding:5px 10px;border:1px solid var(--button-border,#ccc);border-radius:4px;cursor:pointer;font-size:.85em;background:var(--button-bg,#f2f2f2);color:var(--button-text,#000)">Cancel</button>' +
                '</div>' +
            '</form>';

        wrapper.appendChild(lbl);
        wrapper.appendChild(box);
        chatMessages.appendChild(wrapper);
        chatMessages.scrollTop = chatMessages.scrollHeight;

        document.getElementById('wiz-cancel').addEventListener('click', function() {
            wrapper.remove();
        });

        document.getElementById('ai-wizard-form').addEventListener('submit', function(e) {
            e.preventDefault();
            var name = document.getElementById('wiz-name').value.trim();
            var desc = document.getElementById('wiz-desc').value.trim();
            var due  = document.getElementById('wiz-due').value;
            var deps = Array.from(document.querySelectorAll('#wiz-deps input:checked')).map(function(cb) { return cb.value; });

            if (!name) { alert('Project name is required.'); return; }

            var depNote = deps.length ? '\n\nDependencies: ' + deps.join(', ') : '';
            wrapper.remove();

            executeAIAction({
                action: 'create_project',
                params: {
                    name:        name,
                    description: desc + depNote,
                    due_date:    due || undefined,
                }
            });

            if (deps.length) {
                var depMsg = 'Project "' + name + '" was created. Dependencies noted: ' + deps.join(', ') + '. Please create the relevant sub-project todos and blocking dependencies.';
                var chatInput = document.getElementById('chat-input') || document.getElementById('chat-message');
                if (chatInput) {
                    chatInput.value = depMsg;
                    var sendBtn = document.getElementById('send-button') || document.querySelector('[data-action="send"]');
                    if (sendBtn) sendBtn.click();
                }
            }
        });
    }

    // POST an action object to /ai/action and show a confirmation bubble.
    function executeAIAction(actionObj) {
        const chatMessages = document.getElementById('chat-messages');

        // fill_form is handled entirely client-side — no server round-trip needed.
        if (actionObj.action === 'fill_form') {
            _executeFillForm(actionObj);
            return;
        }

        // navigate: open a URL in a new tab without any pre-fill
        if (actionObj.action === 'navigate') {
            const navUrl = actionObj.url || (actionObj.params && actionObj.params.url);
            if (navUrl) {
                const abs = navUrl.startsWith('http') ? navUrl : (window.location.origin + (navUrl.startsWith('/') ? navUrl : '/' + navUrl));
                const _navSi = document.getElementById('chat-status');
                if (_navSi) { _navSi.textContent = '\uD83D\uDD17 Opening: ' + navUrl; _navSi.className = 'chat-status connected'; }
                if (window.AI_WIDGET_POPUP && window.opener && !window.opener.closed) {
                    window.opener.location.href = abs;
                } else {
                    window.location.href = abs;
                }
                const wrapper = document.createElement('div');
                wrapper.className = 'msg-wrapper msg-wrapper-ai';
                const lbl = document.createElement('div');
                lbl.className = 'msg-label';
                lbl.textContent = 'System';
                const el = document.createElement('div');
                el.className = 'message system-message';
                el.innerHTML = '\uD83D\uDD17 Navigating to: <a href="' + abs + '">' + navUrl + '</a>';
                wrapper.appendChild(lbl);
                wrapper.appendChild(el);
                chatMessages.appendChild(wrapper);
                chatMessages.scrollTop = chatMessages.scrollHeight;
            }
            return;
        }

        // navigate_and_fill: store field values in localStorage then open the target page.
        // The widget init on the target page checks for a pending fill and applies it.
        if (actionObj.action === 'navigate_and_fill') {
            const nfUrl    = actionObj.url    || (actionObj.params && actionObj.params.url);
            const nfFields = actionObj.fields || (actionObj.params && actionObj.params.fields) || {};
            if (nfUrl) {
                const abs = nfUrl.startsWith('http') ? nfUrl : (window.location.origin + (nfUrl.startsWith('/') ? nfUrl : '/' + nfUrl));
                try {
                    localStorage.setItem('ai_pending_fill', JSON.stringify({
                        url:     nfUrl,
                        fields:  nfFields,
                        ts:      Date.now()
                    }));
                } catch(e) { console.warn('localStorage write failed', e); }
                if (window.AI_WIDGET_POPUP && window.opener && !window.opener.closed) {
                    window.opener.location.href = abs;
                } else {
                    window.location.href = abs;
                }
                const wrapper = document.createElement('div');
                wrapper.className = 'msg-wrapper msg-wrapper-ai';
                const lbl = document.createElement('div');
                lbl.className = 'msg-label';
                lbl.textContent = 'System';
                const el = document.createElement('div');
                el.className = 'message system-message';
                const fieldCount = Object.keys(nfFields).length;
                el.innerHTML = '🔗 Navigating to: <a href="' + abs + '">' + nfUrl + '</a>'
                    + (fieldCount ? ' — <em>' + fieldCount + ' field(s) will be pre-filled when the page loads.</em>' : '');
                wrapper.appendChild(lbl);
                wrapper.appendChild(el);
                chatMessages.appendChild(wrapper);
                chatMessages.scrollTop = chatMessages.scrollHeight;
            }
            return;
        }

        fetch('/ai/action', {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(actionObj)
        })
        .then(function(r) { return r.json(); })
        .then(function(result) {
            if (!result) {
                throw new Error('Action server returned an empty response');
            }
            if (result.success && result.action === 'open_project_wizard') {
                openProjectWizard(result.wizard_title || '');
                return;
            }
            if (result.action === 'open_inspection_wizard' || (actionObj.action === 'create_inspection' && result.wizard_prefill)) {
                var prefill = result.wizard_prefill || actionObj.params || {};
                if (state.lastAudioFileId)      { prefill.audio_file_id      = state.lastAudioFileId; }
                if (state.lastTranscriptFileId) { prefill.transcript_file_id = state.lastTranscriptFileId; }
                openInspectionWizard(prefill);
                return;
            }
            if (result.action === 'open_yard_wizard') {
                openYardWizard(result.wizard_prefill || {});
                return;
            }
            if (result.action === 'open_hive_wizard') {
                openHiveWizard(result.wizard_prefill || {});
                return;
            }
            if (result.action === 'open_queen_wizard') {
                openQueenWizard(result.wizard_prefill || {});
                return;
            }
            const wrapper = document.createElement('div');
            wrapper.className = 'msg-wrapper msg-wrapper-ai';
            const lbl = document.createElement('div');
            lbl.className = 'msg-label';
            lbl.textContent = 'System';
            const el = document.createElement('div');
            el.className = 'message system-message';
            if (result.success && result.inspection_id) {
                el.innerHTML = '✅ ' + (result.message || 'Inspection saved') +
                    ' <a href="' + (result.url || '/BMaster') + '" target="_blank" style="color:#0077cc;font-weight:bold;">View inspection →</a>';
            } else {
                el.textContent = result.success
                    ? '✅ ' + (result.message || 'Action completed')
                    : '⚠️ Action failed: ' + (result.error || 'unknown error');
            }
            wrapper.appendChild(lbl);
            wrapper.appendChild(el);
            chatMessages.appendChild(wrapper);
            chatMessages.scrollTop = chatMessages.scrollHeight;
        })
        .catch(function(err) {
            console.error('AI action error:', err);
            const wrapper = document.createElement('div');
            wrapper.className = 'msg-wrapper msg-wrapper-ai';
            const lbl = document.createElement('div');
            lbl.className = 'msg-label';
            lbl.textContent = 'System';
            const el = document.createElement('div');
            el.className = 'message error-message';
            el.textContent = '⚠️ Action request failed: ' + err.message;
            wrapper.appendChild(lbl);
            wrapper.appendChild(el);
            chatMessages.appendChild(wrapper);
            chatMessages.scrollTop = chatMessages.scrollHeight;
        });
    }

    function addMessage(text, className, isHtml) {
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
        if (isHtml) {
            messageElement.innerHTML = text;
        } else if (className === 'ai-message' && window.AIUtils && AIUtils.formatMessageContent) {
            messageElement.innerHTML = AIUtils.formatMessageContent(text);
        } else {
            messageElement.textContent = text;
        }

        wrapper.appendChild(label);
        wrapper.appendChild(messageElement);
        chatMessages.appendChild(wrapper);
        chatMessages.scrollTop = chatMessages.scrollHeight;
    }
    
    // ── PAGE MODE ─────────────────────────────────────────────────────────────
    // Reads the model/provider selection from the /ai page dropdown.
    function _applyPageModelSelection() {
        const modelSelectEl = document.getElementById('model-select');
        if (!modelSelectEl || !modelSelectEl.value) return;
        const val = modelSelectEl.value;
        const opt = modelSelectEl.options[modelSelectEl.selectedIndex];
        const provider = (opt && opt.dataset.provider) || 'ollama';
        if (provider === 'grok' || val.startsWith('grok')) {
            state.selectedProvider = 'grok|' + val;
        } else {
            state.selectedProvider = 'ollama|' + val;
        }
        state.userModelOverride = true;
    }

    // Initialize local-chat.js in "page mode" — binds to existing /ai DOM elements
    // instead of creating a floating widget.
    function initPageMode() {
        const form     = document.getElementById('chat-form');
        const input    = document.getElementById('user-input');
        const messages = document.getElementById('chat-messages');
        const sendBtn  = document.getElementById('send-button');

        if (!form || !input || !messages) {
            console.error('[AI] Page mode: required DOM elements missing (#chat-form, #user-input, #chat-messages)');
            return;
        }

        // Apply user config injected by the template
        if (window.AI_CHAT_USER_CONFIG) {
            const cfg = window.AI_CHAT_USER_CONFIG;
            if (cfg.username) state.username = cfg.username;
            if (cfg.isGuest  !== undefined) state.isGuest  = !!cfg.isGuest;
            if (cfg.isAdmin  !== undefined) state.isAdmin  = !!cfg.isAdmin;
            if (cfg.siteName) state.siteName = cfg.siteName;
        }

        // If this /ai page was opened by detaching the widget, honour the original
        // page path and title so the same agent context is used.
        try {
            const urlParams = new URLSearchParams(window.location.search);
            const fromPath  = urlParams.get('from_path');
            const fromTitle = urlParams.get('from_title');
            if (fromPath) {
                state.detachedFromPath  = fromPath;
                state.detachedFromTitle = fromTitle || '';
                console.debug('[AI] Page mode: detached from', fromPath);
            }
        } catch(e) {}

        // When opened via task_id=N, store the todo details so every chat request
        // sends page_path=/todo/details?record_id=N which triggers single-todo context injection.
        if (window.AI_TASK_CONTEXT && window.AI_TASK_CONTEXT.record_id) {
            var tc = window.AI_TASK_CONTEXT;
            state.taskContext = tc;
            // Override page path so server-side _get_module_data uses single-todo fast-path
            state.taskPagePath = '/todo/details?record_id=' + tc.record_id;
            console.debug('[AI] Task context loaded: todo #' + tc.record_id, tc.subject);
        }

        // Restore messages saved from prior navigation, load persisted conversation ID
        restoreMessages();
        loadPersistedState();

        // Initialize agent context and user providers
        loadAgentsConfig().then(function() {
            state.pageContext = detectPageContext();
            // Override page_path so single-todo context injection triggers for task_id links
            if (state.taskPagePath) {
                state.pageContext.page_path = state.taskPagePath;
            }
            // Auto-select agent based on task subject keywords (same logic as todo/details pages)
            if (window.AI_TASK_CONTEXT && state.agentsConfig && state.agentsConfig.agents) {
                var subj = (window.AI_TASK_CONTEXT.subject || '').toUpperCase();
                var agents = state.agentsConfig.agents;
                var picked = null;
                if (/\bENCY\b|HERB|BOTANICAL|CONSTITUENT|PLANT\b/.test(subj) && agents.ency)      picked = agents.ency;
                else if (/\bBEEMASTER\b|\bBMASTER\b|HIVE|APIARY|VARROA|QUEEN\b|INSPECTION/.test(subj) && agents.beemaster) picked = agents.beemaster;
                else if (/\bINVENTORY\b|STOCK\b|\bSKU\b|\bBOM\b/.test(subj) && agents.inventory) picked = agents.inventory;
                else if (/\bHELPDESK\b|SUPPORT\b|TICKET\b/.test(subj) && agents.helpdesk)        picked = agents.helpdesk;
                else if (agents.planning) picked = agents.planning;
                if (picked) {
                    state.currentAgent = picked;
                    console.debug('[AI] Task-context agent selected:', picked.id);
                }
            }
        }).catch(function() {
            state.pageContext = detectPageContext();
            if (state.taskPagePath) {
                state.pageContext.page_path = state.taskPagePath;
            }
        });
        loadUserProviders().catch(function() {});

        // Read model selection from page dropdown when it changes
        const modelSelectEl = document.getElementById('model-select');
        if (modelSelectEl) {
            modelSelectEl.addEventListener('change', _applyPageModelSelection);
            _applyPageModelSelection();
        }

        // Submit: Nav intercept → AI query (same logic as widget's sendMessage)
        form.addEventListener('submit', function(e) {
            e.preventDefault();
            const prompt = input.value.trim();
            if (!prompt) return;

            if (!state.pageContext) {
                state.pageContext = detectPageContext();
                if (state.taskPagePath) state.pageContext.page_path = state.taskPagePath;
            }

            // Client-side navigation interception
            // Skip for ENCY agent nav — handled by fast path inside sendAIRequest
            const _pmAgentId = (state.pageContext && state.pageContext.agent_id) || '';
            const _pmIsEncyNav = (_pmAgentId === 'ency' || (state.pageContext && (state.pageContext.page_path || '').startsWith('/ENCY')))
                && /\b(HERB|HERBS|PLANT|PLANTS|BOTANICAL|CONSTIT|GLOSSARY|DISEASE|SYMPTOM|FORMULA|RECIPE|INSECT|ANIMAL|POLLINATOR|FORAGE|BEE)\b/i.test(prompt);
            const navMatch = !_pmIsEncyNav && prompt.match(NAV_RE);
            if (navMatch) {
                const matches = resolveNavIntent(prompt);
                if (matches && matches.length === 1) {
                    addMessage(prompt, 'user-message');
                    input.value = '';
                    persistMessages();
                    addMessage('Navigating to [' + matches[0].label + '](' + matches[0].url + ')', 'ai-message');
                    persistMessages();
                    setTimeout(function() {
                        if (window.AI_WIDGET_POPUP && window.opener && !window.opener.closed) {
                            window.opener.location.href = matches[0].url;
                        } else {
                            window.location.href = matches[0].url;
                        }
                    }, 600);
                    return;
                } else if (matches && matches.length > 1) {
                    addMessage(prompt, 'user-message');
                    input.value = '';
                    persistMessages();
                    const listMsg = 'Multiple pages match — which did you mean?\n'
                        + matches.slice(0, 8).map(function(m) { return '- [' + m.label + '](' + m.url + ')'; }).join('\n');
                    addMessage(listMsg, 'ai-message');
                    persistMessages();
                    return;
                }
            }

            addMessage(prompt, 'user-message');
            input.value = '';
            input.style.height = 'auto';
            persistMessages();

            // Show send button loading state
            if (sendBtn) {
                sendBtn.disabled = true;
                const sp = sendBtn.querySelector('.button-spinner');
                const tx = sendBtn.querySelector('.button-text');
                if (sp) sp.style.display = 'inline';
                if (tx) tx.style.display = 'none';
            }

            queryAI(prompt);

            // Reset button after a short delay (queryAI is async, no promise returned)
            // The actual reset is done inside sendAIRequest's finally-equivalent
        });

        // Reset send button when response arrives — watch for loading message removal
        // by observing the chat area for new non-loading messages
        (function watchSendBtn() {
            const obs = new MutationObserver(function(muts) {
                muts.forEach(function(m) {
                    m.addedNodes.forEach(function(n) {
                        if (n.classList && (n.classList.contains('msg-wrapper') || n.classList.contains('ai-thinking'))) {
                            if (sendBtn) {
                                sendBtn.disabled = false;
                                const sp = sendBtn.querySelector('.button-spinner');
                                const tx = sendBtn.querySelector('.button-text');
                                if (sp) sp.style.display = 'none';
                                if (tx) tx.style.display = 'inline';
                            }
                        }
                    });
                });
            });
            obs.observe(messages, { childList: true });
        })();

        // Enter to submit (Shift+Enter = new line)
        input.addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                form.dispatchEvent(new Event('submit'));
            }
        });

        // Auto-resize textarea
        input.addEventListener('input', function() {
            this.style.height = 'auto';
            this.style.height = this.scrollHeight + 'px';
        });

        // Clear/new-chat button (✏️)
        const clearBtn = document.getElementById('clear-chat');
        if (clearBtn) {
            clearBtn.addEventListener('click', function() {
                if (!confirm('Start a new conversation?')) return;
                fetch('/ai/reset_conversation', { method: 'POST', credentials: 'include' }).catch(function() {});
                state.currentConversationId = null;
                try { sessionStorage.removeItem('currentConversationId'); sessionStorage.removeItem('chatMessages'); } catch(ex) {}
                messages.innerHTML = '';
                const wEl = document.createElement('div');
                wEl.className = 'welcome-message';
                wEl.innerHTML = '<div class="welcome-icon">🤖</div><h2>How can I help you today?</h2><p>Ask me anything.</p>';
                messages.appendChild(wEl);
                if (window.AIChatPageBridge && window.AIChatPageBridge.onConversationIdChange) {
                    window.AIChatPageBridge.onConversationIdChange(null);
                }
            });
        }

        // Expose bridge so page-specific JS (sidebar etc.) can integrate
        window.AIChatPageBridge = {
            getState: function() { return state; },
            getConversationId: function() { return state.currentConversationId; },
            setConversationId: function(id) {
                state.currentConversationId = id;
                if (id) {
                    try { sessionStorage.setItem('currentConversationId', id); } catch(ex) {}
                } else {
                    try { sessionStorage.removeItem('currentConversationId'); } catch(ex) {}
                }
            },
            onConversationIdChange: null,
            addSystemMessage: function(text) { addMessage(text, 'ai-message'); persistMessages(); }
        };

        console.debug('[AI] Page mode initialized — bound to #chat-form / #user-input / #chat-messages');
    }

    // Add CSS styles
    function addChatStyles() {
        if (!document.querySelector('link[data-ai-chat-css]')) {
            const link = document.createElement('link');
            link.rel = 'stylesheet';
            link.setAttribute('data-ai-chat-css', '1');
            link.href = '/static/css/ai-chat.css?v=' + Date.now();
            document.head.appendChild(link);
        }
    }
    function _addChatStylesLEGACY_UNUSED() {
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

            /* Popup-active state: pulsing ring shows the popup window is live */
            .chat-button.popup-active {
                box-shadow: 0 0 0 3px rgba(255,153,0,0.6), 0 2px 5px rgba(0,0,0,0.2);
                animation: ai-popup-pulse 2s infinite;
            }
            @keyframes ai-popup-pulse {
                0%   { box-shadow: 0 0 0 3px rgba(255,153,0,0.6), 0 2px 5px rgba(0,0,0,0.2); }
                50%  { box-shadow: 0 0 0 7px rgba(255,153,0,0.15), 0 2px 5px rgba(0,0,0,0.2); }
                100% { box-shadow: 0 0 0 3px rgba(255,153,0,0.6), 0 2px 5px rgba(0,0,0,0.2); }
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

            /* In a detached popup window: fill the entire window so resize works naturally */
            body.ai-widget-popup .chat-panel {
                position: fixed;
                top: 0; left: 0; right: 0; bottom: 0;
                width: 100% !important;
                height: 100% !important;
                max-width: 100% !important;
                max-height: 100% !important;
                min-width: 0 !important;
                min-height: 0 !important;
                border-radius: 0;
                box-shadow: none;
                margin: 0;
            }
            body.ai-widget-popup .chat-input {
                flex-shrink: 0;
            }
            body.ai-widget-popup #message-input {
                height: auto;
                min-height: 40px;
                max-height: 160px;
                resize: vertical;
            }

            /* Popup-active state: pulsing ring shows the popup window is live */
            .chat-button.popup-active {
                box-shadow: 0 0 0 3px rgba(255,153,0,0.6), 0 2px 5px rgba(0,0,0,0.2);
                animation: ai-popup-pulse 2s infinite;
            }
            @keyframes ai-popup-pulse {
                0%   { box-shadow: 0 0 0 3px rgba(255,153,0,0.6), 0 2px 5px rgba(0,0,0,0.2); }
                50%  { box-shadow: 0 0 0 7px rgba(255,153,0,0.15), 0 2px 5px rgba(0,0,0,0.2); }
                100% { box-shadow: 0 0 0 3px rgba(255,153,0,0.6), 0 2px 5px rgba(0,0,0,0.2); }
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
                margin: 0; font-size: 14px; white-space: nowrap;
                overflow: hidden; text-overflow: ellipsis; flex-shrink: 0;
            }

            .chat-header-title-group {
                display: flex; align-items: baseline; gap: 5px;
                flex: 1; min-width: 0; overflow: hidden;
            }

            .chat-page-label {
                font-size: 11px; opacity: 0.88; white-space: nowrap;
                overflow: hidden; text-overflow: ellipsis; flex: 1; min-width: 0;
                display: flex; align-items: center; gap: 3px; flex-wrap: nowrap;
            }
            .chat-ctx-page {
                white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
                flex-shrink: 1; min-width: 0;
            }
            .chat-ctx-badge {
                display: inline-block; border-radius: 3px; padding: 0 4px;
                font-size: 10px; font-weight: 700; letter-spacing: 0.02em;
                white-space: nowrap; flex-shrink: 0; line-height: 1.5;
            }
            .chat-ctx-site  { background: rgba(255,255,255,0.28); }
            .chat-ctx-agent { background: rgba(0,0,0,0.22); }

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
            .wh-item:hover { background: var(--table-header-bg); }
            .wh-item.active { background: var(--table-header-bg); border-left: 3px solid var(--link-color); }
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
    
    // Listen for dock-back message from detached popup so the widget re-opens
    // on the parent page when the user clicks ⤡ in the popup.
    if (!PAGE_MODE) {
        window.addEventListener('message', function(event) {
            if (event.origin !== window.location.origin) return;
            if (event.data && event.data.type === 'ai-dock-back') {
                const btn = document.getElementById('chat-button');
                if (btn) btn.click();
                else openChat();
            }
        });
    }

    // Initialize chat when the DOM is loaded
    // Admin: poll for pending support chats and fire browser notification from any page
    (function() {
        if (!window.AI_CHAT_USER_CONFIG || !window.AI_CHAT_USER_CONFIG.isAdmin) return;
        var _adminNotifPerm = (typeof Notification !== 'undefined') ? Notification.permission : 'denied';
        var _adminLastPending = 0;
        var _adminTitleFlashTimer = null;
        var _adminOrigTitle = null;

        function _requestAdminNotifPerm() {
            if (typeof Notification === 'undefined') return;
            if (Notification.permission === 'granted') { _adminNotifPerm = 'granted'; return; }
            if (Notification.permission !== 'denied') {
                Notification.requestPermission().then(function(p) { _adminNotifPerm = p; });
            }
        }

        function _adminBeep() {
            try {
                var ctx = new (window.AudioContext || window.webkitAudioContext)();
                var osc = ctx.createOscillator();
                var gain = ctx.createGain();
                osc.connect(gain);
                gain.connect(ctx.destination);
                osc.type = 'sine';
                osc.frequency.value = 880;
                gain.gain.setValueAtTime(0.3, ctx.currentTime);
                gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.5);
                osc.start(ctx.currentTime);
                osc.stop(ctx.currentTime + 0.5);
            } catch (e) {}
        }

        function _adminTitleFlash(n) {
            if (_adminTitleFlashTimer) return;
            if (!_adminOrigTitle) _adminOrigTitle = document.title;
            var alertTitle = '💬 ' + n + ' Support Request' + (n > 1 ? 's' : '') + '!';
            var on = true;
            var count = 0;
            _adminTitleFlashTimer = setInterval(function() {
                document.title = on ? alertTitle : _adminOrigTitle;
                on = !on;
                if (++count >= 20) {
                    clearInterval(_adminTitleFlashTimer);
                    _adminTitleFlashTimer = null;
                    document.title = _adminOrigTitle;
                }
            }, 800);
        }

        function _adminShowToast(n) {
            var existing = document.getElementById('admin-support-toast');
            if (existing) existing.parentNode.removeChild(existing);
            var toast = document.createElement('div');
            toast.id = 'admin-support-toast';
            toast.style.cssText = 'position:fixed;top:70px;right:20px;z-index:99999;background:#1a6bb5;color:#fff;'
                + 'padding:14px 20px;border-radius:8px;box-shadow:0 4px 20px rgba(0,0,0,0.3);'
                + 'font-size:.95em;font-weight:600;cursor:pointer;max-width:320px;line-height:1.4;';
            toast.innerHTML = '💬 ' + n + ' support chat request' + (n > 1 ? 's' : '') + ' awaiting reply'
                + '<br><small style="font-weight:normal;opacity:.85;">Click to open Support Chat Admin</small>';
            toast.onclick = function() {
                if (window.AI_WIDGET_POPUP && window.opener && !window.opener.closed) {
                    window.opener.location.href = '/chat/admin';
                } else {
                    window.location.href = '/chat/admin';
                }
            };
            document.body.appendChild(toast);
            setTimeout(function() {
                if (toast.parentNode) toast.parentNode.removeChild(toast);
            }, 30000);
        }

        window.ComservAIChat = {
            open: openChatPreferred,
            openInline: openChat,
            openPopup: detachToPopup,
        };
        window.openChat = openChat;
    })();

    document.addEventListener('DOMContentLoaded', function() {
        addChatStyles();

        // When running inside the detached popup window, mark <body> so CSS can
        // override the chat panel to fill 100% of the window.
        if (window.AI_WIDGET_POPUP) {
            document.body.classList.add('ai-widget-popup');
        }

        if (PAGE_MODE) {
            // /ai full-page mode: bind to existing DOM, no floating widget
            initPageMode();
        } else {
            // Widget mode: create floating bubble + panel on every page
            createChatWidget();

            // Load agents config asynchronously (doesn't block widget creation)
            loadAgentsConfig().then(function() {
                console.debug('Agents config loaded successfully');
                if (state.isOpen && state.currentAgent) {
                    const chatButton = document.getElementById('chat-button');
                    if (chatButton && state.currentAgent.icon) {
                        chatButton.querySelector('.chat-icon').textContent = state.currentAgent.icon;
                    }
                }
            });

            // Restore last mode: popup window (default on desktop) or inline dock (if no active popup)
            const isPopupActive = localStorage.getItem('ai_popup_active') === '1';
            if (window.AI_WIDGET_POPUP) {
                openChat();
            } else if (isPopupActive) {
                // If a popup is active, ensure the chat button is visually marked as popup-active
                const chatButton = document.getElementById('chat-button');
                if (chatButton) {
                    chatButton.classList.add('popup-active');
                    chatButton.title = 'AI chat is open in a separate window — click to bring to front';
                }
            } else if (sessionStorage.getItem('ai_chat_open') === 'inline') {
                openChat();
            } else if (sessionStorage.getItem('ai_chat_open') === 'popup'
                    || sessionStorage.getItem('ai_chat_open') === '1') {
                openChatPreferred();
            }
        }

        // Check for a pending navigate_and_fill stored by another tab.
        // If the current URL matches the stored target, apply the field values and clear.
        (function() {
            try {
                var pending = localStorage.getItem('ai_pending_fill');
                if (!pending) return;
                var pdata = JSON.parse(pending);
                if (!pdata || !pdata.url || !pdata.fields) return;
                // Expire after 2 minutes
                if (Date.now() - (pdata.ts || 0) > 120000) {
                    localStorage.removeItem('ai_pending_fill');
                    return;
                }
                // Normalize both URLs to just pathname+search for comparison
                var targetPath = pdata.url.replace(/^https?:\/\/[^\/]+/, '');
                var currentPath = window.location.pathname + window.location.search;
                if (targetPath !== currentPath) return;
                // Clear immediately to avoid re-applying on refresh
                localStorage.removeItem('ai_pending_fill');
                // Short delay so the page form has rendered
                setTimeout(function() {
                    _executeFillForm({ fields: pdata.fields });
                    // Show notification in widget if it exists
                    var chatMessages = document.getElementById('chat-messages');
                    if (chatMessages) {
                        var wrapper = document.createElement('div');
                        wrapper.className = 'msg-wrapper msg-wrapper-ai';
                        var lbl = document.createElement('div');
                        lbl.className = 'msg-label';
                        lbl.textContent = 'System';
                        var el = document.createElement('div');
                        el.className = 'message system-message';
                        el.textContent = '🪄 AI pre-filled form fields. Please review before saving.';
                        wrapper.appendChild(lbl);
                        wrapper.appendChild(el);
                        chatMessages.appendChild(wrapper);
                        chatMessages.scrollTop = chatMessages.scrollHeight;
                    }
                }, 600);
            } catch(e) {
                console.warn('ai_pending_fill check failed:', e);
            }
        })();

        // HelpDesk pre-screen mode: expose helper + auto-open with greeting (widget only)
        if (!PAGE_MODE && window.HELPDESK_PRESCREEN) {
            var _hdOpenAndGreet = function() {
                if (!state.isOpen) {
                    var toggleBtn = document.getElementById('chat-button') || document.querySelector('.chat-button');
                    if (toggleBtn) toggleBtn.click();
                }
                // Display greeting bubble immediately (no API call)
                setTimeout(function() {
                    var chatMessages = document.getElementById('chat-messages');
                    if (chatMessages) {
                        var wrapper = document.createElement('div');
                        wrapper.className = 'msg-wrapper msg-wrapper-ai';
                        var lbl = document.createElement('div');
                        lbl.className = 'msg-label';
                        lbl.textContent = 'AI Assistant';
                        var msg = document.createElement('div');
                        msg.className = 'message ai-message';
                        msg.innerHTML = '👋 <strong>Before you submit a ticket, let me try to help!</strong><br>'
                            + 'Describe your issue here and I\'ll do my best to resolve it right away.<br>'
                            + '<small style="opacity:0.7">If I can\'t solve it, I\'ll let you know and you can use the ticket form.</small>';
                        wrapper.appendChild(lbl);
                        wrapper.appendChild(msg);
                        // Insert after any existing system greeting
                        var firstChild = chatMessages.firstChild;
                        if (firstChild) {
                            chatMessages.insertBefore(wrapper, firstChild.nextSibling);
                        } else {
                            chatMessages.appendChild(wrapper);
                        }
                        chatMessages.scrollTop = chatMessages.scrollHeight;
                    }
                }, 200);
            };

            // Expose for the template button
            window.openHelpDeskChat = _hdOpenAndGreet;
        }

        // Cleanup old local voice recording backups (> 7 days) and render any pending/failed ones
        _cleanupOldAudioBackups().then(_renderLocalAudioBackups).catch(function(e) {
            console.error('Failed to init local audio backups:', e);
        });

        // Check if there is a pending query that needs to be resumed due to navigation
        try {
            const pendingQueryStr = sessionStorage.getItem('ai_pending_query');
            if (pendingQueryStr) {
                const pending = JSON.parse(pendingQueryStr);
                if (pending && pending.prompt && (Date.now() - (pending.timestamp || 0) < 60000)) {
                    console.debug('[AI] Resuming pending query after navigation:', pending.prompt);
                    // Clear it first to prevent infinite loop if it fails repeatedly
                    sessionStorage.removeItem('ai_pending_query');
                    // Automatically open chat panel so the user sees it thinking
                    if (!PAGE_MODE) {
                        openChat();
                    }
                    // Run the query!
                    queryAI(pending.prompt, pending.imageData);
                } else {
                    sessionStorage.removeItem('ai_pending_query');
                }
            }
        } catch(e) {
            console.warn('[AI] Failed to resume pending query:', e);
            sessionStorage.removeItem('ai_pending_query');
        }
    });

    // Global API: open the chat widget pre-loaded with a task context.
    // Called from todo/details.tt "Chat about this task" button.
    // taskContext: { record_id, subject, description, status, due_date, project }
    window.openAIChatWithTask = function(taskContext) {
        if (!taskContext || !taskContext.record_id) { openChat(); return; }
        state.taskContext = taskContext;
        state.taskPagePath = '/todo/details?record_id=' + taskContext.record_id;
        if (!state.pageContext) state.pageContext = detectPageContext();
        state.pageContext.page_path = state.taskPagePath;
        // Auto-select agent based on task subject
        loadAgentsConfig().then(function() {
            if (state.agentsConfig && state.agentsConfig.agents) {
                var subj = (taskContext.subject || '').toUpperCase();
                var agents = state.agentsConfig.agents;
                var picked = null;
                if (/\bENCY\b|HERB|BOTANICAL|CONSTITUENT|PLANT\b/.test(subj) && agents.ency)           picked = agents.ency;
                else if (/\bBEEMASTER\b|\bBMASTER\b|HIVE|APIARY|VARROA|QUEEN\b|INSPECTION/.test(subj) && agents.beemaster) picked = agents.beemaster;
                else if (/\bACCOUNTING\b|\bINVOICE\b|\bCOA\b|\bGL\b/.test(subj) && agents.accounting)  picked = agents.accounting;
                else if (/\bINVENTORY\b|STOCK\b|\bSKU\b/.test(subj) && agents.inventory)               picked = agents.inventory;
                else if (/\bHELPDESK\b|SUPPORT\b|TICKET\b/.test(subj) && agents.helpdesk)              picked = agents.helpdesk;
                else if (agents.planning) picked = agents.planning;
                if (picked) {
                    state.currentAgent = picked;
                    state.pageContext.agent_id   = picked.id;
                    state.pageContext.agent_name = picked.display_name;
                    if (picked.system_prompt) state.pageContext.system_prompt = picked.system_prompt;
                    populateAgentPicker();
                }
            }
            openChat();
        }).catch(function() { openChat(); });
    };
})();
document.addEventListener("DOMContentLoaded", function() {
    if (typeof _startChatSSE === "function") {
        console.log("[Chat] Starting SSE connection (startChatSSE)");
        _startChatSSE();
    }
});

