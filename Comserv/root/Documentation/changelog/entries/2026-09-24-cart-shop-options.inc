<div id="2026-09-24-cart-shop-options" class="cl-entry">
<h3>2026-09-24 — Cart keeps Shop option_N attributes</h3>
<p class="doc-body"><strong>What.</strong> <code>Cart::add_to_cart</code> joins <code>option_0..N</code> from the shop item form into the cart line <code>options</code> string. Shop grid Order now posts <code>quantity</code> (default 1).</p>
<p class="doc-body"><strong>Why.</strong> Shop posted <code>option_*</code> and grid Order sent <code>item_id</code> only; qty and attributes never reached the invoice.</p>
<p class="doc-body"><strong>Files.</strong> <code>Controller/Cart.pm</code>, <code>root/Shop/index.tt</code></p>
</div>
