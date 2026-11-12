<div id="2026-11-08-git-start-one-click" class="cl-entry">
<h3>2026-11-08 — Git dashboard: one click to update or start</h3>
<p class="doc-body"><strong>What.</strong> Update all from main asks once, not twice. Hermes Start reloads the tab when the port comes up instead of leaving "Unable to connect". Open/Stop/Restart ignore a second listener on the same click.</p>
<p class="doc-body"><strong>Why.</strong> The update handler confirmed, then <code>run()</code> confirmed again, so the action looked dead if the second dialog was cancelled. Hermes opened the dashboard URL before it listened and then refused to navigate to that same URL, so the tab stayed dead until a second click.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/static/js/git-dashboard.js</code>, <code>lib/Comserv/Util/Git.pm</code> (plain "nothing to merge" summary when no branch is behind local main).</p>
</div>
