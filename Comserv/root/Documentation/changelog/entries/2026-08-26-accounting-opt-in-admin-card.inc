<div id="2026-08-26-accounting-opt-in-admin-card" class="cl-entry">
<h3>2026-08-26 — Admin Accounting card is opt-in only</h3>
<p class="doc-body"><strong>What.</strong> The admin dashboard Accounting card no longer treats CSC as always opted in. <code>has_accounting</code> requires an enabled <code>accounting</code> site module. Before opt-in the card shows only “Add Accounting package” (link to <code>/admin/site_modules</code>). <code>/Accounting</code> redirects there if the module is off.</p>
<p class="doc-body"><strong>Why.</strong> CSC admins saw CoA, GL, inventory, and schema-compare links with no opt-in. Accounting should not be available until the SiteName enables the package.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Admin.pm</code>, <code>lib/Comserv/Controller/Accounting.pm</code>, <code>root/admin/index.tt</code></p>
</div>
