<div id="2026-10-25-database-compare" class="cl-entry">
<h3>2026-10-25 — Compare live databases from schema compare</h3>
<p class="doc-body"><strong>What.</strong> Schema compare cards now list each real database with table and approximate row counts, a checkbox under each card, and a button that opens a read-only difference report.</p>
<p class="doc-body"><strong>Why.</strong> The 3307 server was created without a full data copy. Result-file schema compare cannot show which tables still have rows on one server and not another.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/DatabaseCompare.pm</code>, <code>Controller/Admin/DatabaseCompare.pm</code>, <code>Controller/Admin/SchemaComparison.pm</code>, <code>admin/schema_compare/servers.tt</code>, <code>admin/database_compare.tt</code>, <code>static/js/schema-compare.js</code>, <code>static/css/themes/schema_compare.css</code>, <code>t/util_database_compare.t</code></p>
</div>
