<div id="2026-09-24-dedupe-planning-personas" class="cl-entry">
<h3>2026-09-24 — One Planning persona in the agent picker</h3>
<p class="doc-body"><strong>What.</strong> Planning Assistant, Project Manager, and Task Assistant were three picker rows for the same job. The picker now shows Planning Assistant only. <code>todo</code> / <code>projects</code> are hidden aliases; Chat maps them to <code>planning</code>. Saved widget agent todo/projects remaps to planning.</p>
<p class="doc-body"><strong>Why.</strong> #2258 dedupe picker personas.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/static/config/agents.json</code> <code>root/static/js/local-chat.js</code> <code>lib/Comserv/Model/AI2/Chat.pm</code></p>
</div>
