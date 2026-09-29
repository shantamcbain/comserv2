<div id="2026-09-26-skip-auto-static" class="cl-entry">
<h3>2026-09-26 — Skip Root begin/auto for static and probe URLs</h3>
<p class="doc-body"><strong>What.</strong> <code>Root::begin</code> and <code>Root::auto</code> return immediately for <code>static/</code>, <code>favicon</code>, <code>robots.txt</code>, <code>sitemap.xml</code>, <code>ads.txt</code>, <code>llms.txt</code>, <code>.well-known/</code>. Those paths no longer run <code>fetch_and_set</code> / DB site setup (~1s each).</p>
<p class="doc-body"><strong>Why.</strong> <code>/planning/daily</code> itself was 2–3s. The browser then requested many JS files, each going through full auto, serialized on one worker and interleaved with WAN probes — minutes of blank/unstyled load.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Root.pm</code></p>
</div>
