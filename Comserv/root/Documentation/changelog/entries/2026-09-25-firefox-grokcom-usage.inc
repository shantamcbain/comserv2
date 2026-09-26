<div id="2026-09-25-firefox-grokcom-usage" class="cl-entry">
<h3>2026-09-25 — Firefox grok.com usage numbers (no cookies)</h3>
<p class="doc-body"><strong>What.</strong> Optional Firefox add-on reads SuperGrok Build/Chat % from the already-open grok.com Settings → Usage tab and writes numbers only to <code>/static/ai/grokcom_usage.json</code>. <code>/ai/usage</code> polls that file.</p>
<p class="doc-body"><strong>Why.</strong> grok.com is not x.ai; the app cannot use grok.com cookies. The tab is already open in Firefox — a same-origin content script can see the visible % without copying the session.</p>
<p class="doc-body"><strong>Files.</strong> <code>script/firefox-grokcom-usage/</code> <code>root/static/js/ai/usage-monitor.js</code></p>
</div>
