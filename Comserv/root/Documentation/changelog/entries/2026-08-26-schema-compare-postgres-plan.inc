<div id="2026-08-26-schema-compare-postgres-plan" class="cl-entry">
<h3>2026-08-26 — Schema-compare PostgreSQL connection plan</h3>
<p class="doc-body"><strong>What.</strong> Authored <code>SchemaComparePostgresPlan.tt</code> and tracking project #289 SCHEMAPG (sub-projects #290–294, todos #2323–2333). Schema-compare is Maria-only; RemoteDB skips postgresql; AccountingDB::provision_site needs a template DB that compare cannot create.</p>
<p class="doc-body"><strong>Why.</strong> Creating <code>inventory_purchase_order_lines</code> on InventoryAccounting exposed two problems: stale :4001 schema (Maria Result not registered) and the longer gap that no PG accounting database exists and compare cannot open PG.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/root/Documentation/SchemaComparePostgresPlan.tt</code>, <code>SchemaMasterPlan.tt</code> index, <code>MASTER_PLAN.tt</code> W0.1 G1 note.</p>
</div>
