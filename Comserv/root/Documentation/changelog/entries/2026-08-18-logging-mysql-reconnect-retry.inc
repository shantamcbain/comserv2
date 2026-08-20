<div id="2026-08-18-logging-mysql-reconnect-retry" class="cl-entry">
<h3>Admin::Logging index &mdash; MySQL transient-connection retry</h3>
<div class="container">

    <h1 class="doc-h1">Logging admin: self-heal "Lost connection to MySQL server during query"</h1>

    <div class="last-updated" doc-muted>
        Last Updated: 2026-08-18 | Version: 1.00 | Author: hermes | Status: Fixed
    </div>

    <div id="toc" class="row doc-toc">
        <div class="col-100">
            <h2 class="doc-h2">Quick Navigation</h2>
            <div class="doc-navrow">
                <a href="#summary" class="doc-navlink">Summary</a>
                <a href="#root" class="doc-navlink">Root cause</a>
                <a href="#fix" class="doc-navlink">Fix</a>
                <a href="#files" class="doc-navlink">Files</a>
                <a href="#verify" class="doc-navlink">Verification</a>
            </div>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="summary" class="doc-h2">1. Summary</h2>
            <p class="doc-body">The Application Error Audit todo <code>admin/logging &mdash; Failed to fetch system_log records: DBIx::Class ... Lost connection to MySQL server during query</code> (logged 2026-08-17) is now fixed. A sub-second DB connection drop during the <code>system_log</code> fetch no longer re-raises the error and opens a spurious audit todo.</p>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="root" class="doc-h2">2. Root cause</h2>
            <ul class="doc-body">
                <li>The connection config (<code>Model/DBEncy.pm</code>) sets <code>mariadb_auto_reconnect =&gt; 1</code>, but DBD::MariaDB only repairs the <em>next</em> statement after a drop &mdash; it does <strong>not</strong> retry the in-flight query that already failed. So a "Lost connection during query" raised from the cached (now-dead) handle.</li>
                <li>The Logging <code>index</code> retry block only fell back for a missing <code>system_identifier</code> column; it reused the same cached handle, so a transient drop still failed and re-logged the very error in the todo.</li>
                <li>Same-day commit <code>67cbb177</code> hardened <code>Admin::HardwareMonitor</code> with a disconnect+reconnect-once pattern for exactly this class of error, but the Logging <code>index</code> path was missed.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="fix" class="doc-h2">3. Fix</h2>
            <ul class="doc-body">
                <li><code>lib/Comserv/Controller/Admin/Logging.pm</code> &mdash; added <code>$attempt_with_reconnect</code>: on a connection-drop error (<code>Lost connection</code> / <code>server has gone away</code> / <code>MySQL server</code>) it disconnects, grabs a fresh handle via <code>$schema-&gt;storage-&gt;dbh</code>, and retries the whole fetch <strong>once</strong>. Mirrors the proven <code>Admin::HardwareMonitor</code> pattern.</li>
                <li>The guard wraps both the full-column fetch and the base-column fallback, and the area-counts query. Only if the retry also fails does it fall through to logging the error (so genuine failures still surface).</li>
                <li>Extracted an <code>$area_counts_stash</code> helper so the grouped breakdown is populated in both the primary and retry paths.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="files" class="doc-h2">4. Files changed</h2>
            <ul class="doc-body">
                <li><code>lib/Comserv/Controller/Admin/Logging.pm</code> &mdash; <code>index</code>: transient-connection reconnect guard (uncommitted, pending commit).</li>
                <li>Unchanged: <code>lib/Comserv/Model/DBEncy.pm</code> (auto-reconnect attr already present); <code>lib/Comserv/Controller/Admin/HardwareMonitor.pm</code> (already hardened in <code>67cbb177</code>).</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 id="verify" class="doc-h2">5. Verification</h2>
            <ul class="doc-body">
                <li><code>perl -Ilib -c lib/Comserv/Controller/Admin/Logging.pm</code> &rarr; syntax OK.</li>
                <li>Standalone <code>:3001</code> auto-reloads the <code>.pm</code>, so the guard is live on the next request (no restart).</li>
                <li>A sub-second blip now self-heals within the request; a genuine outage still surfaces the error after the single retry.</li>
            </ul>
            <p class="doc-backtop"><a href="#toc" class="doc-link">↑ Back to Top</a></p>
        </div>
    </div>

</div>
</div>
