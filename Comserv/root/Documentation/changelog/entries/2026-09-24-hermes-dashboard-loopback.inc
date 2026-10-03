<div id="2026-09-24-hermes-dashboard-loopback" class="cl-entry">
<h3>2026-09-24 — AI Editor Hermes panel uses 127.0.0.1:9119/chat</h3>
<p class="doc-body"><strong>What.</strong> Hermes dashboard is bound to loopback only. The AI Editor was building <code>http://workstation.local:9119/sessions</code>, which cannot connect. Iframe, Detach, Load button, and <code>/ai2/hermes_run</code> probe now default to <code>http://127.0.0.1:9119/chat</code>.</p>
<p class="doc-body"><strong>Why.</strong> <code>hermes dashboard</code> default <code>--host 127.0.0.1</code>. <code>workstation.local</code> is 192.168.1.199 — nothing listens on :9119 there. Browser access to that URL fails; the editor Hermes panel looked dead.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/static/js/ai2editor/hermes-run.js</code>, <code>Controller/AI2.pm</code> <code>hermes_run</code>, <code>root/ai2/editor/editing_widget_popup.tt</code>.</p>
</div>
