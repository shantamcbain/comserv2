<div id="2026-11-05-consignment-location-count" class="cl-entry">
<h3>2026-11-05 — Consignment location count: photo → text → stock, invoice, top-up</h3>
<p class="doc-body"><strong>What.</strong> A consignment storage location (Co-op Sprouting Lids, location #10,
partner #2) can now be counted from a photo of the container. The photo is read into a countable text
("1 blue, 2 yellow, 2 red, 0 green") by local vision, a human corrects and confirms that text, and only then
is anything written: the location's stock level is set to the counted total, the difference is journaled as a
<code>count_adjust</code> transaction, the units that left become a DRAFT customer invoice to the placement's
invoice customer (retail less the partner's commission), the shortfall against the maintained quantity is
queued as 3D print jobs per colour, and the photo is deleted.</p>
<p class="doc-body"><strong>Why.</strong> The coop container was invisible to inventory: sales were discovered
by guesswork, and the photo could not be kept (it may be deleted once the text is verified). The count is a
physical truth, so it sets the level rather than incrementing it; the invoice and the top-up both hang off
that single verified text.</p>
<p class="doc-body"><strong>Files.</strong>
<code>Comserv/lib/Comserv/Util/ConsignmentCountVision.pm</code>,
<code>Comserv/lib/Comserv/Util/ConsignmentCount.pm</code>,
<code>Comserv/lib/Comserv/Util/ConsignmentCountRun.pm</code>,
<code>Comserv/lib/Comserv/Util/ConsignmentCountApply.pm</code>,
<code>Comserv/lib/Comserv/Model/Schema/Ency/Result/Accounting/InventoryConsignmentPlacement.pm</code>,
<code>Comserv/lib/Comserv/Model/Schema/Ency/Result/Accounting/InventoryLocationCount.pm</code>,
<code>Comserv/lib/Comserv/Model/Schema/Ency/Result/Accounting/InventoryLocationCountLine.pm</code>,
<code>Comserv/db/migrations/20261105_consignment_location_counts.sql</code>,
<code>Comserv/lib/Comserv/Controller/Inventory.pm</code> (consignment_count, consignment_count_review),
<code>Comserv/root/Inventory/consignment/count.tt</code>,
<code>Comserv/root/Inventory/consignment/count_review.tt</code></p>
<p class="doc-body"><strong>State.</strong> Proven from the CLI end to end (count #3: stock 8 → 5, draft
invoice INV-3D-0001 to MCoop net 5.35 after 30 % commission, print jobs blue ×1 / green ×2). The two new pages
have not yet been opened in a browser, and the consignment list page has no link to them yet.</p>
</div>
