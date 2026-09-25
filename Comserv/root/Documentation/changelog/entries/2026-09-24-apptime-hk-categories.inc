<div id="2026-09-24-apptime-hk-categories" class="cl-entry">
<h3>2026-09-24 — AppTime leftover + HK pantry categories</h3>
<p class="doc-body"><strong>What.</strong> Provision notes in <code>AccountingDB</code> stamp UTC via <code>AppTime</code>. Item create/edit persist <code>is_consumable</code> and auto-set it for categories <code>food</code>/<code>herb</code>/<code>spice</code>/<code>produce</code>. Those categories appear in add/edit/list suggestions and card colors.</p>
<p class="doc-body"><strong>Why.</strong> Todos #2382 remaining localtime on provision audit; #2483 Health Kitchen pantry SKUs.</p>
<p class="doc-body"><strong>Files.</strong> <code>Model/AccountingDB.pm</code>, <code>Controller/Inventory.pm</code>, <code>root/Inventory/items/{add,edit,list}.tt</code></p>
</div>
