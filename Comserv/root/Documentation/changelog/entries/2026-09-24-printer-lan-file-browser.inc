<div id="2026-09-24-printer-lan-file-browser" class="cl-entry">
<h3>2026-09-24 — Printer LAN file list (local/USB) + delete</h3>
<p class="doc-body"><strong>What.</strong> Control page lists files on the Kobra (local or USB), can print a local file, and delete with a confirm tick. Separate MQTT listLocal/listUdisk so telemetry is not stalled.</p>
<p class="doc-body"><strong>Why.</strong> Organize storage on the machine without the Anycubic app (cloud is off in LAN Mode).</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/Printing3d/Adapter/Anycubic.pm</code>, <code>Controller/PrinterLan.pm</code>, <code>root/3d/printer_control.tt</code></p>
</div>
