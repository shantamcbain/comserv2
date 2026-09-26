<div id="2026-09-25-usage-live-agents" class="cl-entry">
<h3>2026-09-25 — Live usage poll + active AI agent list</h3>
<p class="doc-body"><strong>What.</strong> <code>/ai/usage_live</code>, <code>/ai/usage_ingest</code>, and <code>/ai/usage_kill</code> live in small <code>Controller::AI::Usage</code> with explicit Paths (the 600k <code>AI.pm</code> was not reloading, so live poll 404'd). Hermes overlay now counts cache/reasoning tokens and <code>session_model_usage</code> API calls. Usage page lists four agents: Hermes, AI Chat, Grok Bot (process only — no API bump), AI Editor.</p>
<p class="doc-body"><strong>Why.</strong> The monitor showed app chat only and missed the SuperGrok burn in open Hermes sessions. Operator asked for a live active-agent list of those four surfaces.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Controller/AI/Usage.pm</code>, <code>lib/Comserv/Model/AI2/UsageMonitor.pm</code>, <code>lib/Comserv/Controller/AI.pm</code>, <code>root/ai/usage.tt</code>, <code>root/static/js/ai/usage-monitor.js</code>.</p>
</div>
