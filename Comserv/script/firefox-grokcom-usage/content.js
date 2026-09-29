/* Watch grok.com Settings → Usage. Read visible %. Never touch cookies. */
(function () {
    var timer = null;

    function scrape() {
        var text = (document.body && document.body.innerText) || '';
        text = String(text).replace(/\s+/g, ' ');
        var build = null;
        var chat = null;
        var m = text.match(/\bBuild\b[^%]{0,120}?(\d{1,3})\s*%/i);
        if (m) build = Number(m[1]);
        m = text.match(/\bChat\b[^%]{0,120}?(\d{1,3})\s*%/i);
        if (m) chat = Number(m[1]);
        if (build == null) {
            m = text.match(/\b(coding|code)\b[^%]{0,120}?(\d{1,3})\s*%/i);
            if (m) build = Number(m[2]);
        }
        var buildOk = typeof build === 'number' && build >= 0 && build <= 100;
        var chatOk = typeof chat === 'number' && chat >= 0 && chat <= 100;
        if (!buildOk && !chatOk) return null;
        return {
            build: buildOk ? build : null,
            chat: chatOk ? chat : null,
            href: location.href,
            title: document.title || '',
            at: new Date().toISOString()
        };
    }

    function send() {
        var row = scrape();
        if (!row) return;
        try { browser.runtime.sendMessage({ type: 'grokcom_usage', payload: row }); } catch (e) {}
    }

    function schedule() {
        if (timer) clearTimeout(timer);
        timer = setTimeout(send, 800);
    }

    send();
    window.setInterval(send, 15000);
    window.addEventListener('popstate', schedule);
    window.addEventListener('hashchange', schedule);
    document.addEventListener('visibilitychange', function () { if (!document.hidden) send(); });
    var obs = new MutationObserver(schedule);
    if (document.body) {
        obs.observe(document.body, { childList: true, subtree: true, characterData: true });
    }
}());
