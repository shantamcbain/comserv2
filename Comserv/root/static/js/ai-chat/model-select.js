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
// Catalog sources (all supported, in priority order):
//   1. window.ComservConfig.models  — FLAT array of { value:"provider|model",
//      label, provider }. Rendered server-side into the page HTML by Root auto,
//      so there is NO network round-trip and NO render race. PREFERRED.
//   2. /ai2/providers               — GROUPED { providers:[{service,models:[...]}] }.
//      Fetched only if the flat global is absent, with a timeout + error handling
//      so a slow/unreachable OpenRouter egress can NEVER hang the widget.
//   3. STATIC_FALLBACK              — a small built-in list used if BOTH of the
//      above are empty (e.g. the provider APIs are down). Guarantees the dropdown
//      is never blank and the user can always pick a model.
//
// Data-shape note: the two live sources disagree in shape (flat vs grouped).
// We normalize BOTH into a single internal flat model list so render() has one
// code path. That is the fix for the "widget shows an empty list" regression:
// the old code read the flat source but rendered it as if it were grouped.
(function () {
    'use strict';

    window.ComservChat = window.ComservChat || {};

    // ---- module-level state ------------------------------------------------
    var _catalogCache = null;     // resolved FLAT models array [{value,label,provider}]
    var _catalogPromise = null;   // in-flight fetch promise
    var _listeners = [];          // onChange callbacks
    var _lastSelectEl = null;     // the select currently managed
    var _ctx = 'chat';            // context of the active select
    var _pinnedValue = null;      // value pinned to top (e.g. openrouter|tencent/hy3)
    var _ollamaOnly = false;      // when true, render only Ollama models (skip xAI/OpenRouter)

    // NOTE: there is intentionally NO static fallback model list. The catalog
    // comes only from the live sources (window.ComservConfig.models /
    // /ai2/providers). If those are empty the select shows a "Model list
    // unavailable" placeholder rather than fabricating models.

    // ---- shared label helper ----------------------------------------------
    // Turn a "provider|model" value into a human label. Deriving the provider
    // from the value itself is the ONLY correct way: callers used to assume
    // "not grok therefore ollama", which mislabelled every OpenRouter model
    // (e.g. openrouter|tencent/hy3 shown as "Ollama (Local): tencent/hy3").
    function describeModel(value, opts) {
        opts = opts || {};
        if (!value) return 'AI Assistant';
        var parts  = String(value).split('|');
        var svc    = parts[0] || '';
        var model  = parts[1] || '';
        var suffix = model ? ': ' + model : '';

        if (svc === 'supergrok') return 'SuperGrok (prepaid)' + suffix;
        if (svc === 'grok')       return 'Grok (xAI)' + suffix;
        if (svc === 'supergrok')  return 'SuperGrok (prepaid)' + suffix;
        if (svc === 'openrouter') return 'OpenRouter' + suffix;
        // The chat backend reports the generic bucket name 'external' for any
        // OpenAI-compatible provider (OpenRouter today). Recover the real
        // provider from the model slug rather than showing the bucket name.
        if (svc === 'external') {
            if (model.indexOf('/') !== -1) return 'OpenRouter' + suffix;
            return 'External' + suffix;
        }
        if (svc === 'ollama') {
            var host = opts.host || '';
            var isLocal = !host || host === 'localhost' || host === '127.0.0.1' ||
                          host === '0.0.0.0' || host === '::1';
            return (isLocal ? 'Ollama (Local)' : 'Ollama @' + host) + suffix;
        }
        if (!svc) return 'AI Assistant';
        // Unknown//future provider: name it rather than lying about it.
        return svc.charAt(0).toUpperCase() + svc.slice(1) + suffix;
    }

    // ---- shared helpers (moved here from local-chat.js) -------------------
    function isChatModel(id) {
        if (!id) return false;
        return !/(embed|rerank|bge|nomic|clip|whisper|tts|imagine|image|audio|video)/i.test(id);
    }

    // Rough size score from a model id — used to sort/select tiers.
    function modelSizeScore(id) {
        if (!id) return 0;
        var m = id.match(/(\d+(?:\.\d+)?)\s*[bB]/i);
        if (m) {
            var n = parseFloat(m[1]);
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

    // ---- catalog normalization --------------------------------------------
    // Turn any known source shape into the internal flat list.
    function fromFlat(flat) {
        // [{ value:"provider|model", label, provider, price_prompt, price_completion, pricing, price_tier, free, local }]
        if (!Array.isArray(flat)) return null;
        return flat
            .filter(function (m) { return m && m.value; })
            .map(function (m) {
                // Carry cost metadata through so render() can show real per-token
                // price (AIMPS-P1/#253). Serverside sets price_prompt/price_completion
                // as USD-per-1M; pricing is the raw provider hash (may be absent).
                return {
                    value: m.value,
                    label: m.label || m.value,
                    provider: m.provider || (m.value.split('|')[0] || ''),
                    price_prompt: (m.price_prompt != null) ? m.price_prompt : 0,
                    price_completion: (m.price_completion != null) ? m.price_completion : 0,
                    pricing: m.pricing || null,
                    price_tier: m.price_tier || null,
                    free: !!m.free,
                    local: !!m.local
                };
            });
    }

    function fromGrouped(data) {
        // { providers:[{ service, name, models:[{id,label}] }] }
        if (!data || !Array.isArray(data.providers)) return null;
        var out = [];
        data.providers.forEach(function (p) {
            var svc = p.service || p.name || '';
            var models = Array.isArray(p.models) ? p.models : [];
            if (!models.length) {
                out.push({ value: svc + '|' + svc, label: (p.name || svc) + ' (external)', provider: svc });
                return;
            }
            models.forEach(function (m) {
                var id = m.id || m.value;
                if (!id) return;
                out.push({ value: svc + '|' + id, label: m.label || id, provider: svc });
            });
        });
        return out.length ? out : null;
    }

    // ---- catalog fetch (network-independent fallback) ----------------------
    function fetchCatalog() {
        if (_catalogCache) return Promise.resolve(_catalogCache);
        if (_catalogPromise) return _catalogPromise;

        // 1) Preferred: server-rendered flat global (no network needed).
        var globalModels = (window.ComservConfig && window.ComservConfig.models) || [];
        var flat = fromFlat(globalModels);
        if (flat && flat.length) {
            _catalogCache = flat;
            return Promise.resolve(_catalogCache);
        }

        // 2) Fallback: live grouped endpoint, with a hard timeout so a hanging
        //    OpenRouter egress cannot wedge the widget.
        _catalogPromise = new Promise(function (resolve, reject) {
            var done = false;
            var timer = setTimeout(function () {
                if (done) return;
                done = true;
                reject(new Error('providers request timed out'));
            }, 6000);
            fetch('/ai2/providers', { method: 'GET', credentials: 'include' })
                .then(function (r) { return r.json(); })
                .then(function (data) {
                    if (done) return;
                    var grouped = fromGrouped(data);
                    if (!grouped || !grouped.length) throw new Error('providers returned no models');
                    done = true; clearTimeout(timer);
                    resolve(grouped);
                })
                .catch(function (err) {
                    if (done) return;
                    done = true; clearTimeout(timer);
                    reject(err);
                });
        })
            .then(function (models) {
                _catalogCache = models;
                _catalogPromise = null;
                return _catalogCache;
            })
            .catch(function () {
                _catalogPromise = null;        // allow retry on next init
                throw new Error('providers request failed');
            });
        return _catalogPromise;
    }

    // ---- rendering ---------------------------------------------------------
    // Build option groups into selectEl from the FLAT internal list.
    function render(selectEl, context, pinModel) {
        if (!selectEl) return;
        selectEl.innerHTML = '';

        var models = _catalogCache || [];
        // NOTE: we do NOT fall back to a hardcoded STATIC_FALLBACK list. The
        // catalog must come from the live sources only (window.ComservConfig.models
        // / the /ai2/providers fetch). Inventing models here means the user sees
        // options that aren't actually available to their account. If the live
        // catalog is empty we render a single disabled placeholder instead.
        if (!models.length) {
            var ph = document.createElement('option');
            ph.disabled = true;
            ph.selected = true;
            ph.textContent = 'Model list unavailable';
            selectEl.appendChild(ph);
            return;
        }

        // Group by provider, preserving a stable order: ollama, grok, openrouter.
        var order = { ollama: 0, supergrok: 1, grok: 2, openrouter: 3 };
        var groups = {};   // provider -> [models]
        models.forEach(function (m) {
            var svc = m.provider || (m.value.split('|')[0] || 'external');
            (groups[svc] = groups[svc] || []).push(m);
        });
        var svcs = Object.keys(groups).sort(function (a, b) {
            var ra = order[a] != null ? order[a] : 9;
            var rb = order[b] != null ? order[b] : 9;
            return ra - rb;
        });

        var hy3Value = 'openrouter|tencent/hy3';
        var pinnedOpt = null;
        var ollamaValues = [];
        var freeOpenRouterValues = [];

        svcs.forEach(function (svc) {
            if (_ollamaOnly && svc !== 'ollama') return;

            var grp = document.createElement('optgroup');
            if (svc === 'ollama')       grp.label = 'Ollama (Local)';
            else if (svc === 'supergrok') grp.label = 'SuperGrok (prepaid)';
            else if (svc === 'grok')    grp.label = 'xAI Grok (auto-fill)';
            else if (svc === 'openrouter') grp.label = 'OpenRouter';
            else                        grp.label = svc;

            // Ollama: only real chat models, smallest-first for sane default.
            var list = groups[svc].slice();
            if (svc === 'ollama') {
                list = list
                    .filter(function (m) { return isChatModel(m.value); })
                    .sort(function (a, b) {
                        return modelSizeScore(a.value) - modelSizeScore(b.value);
                    });
            } else if (svc === 'openrouter') {
                // Lowest cost first: free models at the very top, then by prompt
                // price ascending (completion as tie-breaker), alphabetical last
                // resort when prices are equal/missing.
                var priceOf = function (m) {
                    return Math.max(Number(m.price_prompt) || 0, Number(m.price_completion) || 0);
                };
                list.sort(function (a, b) {
                    var fa = m_free(a), fb = m_free(b);
                    if (fa !== fb) return fa ? -1 : 1;
                    var pa = priceOf(a), pb = priceOf(b);
                    if (pa !== pb) return pa - pb;
                    return String(a.value).localeCompare(String(b.value));
                });
                function m_free(m) {
                    return !!(m.free || /(^|:)(free)$/i.test(m.value));
                }
            }

            list.forEach(function (m) {
                var opt = document.createElement('option');
                opt.value = m.value;
                // For Ollama, the bare model slug is the label; for external
                // providers the catalog label already bakes the model name, so
                // use it directly. We DO NOT re-append the provider here because
                // the optgroup header already shows it (that duplication was the
                // "double provider" bug). The label's trailing " (openrouter)"
                // suffix is stripped to avoid repeating the group header.
                var text = (svc === 'ollama')
                    ? m.value.split('|').pop()
                    : String(m.label || m.value).replace(/\s*\([^)]*\)\s*$/, '');
                // Per-token cost marker so the user sees what a choice costs
                // before picking it (AIMPS-P2 / #254). Formatted in JS because
                // the server already sends USD-per-1M numbers.
                var pp = Number(m.price_prompt) || 0;
                var pc = Number(m.price_completion) || 0;
                if (m.local) {
                    text += ' — local';
                } else if (m.free || (svc === 'openrouter' && /(^|:)(free)$/i.test(m.value))
                          || (!m.local && !m.pricing && pp === 0 && pc === 0)) {
                    // Zero-priced external entries (stealth/ox-alpha,
                    // openrouter/auto, ...) cost nothing — mark them free.
                    text += ' — free';
                } else if (pp > 0 || pc > 0 || m.pricing) {
                    var fmt = function (n) { return (Math.round(n * 100) / 100).toFixed(2); };
                    var tier = m.price_tier || (pp === 0 && pc === 0 ? 'free' : 'paid');
                    text += ' — $' + fmt(pp) + '/$' + fmt(pc) + ' per 1M (' + tier + ')';
                }
                opt.textContent = text;
                if (m.value === hy3Value) {
                    pinnedOpt = opt;
                    opt.textContent = '⚡ tencent/hy3 (OpenRouter) — $' + (Math.round(pp * 100) / 100).toFixed(2)
                        + '/$' + (Math.round(pc * 100) / 100).toFixed(2) + ' per 1M (' + (m.price_tier || 'paid') + ')';
                }
                if (svc === 'openrouter' && /(^|:)(free)$/i.test(m.value)) freeOpenRouterValues.push(m.value);
                grp.appendChild(opt);
                if (svc === 'ollama') ollamaValues.push(m.value);
            });
            selectEl.appendChild(grp);
        });

        // Pin hy3 to the top (visible + selectable) when requested, but do NOT
        // auto-select it. The DEFAULT selected model for a non-paying user is a
        // FREE OpenRouter model (no local load, no cost). Ollama is intentionally
        // NOT the default: running local models hammers the workstation, and we
        // only use Ollama once its bug is fixed or the user explicitly demands
        // privacy. Fall back to Ollama / hy3 only when no free OpenRouter model
        // exists. The user can still pick any model (including Ollama or hy3).
        if (pinnedOpt && pinModel) {
            selectEl.insertBefore(pinnedOpt, selectEl.firstChild);
            _pinnedValue = hy3Value;
        } else {
            _pinnedValue = null;
        }

        // Preferred default: a free OpenRouter model (stable, general-purpose).
        var defaultFree = null;
        freeOpenRouterValues.forEach(function (v) {
            if (defaultFree === null) defaultFree = v;
            if (/gemma/i.test(v) || /nemotron-3-(nano|super)/i.test(v)) defaultFree = v;
        });

        // Auto-select default: free OpenRouter > smallest Ollama > pinned hy3 > first.
        if (defaultFree) {
            selectEl.value = defaultFree;
        } else if (ollamaValues.length) {
            selectEl.value = ollamaValues[0];   // already smallest-first
        } else if (pinModel && pinnedOpt) {
            selectEl.value = hy3Value;
        } else if (selectEl.options.length) {
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
            _emit(selectEl ? selectEl.value : null);
        }).catch(function (err) {
            // On total failure, do NOT invent a hardcoded model list. Render the
            // placeholder so the user knows the live catalog couldn't load,
            // rather than silently showing models that may not exist for them.
            if (typeof opts.onError === 'function') opts.onError(err);
            if (selectEl) {
                _catalogCache = [];
                render(selectEl, _ctx, opts.pinModel);
                _emit(selectEl ? selectEl.value : null);
            }
        });
    }

    function getSelectedValue() {
        if (_lastSelectEl && _lastSelectEl.value) return _lastSelectEl.value;
        return resolveDefault(_ctx);
    }

    function resolveDefault(ctx) {
        // Never return a hardcoded model. Prefer the pinned selection; otherwise
        // the first available catalog model (real, live list). Empty string only
        // if the live catalog has nothing — the caller shows the placeholder.
        if (_pinnedValue) return _pinnedValue;
        if (_catalogCache && _catalogCache.length) return _catalogCache[0].value;
        return '';
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
        describeModel: describeModel,
        // test/debug helpers
        _setCatalog: function (c) { _catalogCache = c; }
    };
})();
