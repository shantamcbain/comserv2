<div id="2026-10-11-printer-lan-follow-ip" class="cl-entry">
<h3>2026-10-11 — Follow the Kobra when its LAN address changes</h3>
<p class="doc-body"><strong>What.</strong> Printer identity is now the Anycubic serial (<code>cn</code>) stored as <code>[LAN_CN:…]</code> in the farm row notes. <code>[LAN_HOST:…]</code> is only the last known address. If that address does not answer, control and ping scan the old subnet (then 192.168.2 and 192.168.1) and rewrite the host when the same serial is found. The Kobra 3 row was updated from 192.168.2.53 to 192.168.2.56 after the network move.</p>
<p class="doc-body"><strong>Why.</strong> DHCP moved the printer from .53 to .56. A stored IP alone made the farm look offline until someone edited notes by hand.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/Printing3d/Adapter/Anycubic.pm</code> (<code>relocate</code>), <code>lib/Comserv/Controller/PrinterLan.pm</code> (<code>_follow_printer</code> on ping, attach, and control).</p>
</div>
