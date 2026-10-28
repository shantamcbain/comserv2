<div id="2026-09-25-usage-human-grok-daily-lock" class="cl-entry">
<h3>2026-09-25 — /ai/usage human overview + SuperGrok off-for-today lock</h3>
<p class="doc-body"><strong>What.</strong> Usage page is five SuperGrok numbers and four agent cards (hash <code>#agent-hermes</code>); charts/admin start closed. 14-day token/API charts toggle bar/line (default bar, localStorage). Daily guard computes yesterday+today from grok.com history vs remaining÷days to 2026-10-01 10:31 PDT and locks Grok for the rest of today when either day is over cap.</p>
<p class="doc-body"><strong>Why.</strong> First reading today as <code>day_start</code> hid yesterday/today overspend and left mode=grok. A long list is not a usable usage page.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/ai/usage.tt</code> <code>root/static/js/ai/usage-monitor.js</code> <code>~/.hermes/scripts/supergrok_daily_guard.py</code> <code>AISYSTEMPlan.tt</code></p>
</div>
