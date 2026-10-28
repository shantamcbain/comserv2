<div id="2026-08-27-anycubic-lan-ping" class="cl-entry">
<h3>2026-08-27 — Anycubic LAN ping (todo #2334)</h3>
<p class="doc-body"><strong>What.</strong> Started direct LAN connection to the Anycubic (Kobra 3). Stock LAN Mode handshake is GET <code>http://HOST:18910/info</code> — not Moonraker, not cloud. New <code>Util::Printing3d::Adapter::Anycubic</code> + thin <code>Controller::PrinterLan</code> ping at <code>/3d/printer_lan/ping</code>. Result columns adapter_type/host/port on Printing3dPrinter (apply via schema-compare). No jobs sent to the machine yet.</p>
<p class="doc-body"><strong>Why.</strong> Queue is still manual; farm needs a proven ping before dispatch.</p>
<p class="doc-body"><strong>Files.</strong> <code>Util/Printing3d/Adapter/Anycubic.pm</code>, <code>Controller/PrinterLan.pm</code>, <code>root/3d/printers.tt</code>. Host/port columns are NOT on the Result yet — adding them before schema-compare would 500 <code>/3d/printers</code> (unknown column).</p>
</div>
