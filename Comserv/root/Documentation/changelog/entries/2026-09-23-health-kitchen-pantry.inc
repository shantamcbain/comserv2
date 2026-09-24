<div id="2026-09-23-health-kitchen-pantry" class="cl-entry">
<h3>2026-09-23 — Health Kitchen HK-PANTRY (personal vs inventory)</h3>
<p class="doc-body"><strong>What.</strong> Result classes <code>hk_user_pantry_qty</code> and <code>hk_inventory_ency_map</code> (schema-compare). Util deducts inventory SKUs when the site has inventory; otherwise personal pantry only. Recipes reuse <code>ency_recipe</code> / <code>ency_recipe_line</code>. Mark-as-made on <code>/healthkitchen/recipes</code>.</p>
<p class="doc-body"><strong>Why.</strong> Members without accounting still get a kitchen. Shanta’s SiteName with inventory can drive the reorder short list by consuming stock when a recipe is marked made.</p>
<p class="doc-body"><strong>Files.</strong> <code>Result/HealthKitchen/*.pm</code>, <code>Util/HealthKitchen.pm</code>, <code>Controller/HealthKitchen.pm</code>, <code>root/healthkitchen/{index,pantry,recipes}.tt</code>.</p>
</div>
