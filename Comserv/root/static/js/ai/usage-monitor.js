(function () {
    function resultEl() {
        return document.getElementById('grok-live-result');
    }

    function declareValue() {
        var input = document.getElementById('declare-xai-balance');
        return input ? String(input.value || '').trim() : '';
    }

    function checkLiveGrokBalance(declareVal) {
        var el = resultEl();
        if (!el) return;
        el.textContent = 'Querying xAI and internal logs...';
        var url = '/ai/grok_balance';
        if (declareVal == null || declareVal === '') {
            declareVal = declareValue();
        }
        if (declareVal) {
            url += '?declare_balance=' + encodeURIComponent(declareVal);
        }
        fetch(url, { credentials: 'include' })
            .then(function (r) { return r.json(); })
            .then(function (data) {
                var html = '';
                if (data.success) {
                    html += 'Key source: ' + (data.key_source || 'unknown') + '\n';
                    if (data.supergrok && data.supergrok.pct != null) {
                        html += 'SuperGrok month: ' + data.supergrok.pct + '% ($'
                            + (data.supergrok.spend_usd || '0') + ' / $'
                            + (data.supergrok.limit_usd || '0') + ', '
                            + (data.supergrok.calls || 0) + ' calls)\n';
                    }
                    if (data.live && !data.live.error) {
                        html += 'Live from xAI:\n' + JSON.stringify(data.live, null, 2) + '\n\n';
                    } else if (data.live && data.live.error) {
                        html += 'Live xAI error: ' + data.live.error + '\n';
                    }
                    if (data.internal && data.internal.declared_balance != null) {
                        var decl = data.internal.declared_balance;
                        var spent = data.internal.estimated_spend_since_declared || 0;
                        html += 'Declared xAI balance: $' + decl + '\n';
                        html += 'Tracked spend since declaration: $' + spent + '\n';
                    }
                    html += 'Our tracking (last ~30d Grok): calls='
                        + ((data.internal && data.internal.real_grok_calls) || 0)
                        + ' cost=$' + ((data.internal && data.internal.real_grok_cost) || '0') + '\n';
                    if (data.alert) {
                        html += '\nALERT: ' + (data.alert_msg || 'High SuperGrok/xAI usage');
                        window.alert('SuperGrok / xAI: ' + (data.alert_msg || 'Check /ai/usage'));
                    }
                } else {
                    html = 'Error: ' + (data.error || 'Unknown');
                }
                el.textContent = html;
            })
            .catch(function (e) {
                el.textContent = 'Error fetching /ai/grok_balance:\n' + e.message;
            });
    }

    function cssVar(name, fallback) {
        var v = window.getComputedStyle(document.documentElement).getPropertyValue(name);
        return (v && v.trim()) || fallback;
    }

    function mergeDays(appDays, hermesDays) {
        var map = {};
        function add(list, prefix) {
            (list || []).forEach(function (r) {
                var d = r.day;
                if (!map[d]) map[d] = { day: d, tokens: 0, cost: 0, calls: 0 };
                map[d].tokens += Number(r.tokens || 0);
                map[d].cost += Number(r.cost || 0);
                map[d].calls += Number(r.calls || 0);
            });
        }
        add(appDays);
        add(hermesDays);
        return Object.keys(map).sort().map(function (k) { return map[k]; });
    }

    function drawLine(canvas, points, key) {
        if (!canvas || !canvas.getContext) return;
        var ctx = canvas.getContext('2d');
        var w = canvas.width, h = canvas.height;
        ctx.clearRect(0, 0, w, h);
        var vals = (points || []).map(function (p) { return Number(p[key] || 0); });
        if (!vals.length) {
            ctx.fillStyle = cssVar('--text-color', '#666');
            ctx.fillText('No data', 12, 24);
            return;
        }
        var max = Math.max.apply(null, vals.concat([1]));
        var pad = 28;
        ctx.strokeStyle = cssVar('--border-color', '#ccc');
        ctx.beginPath();
        ctx.moveTo(pad, 8);
        ctx.lineTo(pad, h - pad);
        ctx.lineTo(w - 8, h - pad);
        ctx.stroke();
        ctx.strokeStyle = cssVar('--primary-color', '#2a6');
        ctx.lineWidth = 2;
        ctx.beginPath();
        vals.forEach(function (v, i) {
            var x = pad + (i * ((w - pad - 8) / Math.max(vals.length - 1, 1)));
            var y = (h - pad) - (v / max) * (h - pad - 16);
            if (i === 0) ctx.moveTo(x, y);
            else ctx.lineTo(x, y);
        });
        ctx.stroke();
        ctx.fillStyle = cssVar('--text-color', '#444');
        ctx.font = '11px sans-serif';
        ctx.fillText(String(max), 2, 14);
        ctx.fillText(points[0].day || '', pad, h - 8);
        ctx.fillText(points[points.length - 1].day || '', w - 80, h - 8);
    }

    function loadChartJson() {
        var el = document.getElementById('usage-chart-data');
        if (!el) return { app_days: [], hermes_days: [] };
        try { return JSON.parse(el.textContent); } catch (e) { return { app_days: [], hermes_days: [] }; }
    }

    function renderCharts(data) {
        data = data || loadChartJson();
        var merged = mergeDays(data.app_days, data.hermes_days);
        drawLine(document.getElementById('usage-tokens-chart'), merged, 'tokens');
        drawLine(document.getElementById('usage-cost-chart'), merged, 'cost');
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
        }).catch(function (e) {
            if (out) out.textContent = e.message;
        });
    }

    function refreshLive() {
        var stamp = document.getElementById('usage-live-stamp');
        fetch('/ai/usage_live' + window.location.search, { credentials: 'include' })
            .then(function (r) { return r.json(); })
            .then(function (data) {
                if (!data.success || !data.org) {
                    if (stamp) stamp.textContent = 'Live refresh failed: ' + (data.error || 'unknown');
                    return;
                }
                var o = data.org;
                var ot = o.org_totals || {};
                if (stamp) {
                    stamp.textContent = 'Live ' + new Date().toISOString()
                        + ' · org calls ' + (ot.calls || 0)
                        + ' · tokens app ' + ((o.totals && o.totals.tokens) || 0)
                        + ' + hermes ' + ((o.hermes && o.hermes.totals && o.hermes.totals.tokens) || 0)
                        + ' · $' + (ot.cost || '0');
                }
                renderCharts({
                    app_days: (o.by_day || []).map(function (r) {
                        return { day: r.day, tokens: r.tokens, cost: r.cost, calls: r.calls };
                    }),
                    hermes_days: ((o.hermes && o.hermes.by_day) || []).map(function (r) {
                        return { day: r.day, tokens: r.tokens, cost: r.cost, calls: r.calls };
                    })
                });
            })
            .catch(function (e) {
                if (stamp) stamp.textContent = 'Live refresh error: ' + e.message;
            });
    }

    document.addEventListener('click', function (ev) {
        var t = ev.target;
        if (!t || !t.getAttribute) return;
        if (t.getAttribute('data-check-grok')) {
            ev.preventDefault();
            checkLiveGrokBalance();
            return;
        }
        if (t.getAttribute('data-declare-grok')) {
            ev.preventDefault();
            var val = declareValue();
            if (!val) {
                window.alert('Enter your current balance from console.x.ai first.');
                return;
            }
            checkLiveGrokBalance(val);
            return;
        }
        if (t.getAttribute('data-kill-model')) {
            ev.preventDefault();
            killModel(
                t.getAttribute('data-provider'),
                t.getAttribute('data-model'),
                t.getAttribute('data-reason') || 'other',
                ''
            );
            return;
        }
        if (t.getAttribute('data-unkill-model')) {
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
        killModel(
            form.provider.value,
            form.model.value,
            form.reason.value,
            form.notes.value
        );
    });

    if (document.querySelector('[data-usage-chart]')) {
        renderCharts();
        refreshLive();
        window.setInterval(refreshLive, 20000);
    }
}());
