<div id="2026-09-24-health-kitchen-symptoms" class="cl-entry">
<h3>2026-09-24 — Health Kitchen symptoms + ENCY pantry map</h3>
<p class="doc-body"><strong>What.</strong> Result classes <code>hk_user_health_profile</code> and <code>hk_user_active_symptom</code> (schema-compare). <code>/healthkitchen/symptoms</code> add/resolve; resolved rows are omitted from <code>match_for_symptoms</code>. Pantry rows with an inventory SKU can link/unlink herb/organism/animal/insect/formula via <code>hk_inventory_ency_map</code>.</p>
<p class="doc-body"><strong>Why.</strong> HK-SYMPTOMS #2462/#2463 and remaining HK-PANTRY #2459. Planner input is the active set only.</p>
<p class="doc-body"><strong>Files.</strong> <code>Result/HealthKitchen/UserHealthProfile.pm</code>, <code>UserActiveSymptom.pm</code>, <code>Schema/Ency.pm</code>, <code>Util/HealthKitchen.pm</code>, <code>Controller/HealthKitchen.pm</code>, <code>root/healthkitchen/{symptoms,pantry,index}.tt</code>.</p>
</div>
