<div id="2026-10-08-printer-lan-camera-box" class="cl-entry">
<h3>2026-10-08 — Printer camera plays in the page</h3>
<p class="doc-body"><strong>What.</strong> The printer control page now has a video box for the Kobra 3 HTTP-FLV stream. It stays disconnected until Show in page is clicked.</p>
<p class="doc-body"><strong>Why.</strong> A browser tab cannot play <code>http://printer:18088/flv</code> by itself. The printer also allows only one viewer, so the page must not grab the stream on load.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/3d/printer_control.tt</code>, <code>root/js_load.tt</code>, <code>root/static/js/printer-lan-camera.js</code>, <code>root/static/js/vendor/flv.min.js</code></p>
</div>
