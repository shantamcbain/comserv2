<div id="2026-08-27-sign-order-3mf" class="cl-entry">
<h3>2026-08-27 — Sign order builds two-colour 3MF from filament picks</h3>
<p class="doc-body"><strong>What.</strong> Ordering a sign now renders a two-object 3MF
from the body/text stock dropdowns. Object names and metadata carry filament type and
colour. Post-order page + queue/my-orders download. Delete extra sign_generator rows
(owner/admin; blocked while a job is active).</p>
<p class="doc-body"><strong>Why.</strong> Catalog STL/3MF was baked at design time from
hex pickers; a single STL is one filament; order notes never became a printable file.</p>
<p class="doc-body"><strong>Files.</strong>
<code>services/openscad/app/main.py</code>,
<code>Util/SignGenerator.pm</code>,
<code>Controller/SignGenerator.pm</code>,
<code>Controller/3d.pm</code> (<code>_order_two_colour</code> only),
<code>signgenerator/ordered.tt</code>,
<code>signgenerator/confirm_delete.tt</code>,
<code>3d/browse.tt</code>,
<code>3d/model_detail.tt</code>,
<code>3d/my_orders.tt</code>,
<code>3d/queue.tt</code>,
<code>Documentation/SignGenerator.tt</code>,
<code>Documentation/3dPrintingHowItWorks.tt</code>.</p>
</div>
