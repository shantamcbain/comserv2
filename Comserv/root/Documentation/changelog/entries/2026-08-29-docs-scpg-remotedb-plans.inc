<div id="2026-08-29-docs-scpg-remotedb-plans" class="cl-entry">
<h3>2026-08-29 — Docs: SCPG-REMOTEDB done across plans + RemoteDB API notes</h3>
<p class="doc-body"><strong>What.</strong> Plan and API docs updated for the RemoteDB
  <code>from_context</code> / PostgreSQL allowlist work (todos #2343, #2325, #2326).
  Marked <strong>SCPG-REMOTEDB DONE</strong> on SchemaComparePostgresPlan; noted partial
  G1 progress on MASTER_PLAN, SchemaSystemPlan, and SchemaMasterPlan; expanded
  models/RemoteDB and controllers/RemoteDB with the locked caller rule.</p>
<p class="doc-body"><strong>Why.</strong> After the code fix, plans still described
  Invalid db_type and “compare cannot connect,” which would mislead the next
  agent into redoing RemoteDB instead of starting SCPG-COMPARE.</p>
<p class="doc-body"><strong>Files.</strong>
  <code>root/Documentation/SchemaComparePostgresPlan.tt</code>,
  <code>root/Documentation/MASTER_PLAN.tt</code>,
  <code>root/Documentation/SchemaSystemPlan.tt</code>,
  <code>root/Documentation/SchemaMasterPlan.tt</code>,
  <code>root/Documentation/models/RemoteDB.tt</code>,
  <code>root/Documentation/controllers/RemoteDB.tt</code></p>
</div>
