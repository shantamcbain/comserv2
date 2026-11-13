/* Pages editor AI Assist + Write with AI (Nov 5 2026).
   AI output is a preview only: Insert / Replace / Discard. Nothing is saved
   until the user presses the form's own Save/Create button, except
   "Save as draft", which creates a NEW hidden draft page via /pages/ai_draft. */
(function () {
    'use strict';
    function $(id) { return document.getElementById(id); }
    function val(id) { var e = $(id); return e ? e.value : ''; }
    function setVal(id, v) { var e = $(id); if (e && v !== undefined && v !== null && v !== '') { e.value = v; e.dispatchEvent(new Event('input', { bubbles: true })); } }
    function post(url, data) {
        var body = new URLSearchParams();
        Object.keys(data).forEach(function (k) { if (data[k] !== undefined && data[k] !== null) body.append(k, data[k]); });
        return fetch(url, { method: 'POST', credentials: 'same-origin', body: body,
            headers: { 'Accept': 'application/json' } })
            .then(function (r) { return r.json().catch(function () { return { success: 0, error: 'HTTP ' + r.status }; }); });
    }
    function surface() { return $('page-editor-surface'); }
    function textarea() { return $('body'); }
    function visualMode() { var s = surface(); return s && s.offsetParent !== null; }

    var savedRange = null, savedText = '';
    function rememberSelection() {
        var sel = window.getSelection(), s = surface();
        if (visualMode() && sel && sel.rangeCount && s && s.contains(sel.anchorNode) && !sel.isCollapsed) {
            savedRange = sel.getRangeAt(0).cloneRange();
            var d = document.createElement('div'); d.appendChild(savedRange.cloneContents());
            savedText = d.innerHTML; return;
        }
        var t = textarea();
        if (!visualMode() && t && t.selectionEnd > t.selectionStart) {
            savedRange = { start: t.selectionStart, end: t.selectionEnd };
            savedText = t.value.substring(t.selectionStart, t.selectionEnd); return;
        }
        savedRange = null; savedText = '';
    }
    function wholeBody() { var t = textarea(); return t ? t.value : ''; }
    function writeBody(html) { var t = textarea(); if (!t) return; t.value = html; t.dispatchEvent(new Event('input', { bubbles: true })); }
    function put(html, replace) {
        var t = textarea(); if (!t) return;
        if (savedRange && savedRange.start !== undefined) {
            var a = t.value.substring(0, savedRange.start), b = t.value.substring(replace ? savedRange.end : savedRange.start);
            writeBody(a + html + b);
        } else if (savedRange && visualMode()) {
            var frag = document.createRange().createContextualFragment(html);
            if (replace) savedRange.deleteContents(); else savedRange.collapse(false);
            savedRange.insertNode(frag);
            surface().dispatchEvent(new Event('input', { bubbles: true }));
            // keep the textarea in step so Save sends what the user sees
            var form = t.closest('form'); if (form) form.dispatchEvent(new Event('page-ai-sync'));
        } else {
            writeBody(replace ? html : (wholeBody() + '\n' + html));
        }
        savedRange = null; savedText = '';
    }

    var lastHtml = '';
    function initAssist() {
        var box = $('page-ai-assist'); if (!box) return;
        var status = $('page-ai-status'), prev = $('page-ai-preview');
        box.addEventListener('mousedown', function (e) { if (e.target.closest('[data-ai-action]')) rememberSelection(); });
        box.querySelectorAll('[data-ai-action]').forEach(function (btn) {
            btn.addEventListener('click', function () {
                var action = btn.getAttribute('data-ai-action');
                var text = savedText || wholeBody();
                status.textContent = action === 'links' ? 'Finding pages…' : 'Asking the writing model…';
                $('page-ai-links').innerHTML = ''; $('page-ai-preview-body').innerHTML = '';
                var common = { sitename: val('sitename'), title: val('title'), page_code: box.getAttribute('data-page-code') || val('page_code'), text: text };
                var url = action === 'links' ? '/pages/ai_links' : '/pages/ai_assist';
                if (action !== 'links') { common.action = action; common.notes = val('page-ai-notes'); }
                post(url, common).then(function (r) {
                    if (!r || !r.success) { status.textContent = (r && r.error) || 'AI assist failed'; return; }
                    status.textContent = '';
                    prev.hidden = false;
                    if (action === 'links') {
                        lastHtml = '';
                        $('page-ai-model').textContent = '(from your site pages)';
                        var ul = document.createElement('ul');
                        (r.links || []).forEach(function (l) {
                            var li = document.createElement('li'), b = document.createElement('button');
                            b.type = 'button'; b.className = 'page-fmt-btn'; b.textContent = 'Insert link';
                            b.addEventListener('click', function () {
                                var a = document.createElement('a'); a.href = l.url; a.textContent = l.title;
                                put(a.outerHTML, false);
                            });
                            li.appendChild(b); li.appendChild(document.createTextNode(' ' + l.title + ' (' + l.url + ')'));
                            ul.appendChild(li);
                        });
                        $('page-ai-links').appendChild(ul);
                        if (r.placement) {
                            var p = document.createElement('p');
                            p.textContent = 'Suggested placement: menu "' + r.placement.menu + '"' + (r.placement.submenu ? ', submenu "' + r.placement.submenu + '"' : '') + ', link order ' + r.placement.link_order + '. ';
                            var ap = document.createElement('button'); ap.type = 'button'; ap.className = 'page-fmt-btn'; ap.textContent = 'Use this placement';
                            ap.addEventListener('click', function () { setVal('menu', r.placement.menu); setVal('submenu', r.placement.submenu); setVal('link_order', r.placement.link_order); });
                            p.appendChild(ap); $('page-ai-links').appendChild(p);
                        }
                        $('page-ai-insert').hidden = $('page-ai-replace').hidden = true;
                        return;
                    }
                    lastHtml = r.html || '';
                    $('page-ai-model').textContent = r.model ? '(' + r.model + ')' : '';
                    $('page-ai-preview-body').innerHTML = lastHtml;   // already cleaned server-side
                    $('page-ai-insert').hidden = $('page-ai-replace').hidden = false;
                    box._pendingSel = { range: savedRange, text: savedText };
                }).catch(function () { status.textContent = 'AI assist failed (network)'; });
            });
        });
        function restoreSel() { if (box._pendingSel) { savedRange = box._pendingSel.range; savedText = box._pendingSel.text; } }
        $('page-ai-insert').addEventListener('click', function () { restoreSel(); if (lastHtml) put(lastHtml, false); prev.hidden = true; });
        $('page-ai-replace').addEventListener('click', function () { restoreSel(); if (lastHtml) put(lastHtml, true); prev.hidden = true; });
        $('page-ai-discard').addEventListener('click', function () { lastHtml = ''; box._pendingSel = null; prev.hidden = true; });
    }

    function initWriter() {
        var btn = $('page-ai-write-btn'); if (!btn) return;
        var st = $('page-ai-writer-status');
        btn.addEventListener('click', function () {
            st.textContent = 'Writing…';
            post('/pages/ai_write', { sitename: val('sitename'), topic: val('page-ai-topic'), notes: val('page-ai-writer-notes') })
                .then(function (r) {
                    if (!r || !r.success) { st.textContent = (r && r.error) || 'AI writer failed'; return; }
                    var p = r.page || {};
                    setVal('title', p.title); setVal('page_code', p.page_code); setVal('description', p.description); setVal('keywords', p.keywords);
                    if (r.placement) { setVal('menu', r.placement.menu); setVal('submenu', r.placement.submenu); setVal('link_order', r.placement.link_order); }
                    writeBody(p.body || '');
                    setVal('status', 'draft');
                    st.textContent = 'Filled in by ' + (r.model || 'AI') + '. Review it, then press Create (status is set to Draft).';
                }).catch(function () { st.textContent = 'AI writer failed (network)'; });
        });
        var d = $('page-ai-draft-btn');
        if (d) d.addEventListener('click', function () {
            st.textContent = 'Saving draft…';
            post('/pages/ai_draft', { sitename: val('sitename'), title: val('title'), page_code: val('page_code'), body: wholeBody(),
                description: val('description'), keywords: val('keywords'), menu: val('menu'), submenu: val('submenu'), link_order: val('link_order') })
                .then(function (r) {
                    if (!r || !r.success) { st.textContent = (r && r.error) || 'Draft save failed'; return; }
                    st.innerHTML = ''; var a = document.createElement('a'); a.href = r.edit_url; a.textContent = 'Draft saved: open ' + r.page_code;
                    st.appendChild(a);
                }).catch(function () { st.textContent = 'Draft save failed (network)'; });
        });
    }

    function init() { initAssist(); initWriter(); }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
