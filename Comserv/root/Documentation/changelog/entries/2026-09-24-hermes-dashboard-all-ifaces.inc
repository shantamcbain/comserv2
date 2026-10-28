<div id="2026-09-24-hermes-dashboard-all-ifaces" class="cl-entry">
<h3>2026-09-24 — Hermes dashboard :9119 on localhost, .local, .zero, ZeroTier</h3>
<p class="doc-body"><strong>What.</strong> AI Editor Hermes panel builds <code>http://&lt;page-hostname&gt;:9119/chat</code> so localhost, workstation.local, workstation.zero, and the ZeroTier IP all work. Server probes 127.0.0.1 (always reachable) but returns the browser host. Dashboard rebound to <code>0.0.0.0:9119</code>; firewall opened for LAN + ZeroTier.</p>
<p class="doc-body"><strong>Why.</strong> Default <code>hermes dashboard</code> bind is loopback-only, so phones/tablets/laptops on ZeroTier could not open :9119. Hardcoding 127.0.0.1 in the iframe is the client&apos;s own loopback, not the workstation.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/static/js/ai2editor/hermes-run.js</code>, <code>Controller/AI2.pm</code>, <code>root/ai2/editor/editing_widget_popup.tt</code>.</p>
</div>
