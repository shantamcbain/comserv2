<div id="2026-08-31-printers-tt-parse-fix" class="cl-entry">
<h3>2026-08-31 — Fix /3d/printers TT2 parse error (LAN pause UI)</h3>
<p class="doc-body"><strong>What.</strong> <code>/3d/printers</code> 500ed with <code>parse error - 3d/printers.tt line 123: unexpected token (.)</code>. Replaced invalid TT2 ternary and <code>(notes || '').match(...)</code> chain with plain SET/IF for LAN_PAUSED detection; same for inventory equipment lookup.</p>
<p class="doc-body"><strong>Why.</strong> This Comserv TT2 build rejects <code>?:</code> and method calls on parenthesized <code>||</code> expressions. Global error handler logged the failure for path <code>3d/printers</code> on :4003.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/3d/printers.tt</code>, changelog fragment.</p>
</div>
