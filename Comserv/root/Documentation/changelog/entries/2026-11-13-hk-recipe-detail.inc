<div id="2026-11-13-hk-recipe-detail" class="cl-entry">
<h3>2026-11-13 — Recipe detail shows steps and ENCY links</h3>
<p class="doc-body"><strong>What.</strong> Clicking a recipe opens <code>/healthkitchen/recipe/&lt;id&gt;</code> with numbered preparation steps and an ENCY link on each ingredient that matches exactly. A name that is not in ENCY opens the add-herb page with that name filled in.</p>
<p class="doc-body"><strong>Why.</strong> The list showed a method blob and bare ingredient names. The step table is not in the database yet, so the page splits the existing instructions text.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/HealthKitchen/RecipeDetail.pm</code>, <code>lib/Comserv/Controller/HealthKitchen.pm</code>, <code>root/healthkitchen/recipe.tt</code>, <code>root/healthkitchen/recipes.tt</code>, <code>root/healthkitchen/index.tt</code>, <code>lib/Comserv/Util/HealthKitchen/SlotRecipe.pm</code></p>
</div>
