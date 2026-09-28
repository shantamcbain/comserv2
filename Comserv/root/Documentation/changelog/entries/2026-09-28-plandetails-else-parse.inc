<div id="2026-09-28-plandetails-else-parse" class="cl-entry">
<h3>2026-09-28 — Plan details page parse error</h3>
<p class="doc-body"><strong>What.</strong> <code>/membership/plan_details/23</code> 500'd with <code>unexpected token (ELSE)</code> in <code>membership/PlanDetails.tt</code>. The currency <code>IF</code> was closed before its <code>ELSE</code>, and a stray <code>END</code> sat under two <code>[% NEW %]</code> lines that are not blocks.</p>
<p class="doc-body"><strong>Why.</strong> The joining-bonus edit closed the outer <code>IF</code> too early, so the page could not render on any plan.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/membership/PlanDetails.tt</code></p>
</div>
