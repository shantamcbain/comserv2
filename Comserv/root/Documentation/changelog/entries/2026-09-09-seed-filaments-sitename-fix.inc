<div id="2026-09-09-seed-filaments-sitename-fix" class="cl-entry">
<h3>2026-09-09 — Fix seed_filaments to use session sitename as fallback</h3>
<p class="doc-body"><strong>What.</strong> Changed seed_filaments from hardcoded `|| '3d'` to `|| $self->_sitename($c) || '3d'` to match seed_brew_ingredients pattern, allowing multi-site filament seeding.</p>
<p class="doc-body"><strong>Why.</strong> The '3d' default was hardcoded, but _sitename() already returns the current site from session. Using _sitename as fallback makes the endpoint work correctly when navigated from any site's inventory page, not just the 3d site.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Inventory.pm</code></p>
</div>
