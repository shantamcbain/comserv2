<div id="2026-09-24-aimps-usage-surface-latency" class="cl-entry">
<h3>2026-09-24 — AI usage logs surface, role, and latency (#2030)</h3>
<p class="doc-body"><strong>What.</strong> Every <code>/ai2/chat</code> LLM call now writes <code>duration_ms</code> plus metadata <code>surface</code> (chat vs editor), <code>role</code>, and <code>agent_id</code> into <code>ai_usage_logs</code> on success, provider error, and fallback hops.</p>
<p class="doc-body"><strong>Why.</strong> AIMPS telemetry asked for resolved model, provider, surface, role, latency, and success/failure in the DB, not only an application.log line.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/Chat.pm</code>, <code>lib/Comserv/Controller/AI2.pm</code></p>
</div>
