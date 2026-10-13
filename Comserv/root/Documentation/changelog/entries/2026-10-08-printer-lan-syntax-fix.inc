<div id="2026-10-08-printer-lan-syntax-fix" class="cl-entry">
<h3>2026-10-08 — Printer LAN file manager would not load</h3>
<p class="doc-body"><strong>What.</strong> :4003 failed to reload with a syntax error in <code>Comserv::Util::Printing3d</code> (an <code>unless</code> inside a hash, plus duplicated leftover subs). The printer control page would also have 500'd on the filament list because <code>list_filaments</code> returns a list, not an arrayref.</p>
<p class="doc-body"><strong>Why.</strong> The 3MF parse/copy code was inserted more than once and never compiled. A scalar call then treated one filament hash as the whole list.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/Printing3d.pm</code>, <code>lib/Comserv/Controller/PrinterLan.pm</code></p>
</div>
