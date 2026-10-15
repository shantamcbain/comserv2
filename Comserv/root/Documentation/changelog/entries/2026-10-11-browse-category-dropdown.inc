<div id="2026-10-11-browse-category-dropdown" class="cl-entry">
<h3>2026-10-11 — Browse: top-category dropdown replaces kind filter buttons</h3>
<p class="doc-body"><strong>What.</strong> The /3d/browse filter row's ignored
"Units / Printable parts / Signs / All" buttons were replaced by a single
top-level Category dropdown (beekeeping, electronica, … with item counts).
Selecting a category filters models to that category <em>and all its
descendants</em> (via descendant_ids in the controller); "All categories"
clears the filter. The Deep-web-search checkbox and the search form now
carry the active category so re-searching keeps the filter.</p>
<p class="doc-body"><strong>Why.</strong> The old kind buttons were dead UI
and duplicates of the dropdown; the top category is the useful level for
shoppers.</p>
<p class="doc-body"><strong>Files.</strong>
<code>Comserv/root/3d/browse.tt</code>,
<code>Comserv/lib/Comserv/Controller/3d.pm</code>.</p>
</div>
