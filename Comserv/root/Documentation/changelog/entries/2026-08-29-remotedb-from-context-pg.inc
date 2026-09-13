<div id="2026-08-29-remotedb-from-context-pg" class="cl-entry">
<h3>2026-08-29 — RemoteDB from_context + postgresql in select_connection</h3>
<p class="doc-body"><strong>What.</strong> Fixed error todo #2343 (<code>RemoteDB::index</code>:
  <em>Can't use string ("Comserv::Model::RemoteDB") as a HASH ref</em>).
  <code>Comserv::Model::RemoteDB</code> is plain Moose (cannot extend
  <code>Catalyst::Model</code> — class-level <code>config</code> collides with the Moose
  <code>has config</code>). Added <code>from_context($c)</code> and routed every
  <code>$c-&gt;model('RemoteDB')</code> call site through it
  (Controller::RemoteDB, Setup, Root, Util::RemoteDB, View::Helper::Database,
  RemoteDBExample). Also allowed <code>postgresql|postgres|pg</code> in
  <code>select_connection</code> and taught <code>test_connection</code> to build a
  <code>dbi:Pg</code> DSN (SCPG-REMOTEDB #2325/#2326). Verified
  <code>get_connection(db_production_postgres)</code> returns a handle and
  <code>get_connection_info('csc')</code> selects the PG slot.</p>
<p class="doc-body"><strong>Why.</strong> Visiting <code>/remotedb</code> crashed because
  Catalyst returned the bare class-name string and Moose accessors ran on it.
  PG slots were skipped as "Invalid db_type" so schema-compare could not open
  PostgreSQL connections.</p>
<p class="doc-body"><strong>Files.</strong>
  <code>lib/Comserv/Model/RemoteDB.pm</code>,
  <code>lib/Comserv/Controller/RemoteDB.pm</code>,
  <code>lib/Comserv/Controller/Setup.pm</code>,
  <code>lib/Comserv/Controller/Root.pm</code>,
  <code>lib/Comserv/Util/RemoteDB.pm</code>,
  <code>lib/Comserv/View/Helper/Database.pm</code>,
  <code>lib/Comserv/Controller/RemoteDBExample.pm</code>,
  <code>t/model_RemoteDB_from_context.t</code></p>
</div>
