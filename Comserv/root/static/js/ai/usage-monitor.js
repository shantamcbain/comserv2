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
        }
    });
}());
