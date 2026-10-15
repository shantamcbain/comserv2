/* Persist current grok.com Usage % and record each change. No cookies. */
var lastKey = null;
var lastNativeAt = 0;

function payloadKey(p) {
    return String(p && p.build) + ':' + String(p && p.chat);
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
                at: payload.at,
                href: payload.href
            });
            if (history.length > 200) history = history.slice(-200);
        }
        return browser.storage.local.set({ current: payload, history: history, lastKey: key });
    }).then(function () {
        return browser.runtime.sendNativeMessage('comserv_grokcom_usage', payload);
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
