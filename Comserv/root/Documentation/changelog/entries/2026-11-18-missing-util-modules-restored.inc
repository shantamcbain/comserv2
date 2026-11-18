<div id="2026-11-18-missing-util-modules-restored" class="cl-entry">
<h3>2026-11-18 — startup/runtime abort from missing Comserv::Util modules</h3>
<p class="doc-body"><strong>What.</strong> This worktree's <code>lib/Comserv/Controller/Api.pm</code> (the Android-Studio artifact that is written into every worktree) referenced <code>Comserv::Util</code> modules that this branch does not carry, because the branch is behind <code>main</code>. A top-level <code>use</code> of a missing module aborts Catalyst component setup, so the dev server forks its serving child, the child dies, and nothing binds the port.</p>
<p class="doc-body"><strong>Why.</strong> The modules were added on <code>main</code> after this branch's last merge. Per-worktree audit on 2026-11-18 found: Inventory::PhotoRead, StockTxn, VisionRead (runtime).</p>
<p class="doc-body"><strong>Fix.</strong> Restored the <code>main</code>-tracked copies into this worktree (<code>git show main:Comserv/lib/…</code>); all Controller/Model/View modules then load clean. Follow-up: merge <code>main</code> into this branch so future merges carry the files properly.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/Inventory/PhotoRead.pm</code>, <code>lib/Comserv/Util/StockTxn.pm</code>, <code>lib/Comserv/Util/VisionRead.pm</code></p>
</div>
