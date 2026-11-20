<div id="2026-11-20-daily-log-start-end" class="cl-entry">
<h3>2026-11-20 — Start Day posted twice; End Day could leave the day open</h3>
<p class="doc-body"><strong>What.</strong> One Start Day click no longer sends two posts. End Day closes every open daily-log row for that user and date, then re-reads the row. If the status is still open, the button gets an error instead of "closed".</p>
<p class="doc-body"><strong>Why.</strong> <code>js_load.tt</code> loaded <code>daily-plan-utils.js</code> twice on <code>/planning/daily</code>, so one click posted twice. The second Start Day response was "already one for the day", shown when OK was clicked on the first alert. End Day closed only the newest row, so a second open row kept the day looking open after the "closed" message.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/js_load.tt</code>, <code>root/static/js/planning/daily-plan-utils.js</code>, <code>root/static/js/planning/daily-plan.js</code>, <code>lib/Comserv/Controller/Planning.pm</code>, <code>root/admin/planning/DailyPlan.tt</code>, <code>root/Documentation/DailyLogStartEndFix.tt</code></p>
</div>
