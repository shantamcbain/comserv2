<div id="2026-09-10-traveler-bom-filter-fix" class="cl-entry">
<h3>2026-09-10 — Fixed traveler BOM filter skipping valid HDRY parts</h3>
<p class="doc-body"><strong>What.</strong> Fixed `_explode_to_leaves` in `Traveler.pm` line 274 where a broad regex `INT-HDRY-(BBL|BBR|BL|BLS|BR|BRS|FL|FLS|FR|FRS|FFL|FFR|SBR|SRC|SRL|SRR)` was silently skipping valid BOM components (SBL01, SBL02, BBR03, BL03, BR03, FL03, STEAM-CAP, SMOOTH-CAP, CONNECTOR-CUP, BOARD, BOARD-CAP) from the traveler view. Replaced with targeted filter that only skips L1/L2 corner aliases (*03 STL files aliased to *01).</p>
<p class="doc-body"><strong>Why.</strong> The old regex assumed all parts matching BBL/BBR/BL/BR/FL/FR/SBR/SRC/SRL/SRR/SBL should be skipped as corner duplicates, but many are distinct BOM components. This caused INT-HDRY-001 traveler to be unaware of 15+ valid BOM items.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/Manufacturing/Traveler.pm</code></p>
</div>
<div id="2026-09-10-bom-links-added" class="cl-entry">
<h3>2026-09-10 — Added BOM links for 11 HDRY structural parts</h3>
<p class="doc-body"><strong>What.</strong> Added BOM entries linking 11 newly created HDRY parts to the base unit assembly (item 52): BOARD, BOARD-CAP, CONNECTOR-CUP, SMOOTH-CAP, STEAM-CAP, SBL01, SBL02, BBR03, BL03, BR03, FL03. These parts had no BOM entries so the traveler never showed them.</p>
<p class="doc-body"><strong>Why.</strong> Parts were created in inventory but not linked to any parent BOM, making them invisible to the traveler. The base unit BOM now correctly includes all structural components.</p>
<p class="doc-body"><strong>Files.</strong> <code>inventory_item_bom</code> (direct DB insert)</p>
</div>