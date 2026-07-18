// ai-chat/page-context.js — V2 module (extracted from local-chat.js)
// Page-context extraction + navigation-intent + provider/model auto-selection.
// Referenced from many places in local-chat.js core, exposed on
// window.ComservChat.pageContext.* . init({state, STATIC_NAV, NAV_RE}) injects deps.
(function () {
    window.ComservChat = window.ComservChat || {};
    // `state` is referenced directly by the extracted function bodies; set by init().
    // STATIC_NAV / NAV_RE are declared below (from the original file) and re-pointed in init().
    // state is injected by local-chat.js core (set once at startup). STATIC_NAV /
    // NAV_RE are defined in this file and used directly by the functions below.
    var state = null;
    function init(ctx) { state = ctx.state; }

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
    var NAV_RE = /^(open|go to|take me to|navigate to|visit|switch to|switch|bring me to|load|browse|display|show me the|take me to the|go to the)\s+(.+)/i;

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

    function isChatModel(id) {
        const s = id.toLowerCase();
        // Exclude embedding/reranker/vision-only models
        if (/embed|rerank|bge|nomic|clip|whisper|tts|vision(?!.*instruct)/.test(s)) return false;
        // :cloud models (Ollama-routed cloud) are chat-capable — include them
        return true;
    }

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

    function _fuzzyWordMatch(w, labelWords) {
        if (w.length < 3) return false;
        var maxDist = w.length >= 6 ? 2 : 1;
        return labelWords.some(function(lw) {
            return lw.length >= 3 && _editDist(w, lw) <= maxDist;
        });
    }

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

    window.ComservChat.pageContext = {
        init: init,
        NAV_RE: NAV_RE,
        collectPageErrors: _collectPageErrors,
        getTemplatePathForPage: _getTemplatePathForPage,
        fetchPageDoc: fetchPageDoc,
        extractPageContent: extractPageContent,
        extractPageLinks: extractPageLinks,
        detectPageContext: detectPageContext,
        isChatModel: isChatModel,
        modelSizeScore: modelSizeScore,
        classifyQuery: classifyQuery,
        autoSelectProvider: autoSelectProvider,
        buildNavigationMap: buildNavigationMap,
        editDist: _editDist,
        fuzzyWordMatch: _fuzzyWordMatch,
        resolveNavIntent: resolveNavIntent,
        buildHistory: buildHistory
    };
})();
