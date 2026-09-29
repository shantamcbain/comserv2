<div id="2026-09-26-static-simple-dirs" class="cl-entry">
<h3>2026-09-26 — Restore /static CSS and JS after config lockdown</h3>
<p class="doc-body"><strong>What.</strong> Static::Simple again uses <code>include_path =&gt; ['root']</code> with <code>dirs =&gt; ['static','LegacyStaticPages']</code> so <code>/static/js</code> and <code>/static/css</code> map to <code>root/static/...</code>. <code>root/config</code> stays blocked via <code>dirs</code> + <code>ignore_dirs</code>.</p>
<p class="doc-body"><strong>Why.</strong> The same-day security change set <code>include_path =&gt; ['root/static']</code>, which resolved <code>/static/js/foo.js</code> to <code>root/static/static/js/foo.js</code>. CSS and JS 404'd (or never arrived if :3001 was also queued).</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv.pm</code></p>
</div>
