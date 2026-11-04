<div id="2026-10-21-healthkitchen-plan-results" class="cl-entry">
<h3>2026-10-21 — Health Kitchen plan Result classes</h3>
<p class="doc-body"><strong>What.</strong> Added <code>UserHealthPlan</code>, <code>UserMealSlot</code>, and <code>UserHealthActivity</code> under the ency schema and created <code>hk_user_health_plan</code>, <code>hk_user_meal_slot</code>, and <code>hk_user_health_activity</code> on the app's ency database.</p>
<p class="doc-body"><strong>Why.</strong> The generated-plan path cannot persist without those classes. <code>MealPlan</code> is the inventory meal plan, not this header.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/Schema/Ency/Result/HealthKitchen/UserHealthPlan.pm</code>, <code>UserMealSlot.pm</code>, <code>UserHealthActivity.pm</code>, <code>lib/Comserv/Model/Schema/Ency.pm</code></p>
</div>
