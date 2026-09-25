<div id="2026-09-24-health-kitchen-match" class="cl-entry">
<h3>2026-09-24 — Health Kitchen deterministic herb/formula match</h3>
<p class="doc-body"><strong>What.</strong> <code>Util::HealthKitchen::match_candidates</code> intersects pantry herb ids with <code>herb_symptom</code>, skips contraindicated relationships and drug–herb conflicts, and keeps formulas only when every herb is an allowed pantry match. No LLM.</p>
<p class="doc-body"><strong>Why.</strong> HK-PLANNER #2467 gate: generated menus must not mention foods the user does not have.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/HealthKitchen.pm</code>, <code>t/util_healthkitchen_match.t</code>.</p>
</div>
