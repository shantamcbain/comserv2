<div id="2026-10-26-kobra-boot-offline" class="cl-entry">
<h3>2026-10-26 — Kobra boot no longer marks the farm row offline</h3>
<p class="doc-body"><strong>What.</strong> A just-booted Kobra 3 at 192.168.2.59 answered HTTP::Tiny with status 599. That was treated as “printer moved”, the 0.15s sweep missed it, and printer id 1 was marked offline. The printers page then showed “LAN paused” and hid Control.</p>
<p class="doc-body"><strong>Why.</strong> 599 is also connection refused and reset, which a booting printer returns. Offline is not a LAN pause, and Resume LAN does not clear it.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/Printing3d/Adapter/Anycubic.pm</code>, <code>Controller/PrinterLan.pm</code>, <code>root/3d/printers.tt</code></p>
</div>
