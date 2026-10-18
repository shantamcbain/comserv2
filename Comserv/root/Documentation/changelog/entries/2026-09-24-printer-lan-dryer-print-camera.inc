<div id="2026-09-24-printer-lan-dryer-print-camera" class="cl-entry">
<h3>2026-09-24 — Kobra LAN control: dryer, local start-print, camera capture</h3>
<p class="doc-body"><strong>What.</strong> <code>/3d/printer_lan/control</code> no longer auto-reloads every 15s (that looped a browser Allow/OK dialog). ACE dryer start/stop, list+start of files already on the printer, and MQTT camera start/stop are on the same page. Camera is HTTP-FLV — not playable in Chrome; use VLC after Start camera.</p>
<p class="doc-body"><strong>Why.</strong> Control page only had pause/resume/stop. Raw <code>:18088/flv</code> links without <code>startCapture</code> do nothing, and meta-refresh kept re-prompting.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/Printing3d/Adapter/Anycubic.pm</code>, <code>Controller/PrinterLan.pm</code>, <code>root/3d/printer_control.tt</code></p>
</div>
