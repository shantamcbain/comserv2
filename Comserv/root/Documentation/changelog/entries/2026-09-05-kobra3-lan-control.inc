<div id="2026-09-05-kobra3-lan-control" class="cl-entry">
<h3>2026-09-05 — Kobra 3 LAN state + control page</h3>
<p class="doc-body"><strong>What.</strong> Adapter now parses GET <code>/info</code>, runs the signed POST <code>/ctrl</code> handshake, and queries local MQTTS :9883 for print state (file, progress, layers, temps). New page <code>/3d/printer_lan/control?printer_id=</code> with Pause / Resume / Stop (Stop requires the cancel checkbox). Tokens, MQTT password, and certs are not logged or shown.</p>
<p class="doc-body"><strong>Why.</strong> Farm row 1 is linked at 192.168.2.53. HTTP /info is identity only; live job telemetry and pause/resume/stop live on the printer MQTT broker after handshake.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/Printing3d/Adapter/Anycubic.pm</code>, <code>Controller/PrinterLan.pm</code>, <code>root/3d/printer_control.tt</code>, <code>root/3d/printers.tt</code>.</p>
</div>
