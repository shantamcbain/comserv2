<div id="2026-09-25-org-ai-usage-monitor" class="cl-entry">
<h3>2026-09-25 — Org AI usage monitor (Hermes overlay, graphs, kill switch)</h3>
<p class="doc-body"><strong>What.</strong> <code>/ai/usage</code> no longer sums only the last 200 app rows. It SQL-aggregates all <code>ai_usage_logs</code>, overlays live Hermes <code>state.db</code> sessions (tokens/cost), graphs tokens and USD, shows user/sitename/effectiveness, anomalies, a Router kill switch, and <code>/ai/usage_ingest</code> for Grok bot daily eval.</p>
<p class="doc-body"><strong>Why.</strong> Hermes (TUI/CLI/subagent) never wrote the app ledger, so the page under-reported org AI activity.</p>
<p class="doc-body"><strong>Files.</strong> <code>Model/AI2/UsageMonitor.pm</code> <code>Model/AI2/KillSwitch.pm</code> <code>Controller/AI.pm</code> <code>Model/AI2/Router.pm</code> <code>root/ai/usage.tt</code> <code>static/js/ai/usage-monitor.js</code></p>
</div>
