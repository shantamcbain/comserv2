// ai-chat/model-select.js — SHARED model-selection module for every chat widget.
//
// Eliminates the divergent model code that used to live separately in
// local-chat.js (general "Chat with AI" widget) and ai2editor/chat.js (editor
// chat, which hard-coded tencent/hy3). Both widgets now call THIS module,
// filtered by a `context` so each widget gets the catalog it needs without
// duplicating the fetch/render logic.
//
// Loaded BEFORE local-chat.js / ai2editor/chat.js via js_load.tt (defer
// preserves order). Attaches to window.ComservChat.modelSelect.
//
// API:
//   ComservChat.modelSelect.init({ selectEl, context, pinModel, onReady, onError })
//   ComservChat.modelSelect.getSelectedValue()   -> "provider|model"  (e.g. "openrouter|tencent/hy3")
//   ComservChat.modelSelect.resolveDefault(ctx)   -> default model string for a context ("code" -> "tencent/hy3")
//   ComservChat.modelSelect.onChange(cb)          -> register a change listener
//   ComservChat.modelSelect.isChatModel(id)      -> bool (shared helper, moved from local-chat.js)
//   ComservChat.modelSelect.modelSizeScore(id)   -> number (shared helper, moved from local-chat.js)
//
// Provider catalog endpoint: GET /ai2/providers  (already role-gated + live
// from each provider's API — no stale static lists).
(function () {
    'use strict';

    window.ComservChat = window.ComservChat || {};

    // ---- module-level cache (one fetch, shared by every widget) -----------
    var _catalogCache = null;     // resolved providers array
    var _catalogPromise = null;   // in-flight fetch promise
    var _listeners = [];          // onChange callbacks
    var _lastSelectEl = null;     // the select currently managed
    var _ctx = 'chat';            // context of the active select
    var _pinnedValue = null;      // value pinned to top (e.g. openrouter|tencent/hy3)
    var _ollamaOnly = false;      // when true, render only Ollama models (skip xAI/OpenRouter)

    // ---- shared helpers (moved here from local-chat.js) -------------------
    function isChatModel(id) {
        if (!id) return false;
        // Exclude obvious non-chat model families.
        return !/(embed|rerank|bge|nomic|clip|whisper|tts|imagine|image|audio|video)/i.test(id);
    }

    // Rough size score from a model id — used to sort/select tiers.
    function modelSizeScore(id) {
        if (!id) return 0;
        var m = id.match(/(\d+(?:\.\d+)?)\s*[bB]/i);
        if (m) {
            var n = parseFloat(m[1]);
            // Normalize common scales to a 1-12-ish range.
            if (n >= 100) return 12;            // 70b, 120b, 405b
            if (n >= 30)  return 10;            // 32b, 34b, 70b
            if (n >= 13)  return 8;             // 13b, 14b
            if (n >= 7)   return 6;             // 7b, 8b
            if (n >= 3)   return 4;             // 3b, 4b
            return 2;                           // 1b, 2b
        }
        if (/large/i.test(id))   return 10;
        if (/medium/i.test(id))  return 6;
        if (/small/i.test(id))   return 3;
        return 4;
    }

    // ---- catalog fetch (cached) -------------------------------------------
    // Prefer the server-rendered global (window.ComservConfig.models), which is
    // stashed once per session and rendered into the page HTML — so there is NO
    // per-use fetch and no render race. Fall back to /ai2/providers only if the
    // global is absent (e.g. first paint before the session catalog is built).
    function fetchCatalog() {
        if (_catalogCache) return Promise.resolve(_catalogCache);
        if (_catalogPromise) return _catalogPromise;
        var globalModels = (window.ComservConfig && window.ComservConfig.models) || [];
        if (globalModels.length) {
            _catalogCache = globalModels.map(function (m) {
                return { service: m.provider, name: m.label, models: [{ id: m.value.split('|').pop(), label: m.label }] };
            });
            return Promise.resolve(_catalogCache);
        }
        _catalogPromise = fetch('/ai2/providers', { method: 'GET', credentials: 'include' })
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (!data || !data.success) throw new Error('providers request failed');
                _catalogCache = data.providers || [];
                return _catalogCache;
            })
            .catch(function (err) {
                _catalogPromise = null; // allow retry
                throw err;
            });
        return _catalogPromise;
    }

    // ---- rendering ---------------------------------------------------------
    // Build optgroups (ollama, grok, openrouter/external) into selectEl.
    // `ollamaOnly` (passed via init) restricts the list to local Ollama models
    // only — used by the general Chat-with-AI widget where xAI/OpenRouter aren't
    // needed and just bloat the dropdown / memory.
    function render(selectEl, context, pinModel) {
        if (!selectEl) return;
        selectEl.innerHTML = '';

        var providers = _catalogCache || [];
        var hy3Value = 'openrouter|tencent/hy3';
        var pinnedOpt = null;

        providers.forEach(function (p) {
            var svc = p.service;

            if (svc === 'ollama') {
                var grp = document.createElement('optgroup');
                var host = p.active_host || '';
                var isLocal = !host || host === 'localhost' || host === '127.0.0.1' || host === '0.0.0.0' || host === '::1';
                grp.label = isLocal ? 'Ollama (Local)' : 'Ollama (Remote: ' + host + ')';
                var chatModels = (p.models || []).filter(function (m) { return isChatModel(m.id); });
                var display = chatModels.filter(function (m) { return modelSizeScore(m.id) >= 3; });
                if (!display.length) display = chatModels;
                display.forEach(function (m) {
                    var opt = document.createElement('option');
                    opt.value = 'ollama|' + m.id;
                    opt.textContent = m.id;
                    if (m.unreachable) { opt.disabled = true; opt.textContent = m.label || 'Ollama (unreachable)'; }
                    grp.appendChild(opt);
                });
                if (!display.length) {
                    var o = document.createElement('option');
                    o.value = 'ollama'; o.textContent = 'Ollama (default)';
                    grp.appendChild(o);
                }
                selectEl.appendChild(grp);

            } else if (_ollamaOnly) {
                // Skip grok / external providers when Ollama-only is requested.
                return;

            } else if (svc === 'grok') {
                var ggrp = document.createElement('optgroup');
                ggrp.label = 'xAI (Grok)';
                var gmodels = (p.models && p.models.length)
                    ? p.models.filter(function (m) { return m.id && !/imagine|video/i.test(m.id); })
                        .map(function (m) {
                            var label = m.id.replace(/-/g, ' ').replace(/\b\w/g, function (c) { return c.toUpperCase(); });
                            return { val: 'grok|' + m.id, label: label + ' (xAI)' };
                        })
                    : [{ val: 'grok|grok-4.3', label: 'Grok 4.3 (xAI)' }];
                gmodels.forEach(function (m) {
                    var opt = document.createElement('option');
                    opt.value = m.val; opt.textContent = m.label;
                    ggrp.appendChild(opt);
                });
                selectEl.appendChild(ggrp);

            } else {
                // Generic external provider (OpenRouter, OpenAI, Groq, ...)
                var egrp = document.createElement('optgroup');
                egrp.label = (p.name || svc || 'External');
                var emodels = (p.models && p.models.length)
                    ? p.models.filter(function (m) { return m.id && !/imagine|video|embed|rerank/i.test(m.id); })
                        .map(function (m) {
                            var label = (m.label || m.id).replace(/-/g, ' ');
                            return { val: svc + '|' + m.id, label: label + ' (' + svc + ')' };
                        })
                    : [{ val: svc + '|' + svc, label: (p.name || svc) + ' (external)' }];
                emodels.forEach(function (m) {
                    var opt = document.createElement('option');
                    opt.value = m.val; opt.textContent = m.label;
                    if (m.val === hy3Value) { pinnedOpt = opt; opt.textContent = '⚡ tencent/hy3 (OpenRouter)'; }
                    egrp.appendChild(opt);
                });
                selectEl.appendChild(egrp);
            }
        });

        // Pin + default hy3 when requested (code context pins it; chat context
        // also pins when pinModel is set). Move to top of the dropdown.
        if (pinnedOpt && pinModel) {
            selectEl.insertBefore(pinnedOpt, selectEl.firstChild);
            _pinnedValue = hy3Value;
        } else {
            _pinnedValue = null;
        }

        // Auto-select default: prefer pinned hy3, else first available option.
        if (pinModel && pinnedOpt) {
            selectEl.value = hy3Value;
        } else if (selectEl.options.length) {
            // Preserve any previously-chosen value if still present.
            selectEl.selectedIndex = 0;
        }
    }

    // ---- public API --------------------------------------------------------
    function init(opts) {
        opts = opts || {};
        var selectEl = opts.selectEl || null;
        _ctx = opts.context || 'chat';
        _lastSelectEl = selectEl;
        _ollamaOnly = !!opts.ollamaOnly;

        return fetchCatalog().then(function () {
            render(selectEl, _ctx, opts.pinModel);
            if (typeof opts.onReady === 'function') opts.onReady(_catalogCache);
            // Fire listeners (e.g. so send logic picks up the default).
            _emit(selectEl ? selectEl.value : null);
        }).catch(function (err) {
            if (typeof opts.onError === 'function') opts.onError(err);
            // Surface a single harmless "configure" option so the UI isn't blank.
            if (selectEl) {
                selectEl.innerHTML = '';
                var o = document.createElement('option');
                o.value = ''; o.textContent = 'Models unavailable';
                selectEl.appendChild(o);
            }
        });
    }

    function getSelectedValue() {
        if (_lastSelectEl && _lastSelectEl.value) return _lastSelectEl.value;
        return resolveDefault(_ctx);
    }

    function resolveDefault(ctx) {
        if (ctx === 'code') return 'tencent/hy3';
        return _pinnedValue || 'ollama';
    }

    function onChange(cb) {
        if (typeof cb === 'function') _listeners.push(cb);
    }

    function _emit(value) {
        _listeners.forEach(function (cb) {
            try { cb(value); } catch (e) { /* swallow listener errors */ }
        });
    }

    // Expose. Keep the helpers global too so legacy call sites in local-chat.js
    // still resolve (mirrors the "move, don't rewrite" rule).
    window.isChatModel = isChatModel;
    window.modelSizeScore = modelSizeScore;

    window.ComservChat.modelSelect = {
        init: init,
        getSelectedValue: getSelectedValue,
        resolveDefault: resolveDefault,
        onChange: onChange,
        isChatModel: isChatModel,
        modelSizeScore: modelSizeScore,
        // test/debug helpers
        _setCatalog: function (c) { _catalogCache = c; }
    };
})();
