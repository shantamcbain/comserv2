<div id="2026-08-31-queue-user-time-fallback" class="cl-entry">
<h3>2026-08-31 — /3d/queue user_time filter fallback</h3>
<p class="doc-body"><strong>What.</strong> <code>/3d/queue</code> 500ed with <code>user_time: filter not found</code>. The filter lives in <code>View/TT.pm</code> (AppTime) but the long-lived :4003 worker had not reloaded that view. Templates temporarily show stored UTC timestamps without the filter so the page renders.</p>
<p class="doc-body"><strong>Why.</strong> Template edits hot-reload; View::TT FILTERS only apply after the Perl worker reloads. Stale worker since ~Aug 28 missed the AppTime filter registration.</p>
<p class="doc-body"><strong>Files.</strong> <code>root/3d/queue.tt</code>, <code>queue_print.tt</code>, <code>my_orders.tt</code>. Restore <code>| user_time</code> after a deliberate :4003 restart picks up <code>View/TT.pm</code>.</p>
</div>
