<div id="2026-09-24-schema-ddl-empty-admin" class="cl-entry">
<h3>2026-09-24 — Schema-compare DDL no longer uses empty admin user</h3>
<p class="doc-body"><strong>What.</strong> <code>sync_table_to_result</code> died with <code>Failed to connect … for DDL via admin user ''</code> (#2378). <code>DatabaseCredentials</code> is not on this branch, so admin username was empty; RemoteDB credential-swap was also discarded on reload.</p>
<p class="doc-body"><strong>Why.</strong> Resolve admin from JSON <code>*_admin</code> / <code>comserv_admin</code> slots (then env), connect with DBI directly, never pass an empty username. Fall back to any live ordinary connection for DESCRIBE.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Controller/Admin/SchemaComparison.pm</code></p>
</div>
