<div id="2026-09-24-audit-coa-new" class="cl-entry">
<h3>2026-09-24 — CoA seed uses CoaTemplate->new</h3>
<p class="doc-body"><strong>What.</strong> <code>provision_site</code> called <code>Comserv::Model::CoaTemplate->instance</code>, which does not exist (plain Moose). Chart seeding died and created audit todo #2398.</p>
<p class="doc-body"><strong>Why.</strong> Other callers already used <code>-&gt;new</code>.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Model/AccountingDB.pm</code></p>
</div>
