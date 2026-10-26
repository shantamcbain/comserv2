<div id="2026-10-17-classify-results-template" class="cl-entry">
<h3>2026-10-17 — Classification results page exists for every site</h3>
<p class="doc-body"><strong>What.</strong> Run classification no longer dies with a missing template. The results page is at <code>root/mail/mail.classify_results.tt</code>, not only under <code>CSC/mail/</code>.</p>
<p class="doc-body"><strong>Why.</strong> <code>/mail/classify_invoices</code> asked for <code>mail/mail.classify_results.tt</code>. That file existed only as <code>CSC/mail/mail.classify_results.tt</code>, so a request from <code>3d.local:4001</code> rendered no page and dumped the request.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/mail/mail.classify_results.tt</code>, <code>Controller/Mail.pm</code></p>
</div>
