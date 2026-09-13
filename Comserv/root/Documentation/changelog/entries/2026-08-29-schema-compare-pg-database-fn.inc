<div id="2026-08-29-schema-compare-pg-database-fn" class="cl-entry">
<h3>2026-08-29 — Schema-compare PG drill-down: no more DATABASE()</h3>
<p class="doc-body"><strong>What.</strong> Opening
<code>/admin/schema_compare/server/db-server-1:5433/db/csc</code> no longer throws
<code>DBD::Pg … function database() does not exist</code> (error-audit todo #2322).
Schema-compare now detects PostgreSQL connections and uses engine-aware SQL:
<code>current_database()</code>, <code>pg_tables</code> / catalog stats, and
<code>information_schema.columns</code> for field compare — instead of MySQL-only
<code>SELECT DATABASE()</code>, <code>SHOW TABLES</code>, and
<code>SHOW FULL COLUMNS</code>. PG catalogs map Result scan to
<code>Schema::Accounting::Result</code> (ResultParser accepts
<code>accounting|pg|postgres|postgresql</code>).</p>
<p class="doc-body"><strong>Why.</strong> SCPG-REMOTEDB already returned a live Pg handle;
the database drill-down still ran uncaught Maria SQL on that handle, so the page 500'd
and the global error handler created a recurring <code>[Error] global_error_handler</code>
todo. Live probe: <code>csc</code> on <code>.20:5433</code> answers
<code>current_database=csc</code> with 0 user tables (empty clone-target is fine — the page
must still render).</p>
<p class="doc-body"><strong>Files.</strong>
<code>lib/Comserv/Controller/Admin/SchemaComparison.pm</code>,
<code>lib/Comserv/Util/Schema/ResultParser.pm</code>.</p>
<p class="doc-body"><strong>Not in this change.</strong> Create Table / Result→DDL on PG
and Maria <code>SHOW TABLES LIKE</code> in <code>create_table_from_result</code> remain
SCPG-COMPARE follow-ups (e.g. #2327). Verify on schema port <code>:4007</code> (hard-refresh
schema-compare).</p>
</div>
