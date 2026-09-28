<div id="2026-09-27-session-eval-review" class="cl-entry">
<h3>2026-09-27 — Session eval on /ai/eval; effectiveness card un-buried</h3>
<p class="doc-body"><strong>What.</strong> Reviewed this session's diffs. Fixed <code>_eff_quality</code> counting group buckets as if they were calls. Moved the agent-effectiveness and Daily Eval cards out of collapsed More on <code>/ai/usage</code>. Added Eval links on the usage nav and the <code>/ai</code> admin topbar. Ingested session report <code>2026-09-27</code> source Hermes session 20260926_183058_68fb2e into <code>ai_eval_report</code>.</p>
<p class="doc-body"><strong>Why.</strong> Admin could not see model effectiveness or reach the eval report the session was supposed to create. Schema-compare create-table remains unfixed (called out in the report, not bypassed again).</p>
<p class="doc-body"><strong>Files.</strong> <code>UsageMonitor.pm</code> <code>usage.tt</code> <code>ai/index.tt</code> <code>eval/list.tt</code> <code>eval/detail.tt</code> <code>usage_eval_card.tt</code> <code>data/ai_eval_inbox/2026-09-27-hermes-session-68fb2e.json</code></p>
</div>
