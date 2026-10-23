/* Persist current grok.com Usage % and record each change. No cookies. */
var lastKey = null;
var lastNativeAt = 0;
// Oct 14 2026: post to the aisystem app first (:4006), then other local ports,
// then the native host as last fallback. Never :3001.
var APP_PORTS = [4006, 4003, 4001];

function postOne(port, payload) {
    return fetch('http://127.0.0.1:' + port + '/ai/usage_auto', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Comserv-Grokcom': '1' },
        body: JSON.stringify(payload)
    }).then(function (r) {
        if (!r.ok) throw new Error('http ' + r.status);
        return r.json();
    }).then(function (j) {
        if (!j || (j.ok === false && j.error !== 'no_percent')) throw new Error('rejected');
        return { port: port, reply: j };
    });
}

function postToApp(payload) {
    var i = 0;
    function next() {
        if (i >= APP_PORTS.length) {
            return browser.runtime.sendNativeMessage('comserv_grokcom_usage', payload)
                .then(function (j) { return { port: 'native', reply: j }; });
        }
        var port = APP_PORTS[i++];
        return postOne(port, payload).catch(next);
    }
    return next().then(function (res) {
        return browser.storage.local.set({ lastPost: { port: res.port, reply: res.reply, at: new Date().toISOString() } });
    });
}

function payloadKey(p) {
    return String(p && p.build) + ':' + String(p && p.chat) + ':' + String(p && p.bot);
}

function record(payload, reason) {
    if (!payload) return Promise.resolve();
    var key = payloadKey(payload);
    var changed = key !== lastKey;
    var now = Date.now();
    var heartbeat = (now - lastNativeAt) > 5 * 60 * 1000;
    if (!changed && !heartbeat && lastKey !== null) {
        return browser.storage.local.set({ current: payload }).then(function () {});
    }
    lastKey = key;
    lastNativeAt = now;
    payload.reason = reason || (changed ? 'change' : 'heartbeat');
    return browser.storage.local.get({ history: [] }).then(function (st) {
        var history = Array.isArray(st.history) ? st.history : [];
        if (changed) {
            history.push({
                build: payload.build,
                chat: payload.chat,
                bot: payload.bot,
                at: payload.at,
                href: payload.href
            });
            if (history.length > 200) history = history.slice(-200);
        }
        return browser.storage.local.set({ current: payload, history: history, lastKey: key });
    }).then(function () {
        return postToApp(payload);
    }).catch(function () {
        lastNativeAt = 0;
    });
}

browser.storage.local.get({ lastKey: null, current: null }).then(function (st) {
    lastKey = st.lastKey || (st.current ? payloadKey(st.current) : null);
});

browser.runtime.onMessage.addListener(function (msg) {
    if (!msg || msg.type !== 'grokcom_usage' || !msg.payload) return;
    record(msg.payload, 'page');
});

window.setInterval(function () {
    browser.storage.local.get({ current: null }).then(function (st) {
        if (st.current) record(st.current, 'heartbeat');
    });
}, 5 * 60 * 1000);
