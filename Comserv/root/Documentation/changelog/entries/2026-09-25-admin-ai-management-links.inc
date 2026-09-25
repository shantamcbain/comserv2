<div id="2026-09-25-admin-ai-management-links" class="cl-entry">
<h3>2026-09-25 — Admin AI card uses live /ai management routes</h3>
<p class="doc-body"><strong>What.</strong> Replaced <code>/admin/ai/configure</code> (redirect into <code>/ai/admin/models</code>) with the working AI management set: Usage/Activity Monitor <code>/ai/usage</code>, Model Management <code>/ai/models</code>, Agent Management <code>/ai/admin/agents</code>, API Keys, AI2 Chat, Chat History.</p>
<p class="doc-body"><strong>Why.</strong> The configure/admin-models paths did not open the operator pages; activity monitoring already lives at <code>/ai/usage</code>.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/admin/index.tt</code> <code>Comserv/root/Navigation/admintopmenu.tt</code></p>
</div>
