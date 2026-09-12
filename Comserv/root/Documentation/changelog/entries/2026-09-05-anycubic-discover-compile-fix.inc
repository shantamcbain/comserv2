<div id="2026-09-05-anycubic-discover-compile-fix" class="cl-entry">
<h3>2026-09-05 — Anycubic adapter compile + LAN discover/attach</h3>
<p class="doc-body"><strong>What.</strong> Adapter failed to compile (<code>Unmatched [ in regex</code> from a broken <code>$[</code> host check), so PrinterLan never loaded. Restored a valid <code>sanitize_host</code>, fast TCP probe of :18910 then GET /info, subnet override, and attach that writes <code>[LAN_HOST:ip]</code> onto an existing farm row (no new printer, no host column).</p>
<p class="doc-body"><strong>Why.</strong> Todo #2334: find the Kobra 3 on 192.168.2.0 and bind it to the seeded farm printer. Broken file writes left the 4003 worker unable to compile the adapter.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/Printing3d/Adapter/Anycubic.pm</code>, <code>Controller/PrinterLan.pm</code>, <code>root/3d/printer_discover.tt</code>, <code>root/3d/printers.tt</code>.</p>
</div>
