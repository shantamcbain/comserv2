(function () {
    var SOURCES = [
        { id: 'tui', label: 'Hermes TUI', color: '#2a9d8f' },
        { id: 'cli', label: 'Hermes CLI', color: '#e76f51' },
        { id: 'oneshot', label: 'Hermes oneshot', color: '#7a7a7a' },
        { id: 'chat', label: 'AI Chat', color: '#457b9d' },
        { id: 'editor', label: 'AI Editor', color: '#c9a227' },
        { id: 'grok_bot', label: 'Grok Bot', color: '#6d597a' }
    ];
    var AGENT_IDS = { hermes: 1, chat: 1, grok_bot: 1, editor: 1 };
    var CHART_KEY = 'comserv_usage_chart_type';
    var RESET_ISO = '2026-10-01T10:31:00-07:00';
    var WEEK_OFF_AT = 90;

    var lastOrg = null;
    var focusSource = null;
    var lastGuard = null;

    function resultEl() { return document.getElementById('grok-live-result'); }
    function declareValue() {
        var input = document.getElementById('declare-xai-balance');
        return input ? String(input.value || '').trim() : '';
    }
    function cssVar(name, fallback) {
        var v = window.getComputedStyle(document.documentElement).getPropertyValue(name);
        return (v && v.trim()) || fallback;
    }
    function esc(s) {
        return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/\"/g, '&quot;');
    }
    function fmt(n) {
        n = Number(n || 0);
        if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
        if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
        return String(Math.round(n));
    }
    function setText(id, text) {
        var el = document.getElementById(id);
        if (el) el.textContent = text;
    }

    function chartType() {
        try {
            var t = window.localStorage.getItem(CHART_KEY);
            if (t === 'line' || t === 'bar') return t;
        } catch (e) {}
        return 'bar';
    }
    function setChartType(t) {
        if (t !== 'line' && t !== 'bar') t = 'bar';
        try { window.localStorage.setItem(CHART_KEY, t); } catch (e) {}
        paintChartToggle();
        if (lastOrg) renderChartsFromOrg(lastOrg);
    }
    function paintChartToggle() {
        var t = chartType();
        var buttons = document.querySelectorAll('[data-chart-type]');
        for (var i = 0; i < buttons.length; i++) {
            var on = buttons[i].getAttribute('data-chart-type') === t;
            buttons[i].style.borderColor = on ? 'var(--primary-color)' : 'var(--border-color)';
            buttons[i].style.opacity = on ? '1' : '0.65';
        }
    }

    function last14Days() {
        var out = [];
        var d = new Date();
        d.setUTCHours(0, 0, 0, 0);
        for (var i = 13; i >= 0; i--) {
            out.push(new Date(d.getTime() - i * 86400000).toISOString().slice(0, 10));
        }
        return out;
    }

    function normalizeSource(raw) {
        var s = String(raw || '').toLowerCase();
        if (s === 'tui' || s === 'cli' || s === 'oneshot') return s;
        if (s === 'chat') return 'chat';
        if (s === 'generate' || s === 'editor') return 'editor';
        if (s === 'grok_bot' || s === 'grok-bot') return 'grok_bot';
        if (s === 'hermes') return 'cli';
        return s || 'cli';
    }

    function collectSourceDays(org) {
        var map = {};
        function add(day, src, tokens, calls) {
            if (!day) return;
            day = String(day).slice(0, 10);
            src = normalizeSource(src);
            if (!map[src]) map[src] = {};
            if (!map[src][day]) map[src][day] = { tokens: 0, calls: 0 };
            map[src][day].tokens += Number(tokens || 0);
            map[src][day].calls += Number(calls || 0);
        }
        var hds = (org.hermes && org.hermes.by_day_source) || org.source_days || [];
        hds.forEach(function (r) {
            add(r.day, r.source || r.request_type || r.src, r.tokens, r.api_calls || r.calls);
        });
        (org.by_day_source || []).forEach(function (r) {
            add(r.day, r.request_type || r.source, r.tokens, r.calls);
        });
        if (!hds.length && org.hermes && org.hermes.by_day) {
            (org.hermes.by_day || []).forEach(function (r) {
                add(r.day, 'cli', r.tokens, r.api_calls || r.calls);
            });
        }
        return map;
    }

    function axis(ctx, w, h, padL, padB, padT, padR, max, days) {
        ctx.strokeStyle = cssVar('--border-color', '#ccc');
        ctx.beginPath();
        ctx.moveTo(padL, padT);
        ctx.lineTo(padL, h - padB);
        ctx.lineTo(w - padR, h - padB);
        ctx.stroke();
        ctx.fillStyle = cssVar('--text-color', '#444');
        ctx.font = '11px sans-serif';
        ctx.fillText(fmt(max), 4, padT + 10);
        ctx.fillText('0', 4, h - padB);
        ctx.fillText(days[0].slice(5), padL, h - 8);
        ctx.fillText(days[days.length - 1].slice(5), w - 48, h - 8);
    }

    function seriesMax(days, seriesMap, key) {
        var max = 1;
        days.forEach(function (day) {
            var t = 0;
            SOURCES.forEach(function (s) {
                var cell = (seriesMap[s.id] || {})[day];
                var v = cell ? Number(cell[key] || 0) : 0;
                t += v;
                if (v > max) max = v;
            });
            if (t > max && chartType() === 'bar') max = t;
        });
        if (chartType() === 'bar') {
            var totals = days.map(function (day) {
                var t = 0;
                SOURCES.forEach(function (s) {
                    var cell = (seriesMap[s.id] || {})[day];
                    t += cell ? Number(cell[key] || 0) : 0;
                });
                return t;
            });
            max = Math.max.apply(null, totals.concat([1]));
        }
        return max;
    }

    function drawStacked(canvas, days, seriesMap, key, focusId) {
        if (!canvas || !canvas.getContext) return;
        var ctx = canvas.getContext('2d');
        var w = canvas.width, h = canvas.height;
        ctx.clearRect(0, 0, w, h);
        var padL = 52, padB = 28, padT = 10, padR = 8;
        var innerW = w - padL - padR, innerH = h - padT - padB;
        var n = days.length || 1;
        var barW = Math.max(6, (innerW / n) * 0.72);
        var max = seriesMax(days, seriesMap, key);
        axis(ctx, w, h, padL, padB, padT, padR, max, days);
        days.forEach(function (day, i) {
            var x = padL + (i + 0.14) * (innerW / n);
            var y = h - padB;
            SOURCES.forEach(function (s) {
                var cell = (seriesMap[s.id] || {})[day];
                var v = cell ? Number(cell[key] || 0) : 0;
                var bh = (v / max) * innerH;
                ctx.globalAlpha = (!focusId || focusId === s.id) ? 1 : 0.18;
                ctx.fillStyle = s.color;
                if (v > 0) {
                    ctx.fillRect(x, y - Math.max(bh, 1), barW, Math.max(bh, 1));
                    y -= bh;
                }
            });
            ctx.globalAlpha = 1;
        });
    }

    function drawLines(canvas, days, seriesMap, key, focusId) {
        if (!canvas || !canvas.getContext) return;
        var ctx = canvas.getContext('2d');
        var w = canvas.width, h = canvas.height;
        ctx.clearRect(0, 0, w, h);
        var padL = 52, padB = 28, padT = 10, padR = 8;
        var innerW = w - padL - padR, innerH = h - padT - padB;
        var n = days.length || 1;
        var max = 1;
        days.forEach(function (day) {
            SOURCES.forEach(function (s) {
                var cell = (seriesMap[s.id] || {})[day];
                var v = cell ? Number(cell[key] || 0) : 0;
                if (v > max) max = v;
            });
        });
        axis(ctx, w, h, padL, padB, padT, padR, max, days);
        SOURCES.forEach(function (s) {
            ctx.globalAlpha = (!focusId || focusId === s.id) ? 1 : 0.18;
            ctx.strokeStyle = s.color;
            ctx.fillStyle = s.color;
            ctx.lineWidth = 2;
            ctx.beginPath();
            days.forEach(function (day, i) {
                var cell = (seriesMap[s.id] || {})[day];
                var v = cell ? Number(cell[key] || 0) : 0;
                var x = padL + (i + 0.5) * (innerW / n);
                var y = padT + innerH - (v / max) * innerH;
                if (i === 0) ctx.moveTo(x, y);
                else ctx.lineTo(x, y);
            });
            ctx.stroke();
            days.forEach(function (day, i) {
                var cell = (seriesMap[s.id] || {})[day];
                var v = cell ? Number(cell[key] || 0) : 0;
                var x = padL + (i + 0.5) * (innerW / n);
                var y = padT + innerH - (v / max) * innerH;
                ctx.beginPath();
                ctx.arc(x, y, 2.5, 0, Math.PI * 2);
                ctx.fill();
            });
            ctx.globalAlpha = 1;
        });
    }

    function renderLegend(seriesMap, days) {
        var el = document.getElementById('usage-source-legend');
        if (!el) return;
        el.innerHTML = SOURCES.map(function (s) {
            var tok = 0, calls = 0, nonempty = 0;
            days.forEach(function (day) {
                var cell = (seriesMap[s.id] || {})[day] || {};
                tok += Number(cell.tokens || 0);
                calls += Number(cell.calls || 0);
                if ((cell.tokens || 0) > 0 || (cell.calls || 0) > 0) nonempty += 1;
            });
            var on = !focusSource || focusSource === s.id;
            return '<button type="button" data-source-focus="' + s.id + '"'
                + ' style="border:1px solid var(--border-color);background:var(--card-bg, var(--bg-color));'
                + 'color:var(--text-color);padding:6px 10px;cursor:pointer;opacity:' + (on ? '1' : '0.45') + ';">'
                + '<span style="display:inline-block;width:10px;height:10px;background:' + s.color
                + ';margin-right:6px;"></span>'
                + esc(s.label) + ' · ' + fmt(tok) + ' tok · ' + fmt(calls) + ' API · '
                + nonempty + '/14d'
                + '</button>';
        }).join('');
    }

    function renderChartsFromOrg(org) {
        var days = last14Days();
        var map = collectSourceDays(org || {});
        var draw = chartType() === 'line' ? drawLines : drawStacked;
        draw(document.getElementById('usage-tokens-chart'), days, map, 'tokens', focusSource);
        draw(document.getElementById('usage-calls-chart'), days, map, 'calls', focusSource);
        renderLegend(map, days);
        paintChartToggle();
    }

    function vancouverDate(d) {
        try {
            return new Intl.DateTimeFormat('en-CA', {
                timeZone: 'America/Vancouver',
                year: 'numeric', month: '2-digit', day: '2-digit'
            }).format(d);
        } catch (e) {
            return d.toISOString().slice(0, 10);
        }
    }

    function nextReset(now) {
        var reset = new Date(RESET_ISO);
        var week = 7 * 24 * 3600 * 1000;
        while (reset.getTime() <= now.getTime()) reset = new Date(reset.getTime() + week);
        return reset;
    }

    function computeGuard(build, histText) {
        var now = new Date();
        var reset = nextReset(now);
        var hours = Math.max(0, (reset.getTime() - now.getTime()) / 3600000);
        var daysLeft = Math.max(1, Math.ceil(hours / 24));
        var remaining = Math.max(0, 100 - build);
        var dailyCap = remaining ? Math.max(3, Math.floor(remaining / daysLeft)) : 0;
        var today = vancouverDate(now);
        var yestDate = new Date(now.getTime() - 24 * 3600 * 1000);
        var yesterday = vancouverDate(yestDate);
        var pts = [];
        String(histText || '').split('\n').forEach(function (line) {
            line = line.trim();
            if (!line) return;
            try {
                var o = JSON.parse(line);
                if (typeof o.build !== 'number') return;
                var ts = o.at ? new Date(o.at) : null;
                if (!ts || isNaN(ts.getTime())) return;
                pts.push({ ts: ts, build: o.build, day: vancouverDate(ts) });
            } catch (e) {}
        });
        pts.push({ ts: now, build: build, day: today });
        function lastBefore(dayStr) {
            var last = null;
            pts.forEach(function (p) {
                if (p.day < dayStr) last = p.build;
            });
            return last;
        }
        function firstLastOn(dayStr) {
            var first = null, last = null;
            pts.forEach(function (p) {
                if (p.day === dayStr) {
                    if (first == null) first = p.build;
                    last = p.build;
                }
            });
            return { first: first, last: last };
        }
        var todayFL = firstLastOn(today);
        var priorToday = lastBefore(today);
        var usedToday;
        if (priorToday != null) usedToday = Math.max(0, build - priorToday);
        else usedToday = Math.max(0, build - (todayFL.first != null ? todayFL.first : build));
        var yestFL = firstLastOn(yesterday);
        var usedYest;
        if (yestFL.last != null) {
            var priorY = lastBefore(yesterday);
            usedYest = priorY != null ? Math.max(0, yestFL.last - priorY) : Math.max(0, yestFL.last - yestFL.first);
        } else if (priorToday == null && todayFL.first != null) {
            usedYest = Math.max(0, todayFL.first);
        } else {
            usedYest = 0;
        }
        var overY = dailyCap > 0 && usedYest >= dailyCap;
        var overT = dailyCap > 0 && usedToday >= dailyCap;
        var weekOff = build >= WEEK_OFF_AT;
        var reasons = [];
        if (overY) reasons.push('yesterday ' + usedYest + '% ≥ daily cap ' + dailyCap + '%');
        if (overT) reasons.push('today ' + usedToday + '% ≥ daily cap ' + dailyCap + '%');
        if (weekOff) reasons.push('week Build ' + build + '% ≥ ' + WEEK_OFF_AT + '%');
        return {
            ok: true,
            build: build,
            remaining: remaining,
            daily_cap: dailyCap,
            used_today: usedToday,
            used_yesterday: usedYest,
            days_left: daysLeft,
            reset_at: reset.toISOString(),
            mode: (overY || overT || weekOff) ? 'free' : 'grok',
            off_today: !!(overY || overT || weekOff),
            lock_reason: reasons.join('; ')
        };
    }

    function paintSuperGrok(g) {
        if (!g) return;
        lastGuard = g;
        var build = g.build;
        setText('usage-kpi-build', build == null ? '—' : (build + '%'));
        setText('usage-kpi-remaining', g.remaining == null ? '—' : (g.remaining + '%'));
        setText('usage-kpi-cap', g.daily_cap == null ? '—' : (g.daily_cap + '%'));
        setText('usage-kpi-used-today', g.used_today == null ? '—' : (g.used_today + '%'));
        setText('usage-kpi-days', g.days_left == null ? '—' : String(g.days_left));
        var st = document.getElementById('usage-sg-status');
        if (!st) return;
        if (g.off_today || g.mode === 'free') {
            st.textContent = 'SuperGrok off for today. New Hermes sessions → openrouter/cohere/north-mini-code:free. '
                + (g.lock_reason || '')
                + '. Restores grok-build-0.1 next PDT day only if week Build < ' + WEEK_OFF_AT + '%. This chat stays until a new session.';
            st.style.color = 'var(--error-color, var(--primary-color))';
        } else {
            st.textContent = 'SuperGrok on for new sessions (grok-build-0.1). Yesterday +'
                + (g.used_yesterday == null ? '?' : g.used_yesterday) + '% · reset '
                + (g.reset_at || RESET_ISO) + '.';
            st.style.color = 'var(--text-color)';
        }
    }

    function checkLiveGrokBalance(declareVal) {
        var el = resultEl();
        if (!el) return;
        el.textContent = 'Querying xAI and internal logs...';
        var url = '/ai/grok_balance';
        if (declareVal == null || declareVal === '') declareVal = declareValue();
        if (declareVal) url += '?declare_balance=' + encodeURIComponent(declareVal);
        fetch(url, { credentials: 'include' })
            .then(function (r) { return r.json(); })
            .then(function (data) {
                el.textContent = data.success ? JSON.stringify(data, null, 2) : ('Error: ' + (data.error || 'Unknown'));
            })
            .catch(function (e) { el.textContent = e.message; });
    }

    function postForm(url, fields) {
        var body = new URLSearchParams();
        Object.keys(fields).forEach(function (k) {
            if (fields[k] != null) body.append(k, fields[k]);
        });
        return fetch(url, {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: body.toString()
        }).then(function (r) { return r.json(); });
    }

    function killModel(provider, model, reason, notes) {
        var out = document.getElementById('usage-kill-result');
        return postForm('/ai/usage_kill', {
            action: 'kill', provider: provider, model: model, reason: reason || 'other', notes: notes || ''
        }).then(function (data) {
            if (out) out.textContent = data.success ? ('Killed ' + provider + '/' + model) : (data.error || 'kill failed');
            if (data.success) window.location.reload();
        }).catch(function (e) { if (out) out.textContent = e.message; });
    }

    function loadGrokCom() {
        try {
            var raw = window.localStorage.getItem('comserv_grokcom_usage');
            if (!raw) return null;
            var o = JSON.parse(raw);
            if (!o || (o.build == null && o.chat == null)) return null;
            return o;
        } catch (e) { return null; }
    }

    function paintGrokCom() {
        var o = loadGrokCom();
        var bEl = document.getElementById('declare-grokcom-build');
        var cEl = document.getElementById('declare-grokcom-chat');
        if (o && bEl && o.build != null) bEl.value = o.build;
        if (o && cEl && o.chat != null) cEl.value = o.chat;
    }

    function saveGrokCom() {
        var b = document.getElementById('declare-grokcom-build');
        var c = document.getElementById('declare-grokcom-chat');
        var build = b ? Number(b.value) : NaN;
        var chat = c ? Number(c.value) : NaN;
        if (!(build >= 0 && build <= 100) || !(chat >= 0 && chat <= 100)) {
            window.alert('Enter Build % and Chat % from grok.com Settings → Usage (0–100).');
            return;
        }
        var o = { build: build, chat: chat, at: new Date().toISOString() };
        try { window.localStorage.setItem('comserv_grokcom_usage', JSON.stringify(o)); } catch (e) {}
        paintGrokCom();
        refreshGuard();
    }

    function parseJsonResponse(r) {
        return r.text().then(function (text) {
            var t = (text || '').replace(/^\uFEFF/, '').trim();
            if (!t || t.charAt(0) !== '{') return null;
            try { return JSON.parse(t); } catch (e) { return null; }
        });
    }

    function refreshGrokComFile() {
        fetch('/static/ai/grokcom_usage.json', { credentials: 'same-origin', cache: 'no-store' })
            .then(parseJsonResponse)
            .then(function (d) {
                if (!d || !d.ok) return;
                if (!(d.build >= 0 && d.build <= 100) && !(d.chat >= 0 && d.chat <= 100)) return;
                try {
                    window.localStorage.setItem('comserv_grokcom_usage', JSON.stringify({
                        build: d.build,
                        chat: d.chat,
                        at: d.at || new Date().toISOString(),
                        source: 'firefox'
                    }));
                } catch (e) {}
                paintGrokCom();
                refreshGuard();
            })
            .catch(function () {});
    }

    function refreshGuard() {
        fetch('/static/ai/supergrok_guard.json', { credentials: 'same-origin', cache: 'no-store' })
            .then(parseJsonResponse)
            .then(function (d) {
                if (d && d.ok) {
                    paintSuperGrok(d);
                    return;
                }
                return fetch('/static/ai/grokcom_usage_history.jsonl', { credentials: 'same-origin', cache: 'no-store' })
                    .then(function (r) { return r.text(); })
                    .then(function (text) {
                        var o = loadGrokCom() || {};
                        if (typeof o.build !== 'number') return;
                        paintSuperGrok(computeGuard(o.build, text));
                    });
            })
            .catch(function () {
                var o = loadGrokCom() || {};
                if (typeof o.build === 'number') paintSuperGrok(computeGuard(o.build, ''));
            });
    }

    function paintAgents(agents) {
        (agents || []).forEach(function (a) {
            if (!a || !AGENT_IDS[a.id]) return;
            var st = document.querySelector('[data-agent-status="' + a.id + '"]');
            var det = document.querySelector('[data-agent-detail="' + a.id + '"]');
            if (st) st.textContent = a.status || '';
            if (det) det.textContent = a.detail || '';
        });
    }

    function applyOrg(o, source) {
        lastOrg = o;
        var ot = o.org_totals || {};
        var ht = (o.hermes && o.hermes.totals) || {};
        setText('usage-kpi-calls', fmt(ot.hermes_calls || ot.calls || ht.api_calls || 0));
        setText('usage-kpi-calls-sub', 'Hermes API ' + fmt(ht.api_calls || 0) + ' · app ' + fmt(ot.app_calls || 0));
        setText('usage-kpi-tokens', fmt(ht.tokens || ot.tokens || 0));
        setText('usage-kpi-tokens-sub', 'cache + reasoning included');
        var or = o.openrouter || {};
        if (or.ok) {
            if (or.remaining != null && or.remaining !== '') {
                setText('usage-kpi-or', '$' + Number(or.remaining).toFixed(2) + ' left');
            } else {
                setText('usage-kpi-or', 'used $' + Number(or.usage || 0).toFixed(2));
            }
            setText('usage-kpi-or-sub', 'live OpenRouter · add money when empty'
                + (or.limit != null ? (' · cap $' + Number(or.limit).toFixed(2)) : ''));
        }
        paintGrokCom();
        paintAgents(o.agents);
        renderChartsFromOrg(o);
        var stamp = document.getElementById('usage-live-stamp');
        if (stamp) {
            stamp.textContent = (source && source.indexOf('snapshot') !== -1 ? 'Snapshot ' : 'Live ')
                + new Date().toISOString()
                + ' · ' + fmt(ht.api_calls || 0) + ' Hermes API · ' + fmt(ht.tokens || 0) + ' tokens';
        }
        if (window.location.hash && window.location.hash.indexOf('#agent-') === 0) {
            showTunnel(window.location.hash.replace('#agent-', ''));
        }
    }

    function showTunnel(id) {
        var empty = document.getElementById('usage-tunnel-empty');
        var body = document.getElementById('usage-tunnel-body');
        if (!body) return;
        var o = lastOrg || {};
        var days = last14Days();
        var map = collectSourceDays(o);
        var html = '';
        var srcIds = { tui: 1, cli: 1, oneshot: 1, chat: 1, editor: 1, grok_bot: 1 };
        if (srcIds[id]) {
            var meta = SOURCES.filter(function (s) { return s.id === id; })[0] || { label: id };
            html += '<h3>' + esc(meta.label) + ' — 14 days</h3>';
            html += '<div style="overflow-x:auto;"><table class="data-table"><thead><tr><th>Day</th><th>Tokens</th><th>API</th></tr></thead><tbody>';
            var tTok = 0, tApi = 0, n = 0;
            days.forEach(function (day) {
                var cell = (map[id] || {})[day] || {};
                var tok = Number(cell.tokens || 0), api = Number(cell.calls || 0);
                tTok += tok; tApi += api;
                if (tok || api) n += 1;
                html += '<tr><td>' + esc(day) + '</td><td>' + fmt(tok) + '</td><td>' + fmt(api) + '</td></tr>';
            });
            html += '</tbody></table></div>';
            html += '<p class="doc-muted">' + n + ' of 14 days had traffic · ' + fmt(tTok) + ' tokens · ' + fmt(tApi) + ' API.</p>';
        }
        if (id === 'hermes') {
            var h = o.hermes || {};
            html += '<h3>Hermes models (top)</h3>';
            html += '<div style="overflow-x:auto;"><table class="data-table"><thead><tr><th>Model</th><th>API</th><th>Tokens</th></tr></thead><tbody>';
            (h.by_model || []).slice(0, 8).forEach(function (r) {
                html += '<tr><td>' + esc(r.model) + '</td><td>' + fmt(r.api_calls || r.calls)
                    + '</td><td>' + fmt(r.tokens) + '</td></tr>';
            });
            html += '</tbody></table></div>';
            html += '<p class="doc-muted">TUI / CLI / oneshot are separate colours on the charts (open Charts). Click those chips for a 14-day table.</p>';
        } else if ((id === 'chat' || id === 'editor') && !html) {
            html += '<h3>' + (id === 'chat' ? 'AI Chat' : 'AI Editor') + '</h3>';
            html += '<p class="doc-muted">No app-ledger rows in this snapshot. Bars stay at zero until UsageMonitor is live.</p>';
        } else if (id === 'grok_bot') {
            html += '<p class="doc-muted">Local process only — no Grok API. Daily evals: <a href="/ai/eval" style="color:var(--link-color);">/ai/eval</a>.</p>';
        }
        if (empty) empty.hidden = true;
        body.hidden = false;
        body.innerHTML = html || '<p class="doc-muted">Nothing for ' + esc(id) + '</p>';
        if (history.replaceState) history.replaceState(null, '', '#agent-' + id);
    }

    function refreshLive() {
        var stamp = document.getElementById('usage-live-stamp');
        var q = window.location.search || '';
        var urls = ['/ai2/usage_live' + q, '/ai/usage_live' + q, '/static/ai/usage_snapshot.json'];
        function tryAt(i) {
            if (i >= urls.length) {
                if (stamp) stamp.textContent = 'No usage JSON.';
                return;
            }
            fetch(urls[i], { credentials: 'include' })
                .then(function (r) {
                    return parseJsonResponse(r).then(function (data) { return { data: data, url: urls[i] }; });
                })
                .then(function (pack) {
                    if (!pack.data || !pack.data.success || !pack.data.org) {
                        tryAt(i + 1);
                        return;
                    }
                    applyOrg(pack.data.org, pack.url.split('?')[0]);
                })
                .catch(function () { tryAt(i + 1); });
        }
        tryAt(0);
    }

    document.addEventListener('click', function (ev) {
        var t = ev.target;
        if (!t) return;
        var typeBtn = t.closest && t.closest('[data-chart-type]');
        if (typeBtn) {
            ev.preventDefault();
            setChartType(typeBtn.getAttribute('data-chart-type'));
            return;
        }
        var chip = t.closest && t.closest('[data-source-focus]');
        if (chip) {
            var sid = chip.getAttribute('data-source-focus');
            focusSource = (focusSource === sid) ? null : sid;
            if (lastOrg) renderChartsFromOrg(lastOrg);
            showTunnel(sid);
            return;
        }
        var row = t.closest && t.closest('[data-tunnel]');
        if (row && t.tagName !== 'A') {
            ev.preventDefault();
            showTunnel(row.getAttribute('data-tunnel'));
            return;
        }
        if (t.getAttribute && t.getAttribute('data-check-grok')) {
            ev.preventDefault();
            checkLiveGrokBalance();
            return;
        }
        if (t.getAttribute && t.getAttribute('data-declare-grok')) {
            ev.preventDefault();
            var val = declareValue();
            if (!val) { window.alert('Enter balance from console.x.ai first.'); return; }
            checkLiveGrokBalance(val);
            return;
        }
        if (t.getAttribute && t.getAttribute('data-declare-grokcom')) {
            ev.preventDefault();
            saveGrokCom();
            return;
        }
        if (t.getAttribute && t.getAttribute('data-unkill-model')) {
            ev.preventDefault();
            postForm('/ai/usage_kill', {
                action: 'unkill',
                provider: t.getAttribute('data-provider'),
                model: t.getAttribute('data-model')
            }).then(function (data) {
                if (data.success) window.location.reload();
                else window.alert(data.error || 'unkill failed');
            });
        }
    });

    document.addEventListener('submit', function (ev) {
        var form = ev.target;
        if (!form || form.id !== 'usage-kill-form') return;
        ev.preventDefault();
        killModel(form.provider.value, form.model.value, form.reason.value, '');
    });

    if (document.querySelector('[data-usage-chart]') || document.getElementById('usage-overview')) {
        paintChartToggle();
        paintGrokCom();
        refreshGrokComFile();
        refreshGuard();
        refreshLive();
        window.setInterval(refreshLive, 20000);
        window.setInterval(refreshGrokComFile, 20000);
        window.setInterval(refreshGuard, 20000);
        if (window.location.hash && window.location.hash.indexOf('#agent-') === 0) {
            showTunnel(window.location.hash.replace('#agent-', ''));
        }
    }
}());
