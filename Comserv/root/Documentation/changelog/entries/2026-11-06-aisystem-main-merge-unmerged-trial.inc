<div id="2026-11-06-aisystem-main-merge-unmerged-trial" class="cl-entry">
<h3>2026-11-06 — aisystem could not take main until an unmerged trial file was cleared</h3>
<p class="doc-body"><strong>What.</strong> Update-all skipped <code>aisystem</code> because the index still had an unmerged path, <code>Comserv/data/ai_trials/particle_1.state.json</code>, with no merge in progress. That file is live trial state. The index was resolved to the branch version and the live file was put back as a normal unstaged edit. Local <code>main</code> (<code>f1dcf98a6</code>) was then merged with autostash. HEAD is <code>e9450cab3</code>. <code>aisystem</code> is 0 behind <code>main</code>.</p>
<p class="doc-body"><strong>Why.</strong> <code>git commit</code> and <code>git merge --autostash</code> both refuse an unmerged index, so a dirty feature tree was not the blocker. Incoming main did not touch the dirty files. The unfinished AppTime and page-AI edits were left uncommitted on purpose.</p>
<p class="doc-body"><strong>Files.</strong> No feature code was committed. Tracking todo <a href="/todo/details?record_id=2664">#2664</a> on project #280.</p>
</div>
