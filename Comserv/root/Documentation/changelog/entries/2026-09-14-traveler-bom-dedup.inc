<div id="2026-09-14-traveler-bom-dedup" class="cl-entry">
<h3>2026-09-14 — Traveler BOM dedup — prevent double-counting multi-path components</h3>
<p class="doc-body"><strong>What.</strong> Added a <code>$seen_leaves</code> hashref guard in Traveler.pm's <code>_explode_to_leaves</code> that skips a leaf component if already counted via another path. A component that is both a direct child of the parent AND a descendant of a sub-assembly (e.g., a part that appears in the HDRY base BOM AND is nested under the add-on BOM) was being counted twice — once per path. The dedup guard ensures each leaf SKU contributes exactly once to traveler quantities.</p>
<p class="doc-body"><strong>Why.</strong> INT-HDRY-001's BOM includes both the Base and Add-on sub-assemblies AND their shared child parts. When the traveler exploded the BOM to leaves, the walker visited those shared children twice (once direct, once via the sub-assembly), overstating the quantity needed and showing duplicate rows.</p>
<p class="doc-body"><strong>Files.</strong> <code>Comserv/lib/Comserv/Util/Manufacturing/Traveler.pm</code> (<code>_explode_to_leaves</code> — <code>$seen_leaves</code> parameter and guard).</p>
</div>
