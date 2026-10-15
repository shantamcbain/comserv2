<div id="2026-09-24-setup-schema-version-badge" class="cl-entry">
<h3>2026-09-24 — Setup wizard shows PG schema version</h3>
<p class="doc-body"><strong>What.</strong> Accounting setup step 2 shows the site PG schema version badge (current / outdated / ahead / unversioned / unknown) via <code>Migrator::schema_version_status</code>, same states as <code>/Accounting/admin/databases</code>.</p>
<p class="doc-body"><strong>Why.</strong> Todo #1846 ACCON Ph.1a S10 — owner sees their own DB version without CSC.</p>
<p class="doc-body"><strong>Files.</strong> <code>Controller/Accounting/Setup.pm</code>, <code>root/Accounting/setup/index.tt</code></p>
</div>
