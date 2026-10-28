<div id="2026-09-28-schema-compare-create-table" class="cl-entry">
<h3>2026-09-28 — Schema-compare Create Table no longer walks the whole schema</h3>
<p class="doc-body"><strong>What.</strong> <code>create_table_from_result</code> now builds CREATE TABLE for the one Result class, registers that class and its relationship targets on the live schema instance, and retries if <code>source()</code> names a class that is not registered yet. The old <code>deployment_statements</code> walk and the <code>schema-&gt;deploy()</code> fallback are gone.</p>
<p class="doc-body"><strong>Why.</strong> Admin Create Table died with <code>Can't find source for AiModelPolicyHistory</code> because a process whose schema froze at startup did not know the new Result class, and the fallback would have deployed every table. Existing <code>ai_model_policy*</code> tables were not dropped.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/Admin/SchemaComparison.pm</code></p>
</div>
