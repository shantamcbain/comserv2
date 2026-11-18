<div id="2026-11-07-custom-order-description" class="cl-entry">
<h3>2026-11-07 — Customer order can hold any part description</h3>
<p class="doc-body"><strong>What.</strong> The order form has a paragraph box, Describe the part. A line with only that text is saved. The full paragraph is stored in the line notes, because the description column is only 500 characters, and the order view shows it back.</p>
<p class="doc-body"><strong>Not done.</strong> This does not create an STL. Port 4003 was not running, so the form was not exercised in a browser.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/CustomerOrder/new.tt</code>, <code>root/CustomerOrder/view.tt</code>, <code>root/static/js/CustomerOrder/order-form.js</code>, <code>lib/Comserv/Controller/CustomerOrder.pm</code>. Todo #2681.</p>
</div>
