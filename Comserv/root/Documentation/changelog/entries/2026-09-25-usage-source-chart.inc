<div id="2026-09-25-usage-source-chart" class="cl-entry">
<h3>2026-09-25 — Usage 14d stacked by source; drop the table wall</h3>
<p class="doc-body"><strong>What.</strong> <code>/ai/usage</code> default view is three KPIs, a 14-day stacked bar chart (tokens + API calls) with one colour per source (Hermes TUI / CLI / oneshot, AI Chat, AI Editor, Grok Bot), legend chips that tunnel into that source, and four agent cards. Kill switch / xAI / ledger are behind one Admin details. Cost is not graphed (xAI actual is $0). Snapshot JSON now includes <code>hermes.by_day_source</code>.</p>
<p class="doc-body"><strong>Why.</strong> The old line chart merged everything and the cost series was empty. The page was still a long list of tables.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/ai/usage.tt</code>, <code>root/static/js/ai/usage-monitor.js</code>, <code>Model/AI2/UsageMonitor.pm</code>, <code>root/static/ai/usage_snapshot.json</code></p>
</div>
