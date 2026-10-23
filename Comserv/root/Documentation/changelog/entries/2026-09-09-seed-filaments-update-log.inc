<div id="2026-09-09-seed-filaments-update-log" class="cl-entry">
<h3>2026-09-09 — Fix seed_filaments update counter and log entries</h3>
<p class="doc-body"><strong>What.</strong> Fixed $skipped++ to always increment (removed `if $skipped == 0` guard) and added log entry for successful updates so the seed_result table shows "updated" for each item.</p>
<p class="doc-body"><strong>Why.</strong> The `if $skipped == 0` guard prevented the counter from incrementing after the first existing item, causing incorrect "0 created, 21 skipped" display. Also, successful updates had no log entry in @log so the result table was empty for updated items.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/Inventory.pm</code></p>
</div>
