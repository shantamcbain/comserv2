<div id="2026-10-17-queue-reads-filament-plan" class="cl-entry">
<h3>2026-10-17 — Queue complete uses the saved filament plan</h3>
<p class="doc-body"><strong>What.</strong> The queue Complete button always prompted for grams and time, even when <code>printing_3d_job_filaments</code> already had the send-time plan. Jobs with a plan now show those grams (and <code>print_hours</code> when set) and confirm without the prompts.</p>
<p class="doc-body"><strong>Why.</strong> The plan was stored, but the page never loaded it, so Complete still asked for a number and a time.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Util/Printing3d.pm</code>, <code>lib/Comserv/Controller/3d.pm</code>, <code>root/3d/queue.tt</code></p>
</div>
