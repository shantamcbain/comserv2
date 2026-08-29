<div id="2026-08-27-ai-coa-wizard" class="cl-entry">
<h3>2026-08-27 — AI Chart of Accounts wizard (review then seed)</h3>
<p class="doc-body"><strong>What.</strong> <code>/Accounting/setup/ai_generate</code> is SiteName-scoped. Overlays pre-fill from that site’s enabled teaching/ecommerce modules. Entity type is an explicit form field (sole proprietor / corporation / partnership / non-profit), defaulted from the site map. Maria accounts with GL/inventory/invoice activity on this site are locked keep; unused generic accounts may drop. Dropped accnos are stored on <code>site_accounting_dbs.notes</code> so Import will not reinsert them; GL lines whose accno is missing now fail instead of silent skip.</p>
<p class="doc-body"><strong>Why.</strong> ACCON Ph.2: generated charts must not commit unreviewed, and existing Maria books must not be discarded.</p>
<p class="doc-body"><strong>Files.</strong> <code>Controller/Accounting/Setup.pm</code>, <code>Util/Accounting/CoaAiGenerate.pm</code>, <code>Util/Accounting/Migrator.pm</code>, <code>root/Accounting/setup/ai_generate.tt</code>, <code>root/Accounting/setup/index.tt</code>, <code>Model/CoaTemplate.pm</code>.</p>
</div>
